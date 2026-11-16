# MarkText 2 — native Swift rewrite (plan)

## What we found
- The folder contains only the shipped `MarkText.app` 0.17.1 (March 2022): Electron + Vue 2 + Element UI + the custom "Muya" editor engine, about 285 MB, about 15k files in `app.asar`. Its Info.plist was built with macOS SDK 11.1 and declares `LSMinimumSystemVersion 10.11`.
- There is no source checkout. Source maps inside the asar show the feature set: live-preview editor, sidebar (file tree, outline, search), tabs, 6 themes, KaTeX math, mermaid/flowchart/sequence/vega diagrams, Prism code highlighting, HTML/PDF export, focus/typewriter/source modes, image uploaders, spellcheck, command palette.
- Upgrading the Electron app in place is not worthwhile: Vue 2, Element UI and Electron 1x are all EOL, and the native modules (keytar, native-keymap, fontmanager) would need rebuilding. **Decision: clean-room native rewrite.** We keep the name, document types and core reading experience. We drop the long tail (uploaders, tweet, command palette, Unsplash, custom spellchecker; macOS already provides spellcheck).

## Product shape: a simple viewer that can edit
- Opens `.md .markdown .mmd .mdown .mdtxt .mdtext` (+ `public.plain-text` via "Open With").
- **Read mode is the default.** Edit is one shortcut away: ⌘E toggles Read ↔ Split, and ⌘⌥E opens source-only Edit.
- Sidebar: **Outline** (headings, click to jump, live highlight of the current section).
- Live reload when the file changes on disk (editors, `git pull`, AI agents writing files).
- Toolbar appearance popover: Theme (Auto / Light / Dark / Sepia), Typeface (System / New York / Mono), text size, line width (Narrow / Wide).
- Subtitle: `1,240 words · 6 min read`.
- Find (⌘F), Print (⌘P), Export PDF / HTML, Share.
- Quick Look extension: spacebar in Finder renders markdown with the same renderer.

## Tech
| Area | Choice |
|---|---|
| Language | Swift 6.4, strict concurrency (Swift 6 language mode) |
| UI | SwiftUI `DocumentGroup` + `NavigationSplitView`; macOS 26 Liquid Glass (system toolbar/sidebar glass, `.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`), built with the macOS 27 SDK |
| Deployment target | macOS 26.0, `ARCHS=arm64` only |
| Project | XcodeGen `project.yml` → `MarkText.xcodeproj` |
| Parsing | `apple/swift-markdown` (cmark-gfm: tables, task lists, strikethrough, autolinks); our own Swift `HTMLRenderer` visitor |
| Math | Swift pre-pass protects `$…$` / `$$…$$` (outside code) → placeholders → KaTeX renders client side |
| Diagrams | ```` ```mermaid ```` → mermaid v11 (vendored) |
| Code highlight | highlight.js (vendored, common languages) |
| Preview | `WKWebView` in `NSViewRepresentable`, template loaded once; updates pushed via JS (`MarkText.render`) with scroll position kept |
| Local resources | `WKURLSchemeHandler`: `mtres://` = bundled assets, `mtdoc://` = files relative to the document folder (relative images work) |
| Editor | `NSTextView` (TextKit 2) wrapper with a lightweight markdown highlighter, system find bar, spellcheck |
| Sandbox | **Off** (relative images, links to sibling `.md` files). Hardened runtime, ad-hoc signed. QL extension is sandboxed (required). |
| Bundle ID | `io.github.greenerycomplexity.MarkText` (does not clash with the old `com.github.marktext.marktext`) |

## Layout
```
MarkText/
  project.yml
  Sources/
    MarkTextKit/        framework: Markdown → HTML, outline, stats, assets (shared with QL)
      Renderer/  MarkdownRenderer.swift, HTMLRenderer.swift, MathProtector.swift, Slugger.swift, FrontMatter.swift
      Model/     RenderedDocument.swift (html, headings, stats)
      Web/       PreviewAssets.swift (bundle URLs), SchemeHandler.swift
      Resources/web/  template.html, marktext.css, marktext.js, vendor/{katex,mermaid,hljs}
    MarkText/           app
      App/ Document/ Views/ Editor/ Preview/ Settings/ Export/ Support/
    MarkTextQuickLook/  QL preview extension
  Tests/MarkTextKitTests/  + Fixtures/*.md
  Resources/AppIcon.icon (Icon Composer) + Assets.xcassets
```

## Contracts (fixed: agents build against these)

