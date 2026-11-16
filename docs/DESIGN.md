# MarkText 2: UX spec (design lead decisions, binding)

Principle: a calm reading surface. Chrome is system Liquid Glass; content runs under it. Use system controls, SF Symbols and semantic colors. No custom colors in chrome; the one accent is the system accent.

## Window
- Default 1100×800, min 560×420, frame autosaved, cascades.
- Title is the file name; NSDocument draws the edited dot.
- Subtitle: `1,240 words · 6 min read`, via `.navigationSubtitle`, bridged.
- The web view scrolls under the toolbar (already proven).
- Sepia sets the window background `#F6F0E4` with aqua appearance. Light and Dark force the appearance. Auto = nil.

## Toolbar (left → right)
1. System sidebar toggle.
2. (flexible space)
3. Group: mode picker, segmented, icons only with help tooltips:
   - Read: `book`
   - Split: `rectangle.split.2x1`
   - Edit: `pencil.line`
4. `ToolbarSpacer(.fixed)`.
5. Group: Find (`magnifyingglass`) and Appearance (`textformat.size`, popover).
6. `ToolbarSpacer(.fixed)`.
7. Share (`ShareLink` of the file URL).

Groups render as separate glass capsules (macOS 26 default).

## Appearance popover (~260pt wide, padding 16, spacing 14)
- **Theme:** four 28pt circular swatches (Auto is a half light / half dark circle, then Light, Dark, Sepia). The selected one gets a 2pt accent ring. Labels go in the help tooltips; no visible caption text.
- **Typeface:** three 64×44 tiles, each showing "Aa" in its own font (SF, New York, SF Mono), with the label beneath in 11pt secondary. The selected tile has an accent stroke.
- **Size:** `A` small, a slider (13–24, step 1), `A` large. Commands ⌘+ / ⌘− / ⌘0 do the same.
- **Width:** segmented Narrow | Wide.
- Values persist via `@AppStorage` and apply to all windows live.

## Sidebar: Outline
- Plain `List(selection:)` driven by headings. Indent 14pt per level relative to the document's minimum level.
- Text is 13pt. The top level uses `.primary`, deeper levels use `.secondary`.
- The current heading (from `activeHeading`) is the selection, so it shows the system selection style. Clicking a heading calls `scrollToHeading`.
- Visible by default when the document has ≥ 3 headings. After the user toggles it, remember that choice (`@AppStorage`).
- Empty: `ContentUnavailableView("No Headings", systemImage: "list.bullet.indent")`.
- Sidebar width: 200 ideal, min 160, max 320.

## Modes
- **Read:** preview only.
- **Split:** editor | preview at 50/50, resizable (`HSplitView`, or an NSSplitView wrapper if HSplitView is janky). Editor scroll drives preview scroll (top visible source line → `scrollToLine`).
- **Edit:** editor only.
- Shortcuts: ⌘E toggles Read ↔ Split; ⌥⌘E opens Edit; ⌘1/⌘2/⌘3 select Read/Split/Edit directly. All of these live in the View menu.
- The default mode for opened documents comes from Settings (Read). A new or empty document opens in Split.
- Render debounce while typing is 80 ms. Rendering runs off the main thread, and stale results are dropped.

## Find (Read and Split)
- ⌘F shows a glass capsule (`.glassEffect(.regular, in: .capsule)`) at the top-trailing edge of the preview, 12pt below the toolbar inset.
- Contents: magnifier icon, TextField "Find" (~180pt), previous/next chevrons, close ×.
- Return and ⌘G go to the next match, ⇧Return and ⇧⌘G to the previous, Esc closes.
- When nothing matches, the field text turns `.red`; there is no extra label.
- It uses `WKWebView.find(_:configuration:)` with wraps = true and case-insensitive matching.
- In Edit mode ⌘F goes to the NSTextView find bar.

## Links
- `http(s)` and `mailto` open in the default app.
- Relative or absolute local `.md`/`.markdown` paths open in MarkText; a `#frag` on them is applied after load.
- Other local files open via NSWorkspace.
- `#frag` links scroll in-page (handled in JS).

## Empty document
- The preview shows centered `ContentUnavailableView("Empty Document", systemImage: "doc.text", description: "Press ⌘E to start writing.")`.

## Export / Print
- File menu entries:
  - Export as PDF… (⌥⌘P) uses `printOperation` with the save disposition.
  - Export as HTML… writes a standalone HTML file from the rendered DOM: CSS inlined, KaTeX fonts as data URIs (or KaTeX CSS + fonts referenced from jsDelivr if inlining is too big; prefer self-contained), mermaid as inline SVG, no scripts.
  - Print… (⌘P) uses the web view `printOperation` (override `NSDocument.printOperation(withSettings:)`).
- Margins are 54pt and the paper size follows the user's printer settings.

## Settings (⌘,)
- A single form pane, standard `Form` with `.formStyle(.grouped)`:
  - "Open documents in": Read / Split.
  - "Show outline": Automatically / Always / Never.
  - Theme, Typeface, Size and Width, mirroring the popover.
  - "Reload when the file changes on disk": on.

## Editor
- `NSTextView` (TextKit 2), SF Mono 13.5pt, line height 1.5×, transparent background.
- Text container width is capped at 760pt and centered via insets, with 24pt top/bottom insets plus the toolbar inset.
- Highlighting:
  - Heading lines are semibold, with `#` marks in tertiary.
  - `**bold**` is semibold and `*em*` italic, with markers in tertiary.
  - Inline code and fences use `systemPink` at 90%, and fence lines are tertiary.
  - Link text uses the accent; the URL is tertiary.
  - Blockquotes are secondary; list markers and task boxes are tertiary; `$math$` uses `systemPurple`.
  - On sepia, use the warm text colors from the CSS.
- Behaviour: undo goes through the document's undo manager; continuous spellcheck is on; smart quotes, dashes and text replacement are off; `usesFindBar` and incremental search are on; tab inserts 4 spaces in lists? No: plain tab.
- Newline continues list/quote/task markers: Return after `- item` inserts `- `, and Return on an empty marker line removes the marker.
