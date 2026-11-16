import AppKit

// Pure AppKit lifecycle: SwiftUI is only used for views. A SwiftUI `App` owns (and can rebuild) the main menu
// and swallows menu actions such as Settings, which is exactly what broke ⌘, and ⌘Q.
PrefKey.registerDefaults()
Harness.prepareDefaults()
UIScript.prepareDefaults()
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