### Swift (MarkTextKit)
```swift
public struct Heading: Hashable, Sendable, Identifiable { public let id: String /*slug*/; public let level: Int; public let title: String }
public struct DocumentStats: Hashable, Sendable { public let words: Int; public let readingMinutes: Int }
public struct RenderedDocument: Sendable { public let html: String /*body fragment*/; public let headings: [Heading]; public let stats: DocumentStats; public let hasMath: Bool; public let hasMermaid: Bool }
public enum MarkdownRenderer { public static func render(_ markdown: String) -> RenderedDocument }  // pure, thread-safe
public enum PreviewAssets { public static var templateURL: URL; public static var bundle: Bundle }
public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler { public init(documentDirectory: @escaping @Sendable () -> URL?) }
```
HTML rules: headings get `id="<slug>"` (GitHub-style, deduped `-1`, `-2`). Task items get `<input type="checkbox" disabled>`. Relative `src` values are rewritten to `mtdoc://local/<percent-encoded relative path>`. Code blocks become `<pre><code class="language-x">`, and mermaid blocks become `<div class="mermaid">`. Math becomes `<span class="math-inline">` / `<div class="math-display">` with the raw TeX as escaped text. Front matter (YAML `---`) is stripped and shown as a collapsed `<details class="front-matter">`. Raw HTML is passed through, then sanitized in JS (DOMPurify not needed: we strip `<script>` and `on*=` in Swift).

### JS bridge (`marktext.js`, global `window.MarkText`)
- `MarkText.render(html, {preserveScroll: bool})`: replaces `#content`, then runs hljs, KaTeX and mermaid (lazy).
- `MarkText.setStyle({theme:'auto'|'light'|'dark'|'sepia', font:'system'|'serif'|'mono', size: 16, width:'narrow'|'wide'})`.
- `MarkText.scrollToHeading(id)`, `MarkText.scrollToFraction(f)`.
- Posts to `window.webkit.messageHandlers.marktext` as `{type:'ready'} | {type:'activeHeading', id} | {type:'scroll', fraction} | {type:'link', href}`. All link clicks are intercepted and sent to Swift.

## Design direction
- Content first: chrome is glass, and the page is the reading surface. There are no custom colors in chrome, only system materials and semantic colors. One accent (system accent).
- Typography: SF Pro Text 16/1.65 default, measure 68ch (narrow) / 92ch (wide). Headings are tight (1.25), with weight carrying hierarchy rather than size alone. Code is SF Mono 0.875em on a subtle fill. No heavy borders.
- Page background follows the window: transparent web view over the window background so glass toolbars sample the real content. Content scrolls under the toolbar (`.scrollEdgeEffectStyle`-like soft edge done in CSS).
- Sepia: warm paper (#F7F1E3 / text #3B3125). Dark: true system dark (#1E1E1E-ish), not pure black.
- Outline sidebar: plain list, indented by level, SF 13pt, current heading in accent tint. Empty state: "No headings".
- Empty/new document: centered placeholder "Start writing, or drop a Markdown file here."
- Motion: system defaults only. Mode switches animate split width; no custom springs.

## Testing (runs in background, never steals focus)
1. `xcodebuild test` on MarkTextKit: fixtures for GFM, math protection, slugs, front matter, relative image rewriting, sanitizing, plus a performance test (1 MB doc).
2. Snapshot harness (DEBUG only): `MarkText --snapshot <file.md> --out <dir> [--mode read|split|edit] [--theme …]`. The app launches as `.accessory` (no Dock icon, no activation), moves its own window to a non-current Space (SkyLight private API, DEBUG only; if unavailable the window is ordered back), renders, and writes PNGs of the window via `screencapture -l` driven from the harness script, then exits.
3. Opus (me) reviews every snapshot for design quality, then sends polish rounds.

## Phases
| # | Work | Agent | Parallel |
|---|---|---|---|
| 1 | Scaffold + MarkTextKit renderer + unit tests | Sonnet A | ✓ |
| 1 | Web assets: vendor libs, template/CSS/JS bridge | Sonnet B | ✓ |
| 1 | App icon (`.icon` + asset catalog fallback) | Sonnet C | ✓ |
| 2 | App UI: document, viewer, editor, outline, settings, export, live reload | Sonnet D | after 1 |
| 3 | Quick Look extension + snapshot harness | Sonnet E | after 2 |
| 4 | Snapshot review → polish rounds | me + Sonnet | loop |
| 5 | Release build, install to `~/Applications` test copy, final report | me | |

---
## Revisions after Fable review (these override the sections above)
1. **Document architecture:** AppKit `NSDocument` (`MarkdownDocument`) + `NSWindowController` hosting the SwiftUI root view in an `NSHostingController` (`sceneBridgingOptions = [.toolbars, .title]`). The SwiftUI `App` provides only `Settings` + commands via `NSApplicationDelegateAdaptor`. NSDocument gives clean-only autorevert on external change, a Print command, versions and recents. `applicationShouldOpenUntitledFile` → false; on launch with no docs, show the Open panel. Never reload through a binding. Preserve encoding, BOM and line endings on save.
2. **MarkTextKit is a local Swift package** at `MarkText/Packages/MarkTextKit`. It is linked statically into the app and the QL extension, and resources ship via `Bundle.module` (`.copy("Resources/web")` keeps the folder tree). swift-markdown is pinned to `exact: 0.7.3`.
3. **Images and links:** no Swift rewriting of `src`. The template gets `<base href="mtdoc://local/<abs doc dir>/">`, and template assets use absolute `mtres://` URLs. The handler resolves the path, runs realpath, and serves files only (any path, since the app is unsandboxed) with correct MIME types. `#frag` links are handled in JS. Every other click goes to Swift as `{type:'link', href}`: http(s)/mailto open in the default app, and a relative `.md` path opens in MarkText. Remote images are **allowed** (`img-src https:`), because a viewer showing README badges is expected.
4. **Security:** CSP in the template (`default-src 'none'; script-src mtres:; style-src mtres: 'unsafe-inline'; img-src mtres: mtdoc: data: https:; font-src mtres: data:`). DOMPurify runs in JS before `innerHTML`, and Swift does no regex stripping. The navigation delegate cancels every navigation after the template load.
5. **Math:** parse once to find code/HTML source ranges, mask them, substitute alphanumeric placeholders, parse again. Delimiters follow pandoc rules: `\$` escapes, `$5 and $10` stays literal. A display placeholder alone in a paragraph is unwrapped to `<div class="math-display">`. TeX is excluded from word counts.
6. **Bridge additions:** `{type:'rendered', errors:[...]}` after hljs, KaTeX, mermaid, fonts and images settle. Mermaid source is kept in `data-source` and re-rendered on theme change. Scroll is anchored to an element. Swift calls the bridge only via `callAsyncJavaScript(..., arguments:)` and queues calls until `ready`.
7. **Themes:** the chosen theme sets the window `NSAppearance` (Auto = nil), Sepia uses the light appearance plus a CSS class, and the web view background is transparent.
8. **Find:** custom glass find bar over `WKWebView.find(_:configuration:)` in Read mode. The NSTextView find bar is used in the editor.
9. **Print and PDF:** `webView.printOperation(with:)` with a print stylesheet. Export PDF uses the same operation with the save job disposition.
10. **Quick Look:** the extension is sandboxed with `network.client`. It replies only after `rendered`, and has no relative images. A `net.daringfireball.markdown` UTI is imported with all six extensions.
11. **Signing:** manual, "Apple Development" identity (stable across builds), hardened runtime.
12. **Test harness:**
    - **Tier A (always):** `--snapshot` runs an `.accessory` app; the window is ordered back and never key. Output is `WKWebView.takeSnapshot` PNGs plus a DOM-assertion JSON.
    - **Tier B (a few shots):** in-process ScreenCaptureKit window capture for glass fidelity. The SkyLight Space move is dropped.
13. **Phases:**
    - **0** spike (project.yml, empty app + extension + icon wiring, external reload, transparent web view under glass, both capture tiers), in parallel with **1** (renderer, web assets, icon).
    - **2a** shell, preview and outline; **2b** editor; **2c** export, print and find; **3** Quick Look.
    - Then the polish loop.
14. **Shipping:** `LSHandlerRank` Default, a third-party licences file, vendor versions pinned with checksums (mermaid as the single-file `mermaid.min.js`).
15. **Contract additions, final (all agents):**
    - **Line mapping:** block elements (`p h1-6 pre ul ol li blockquote table hr div.math-display div.mermaid details`) carry `data-line="<1-based line in the ORIGINAL source>"`. The math pre-pass must map lines back to the original source.
    - **URLs:** the template is loaded from `mtres://app/template.html` and references assets with relative paths (`vendor/katex/katex.min.css`). The document folder is served as `mtdoc://local/<absolute/path>`.
    - **Bridge API:** `MarkText.render(html, {preserveScroll, baseHref, hasMath, hasMermaid})` sets/updates `<base>` and lazy-loads mermaid/KaTeX only when needed. `MarkText.scrollToLine(n)` was added. The `scroll` message is `{type:'scroll', fraction, line}`, where `line` is the `data-line` of the top visible block.
    - **Mermaid** blocks are `<div class="mermaid" data-line=".." data-source="<escaped source>"></div>`.
16. **Toolbar and window open (performance pass):**
    - The toolbar is a native `NSToolbar` (`Document/DocumentToolbar.swift`), not SwiftUI `.toolbar`. The hosting controller uses `sceneBridgingOptions = []` and `sizingOptions = []`; the window owns its size. Revision 1's `[.toolbars, .title]` no longer applies.
    - Items: sidebar toggle, tracking separator, three mode toggle buttons (one glass capsule), Find and Appearance (one capsule; the popover hosts the SwiftUI `AppearancePopover`), `NSSharingServicePickerToolbarItem` (only when the document has a file).
    - `PreviewController.make()` hands out a prewarmed spare web view; a replacement is prepared 2.5 s later in two run-loop turns.
    - Harness: keys are dispatched from the run loop and followed by a posted event; never end undo groups by hand. Main-thread stacks of stalls are written to `main-stacks.txt` (`--stack-after-ms N`). Scripts can pin defaults with a top-level `"prefs"` object. `Scripts/remote-snapshot.sh` takes window screenshots on the Air.
