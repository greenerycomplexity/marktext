import AppKit
import Darwin
import Foundation

#if DEBUG

/// Main-thread stack capture that also works while main is hard-blocked (`sample` returns empty call graphs over
/// ssh): the watchdog thread signals the main thread, whose handler writes its own backtrace to a file.
nonisolated enum MainStacks {
    static let capacity: Int32 = 512
    nonisolated(unsafe) static var fd: Int32 = -1
    nonisolated(unsafe) static var mainThread: pthread_t?
    nonisolated(unsafe) static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(capacity))
    /// Frames captured by the handler; -1 while a capture is pending. Written on main, polled by the watchdog thread.
    nonisolated(unsafe) static var captured: Int32 = 0
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var previousPreprocessor: objc_exception_preprocessor?

    /// CPU time the main thread has used so far, in ms (callable from any thread). A stall whose CPU time is far
    /// below its wall time was waiting (IPC, preemption), not computing.
    static func mainCPUMs() -> Double {
        guard let mainThread else { return 0 }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(pthread_mach_thread_np(mainThread), thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000 + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    /// Call on the main thread.
    static func install(out: URL) {
        _ = frames
        mainThread = pthread_self()
        fd = open(out.appending(path: "main-stacks.txt").path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        var action = sigaction()
        // The handler only walks the stack (microseconds). Symbolication happens on the watchdog thread: doing it
        // here took longer than the sampling interval and starved the main thread.
        action.__sigaction_u.__sa_handler = { _ in MainStacks.captured = backtrace(MainStacks.frames, MainStacks.capacity) }
        action.sa_flags = SA_RESTART
        sigaction(SIGUSR1, &action, nil)
    }

    nonisolated(unsafe) static var pending: [(header: String, frames: [UnsafeMutableRawPointer?])] = []

    /// Call from the watchdog thread: records the main thread's current stack under `header`.
    static func capture(_ header: String) {
        guard fd >= 0, let mainThread, count < 20000 else { return }
        count += 1
        captured = -1
        pthread_kill(mainThread, SIGUSR1)
        var spins = 0
        while captured < 0, spins < 400 { usleep(50); spins += 1 }
        guard captured > 0 else { return }
        pending.append((header, Array(UnsafeBufferPointer(start: frames, count: Int(captured)))))
    }

    /// Call from the watchdog thread, between stalls: symbolicates and writes what `capture` recorded.
    static func flush() {
        for (header, stack) in pending {
            let line = "=== \(header)\n"
            _ = line.withCString { write(fd, $0, strlen($0)) }
            stack.withUnsafeBufferPointer { backtrace_symbols_fd($0.baseAddress, Int32($0.count), fd) }
            _ = write(fd, "\n", 1)
        }
        pending.removeAll(keepingCapacity: true)
    }
}

/// `MarkText --ui-script steps.json --out dir`: replays keyboard-level UI scripts in a background (.accessory)
/// app. Keys are synthesized `NSEvent`s sent through `NSApp.sendEvent`, so key equivalents go through the real
/// main menu and responder chain. The app is never activated; its windows are ordered back and made key
/// within the app only. A watchdog thread records main-thread stalls and takes `sample` stacks of them.
enum UIScript {
    struct Config { var script: URL; var out: URL }

    static let config: Config? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--ui-script"), i + 1 < a.count else { return nil }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let out = a.firstIndex(of: "--out").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } ?? "ui-out"
        return Config(script: URL(fileURLWithPath: a[i + 1], relativeTo: cwd).standardizedFileURL,
                      out: URL(fileURLWithPath: out, relativeTo: cwd).standardizedFileURL)
    }()
    static var isActive: Bool { config != nil }

    static func prepareDefaults() {
        guard isActive else { return }
        // AppKit catches Objective-C exceptions at the top of the run loop and carries on; log every throw with its stack.
        MainStacks.previousPreprocessor = objc_setExceptionPreprocessor { exception in
            if let e = exception as? NSException {
                Harness.log("OBJC EXCEPTION \(e.name.rawValue): \(e.reason ?? "")\n" + Thread.callStackSymbols.prefix(45).joined(separator: "\n"))
            }
            return MainStacks.previousPreprocessor?(exception) ?? exception
        }
        let a = CommandLine.arguments
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        Harness.applyLaunchOverrides(&domain)
        // A script can pin defaults ("prefs": {"NSCloseAlwaysConfirmsChanges": "YES"}) so it does not depend on the machine's settings.
        if let c = config, let data = try? Data(contentsOf: c.script), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefs = json["prefs"] as? [String: Any] { domain.merge(prefs) { $1 } }
        for (n, x) in a.enumerated() where x == "--pref" && n + 1 < a.count {
            let kv = a[n + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { domain[kv[0]] = kv[1] }
        }
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    // MARK: Watchdog

    struct Stall { var at: Double; var ms: Double; var cpuMs: Double; var step: String; var sample: String? }

    nonisolated final class Answer: @unchecked Sendable { var at: DispatchTime? }

    nonisolated final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var _step = "(start)"
        private var _paused = false
        var paused: Bool { get { lock.withLock { _paused } } set { lock.withLock { _paused = newValue } } }
        private var _stalls: [Stall] = []
        private var _latencies: [Double] = []
        var latencies: [Double] { lock.withLock { _latencies } }
        private var running = true
        private var samples = 0
        private var sampleCountByStep: [String: Int] = [:]   // a per-step budget so launch/open stalls don't use up all samples
        private let t0 = DispatchTime.now()
        /// A main-thread ping that has waited this long gets its stack captured every 10 ms (`--stack-after-ms`).
        let stackAfterMs: Double = {
            let a = CommandLine.arguments
            return a.firstIndex(of: "--stack-after-ms").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } ?? 60
        }()
        var step: String { get { lock.withLock { _step } } set { lock.withLock { _step = newValue } } }
        var stalls: [Stall] { lock.withLock { _stalls } }
        func stop() { lock.withLock { running = false } }

        func start(pid: Int32, out: URL) {
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    Thread.sleep(forTimeInterval: 0.05)
                    if paused { Thread.sleep(forTimeInterval: 0.45); continue }   // idle CPU measurement: the watchdog itself must not cost CPU
                    let answer = Answer()
                    let sent = DispatchTime.now()
                    let cpuAtSend = MainStacks.mainCPUMs()
                    let stepAtSend = step
                    DispatchQueue.main.async { self.lock.withLock { answer.at = DispatchTime.now() } }
                    var sampled: String?
                    var nextStackAt = stackAfterMs
                    while true {
                        let done = lock.withLock { answer.at != nil }
                        let waited = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e6
                        if done { break }
                        if waited >= nextStackAt {
                            MainStacks.capture("step \(stepAtSend) | waited \(Int(waited)) ms")
                            nextStackAt = waited + (waited > 3000 ? 2000 : 4)
                            if waited > 3000 { MainStacks.flush() }
                        }
                        if waited > 100, sampled == nil, samples < 12, sampleCountByStep[stepAtSend, default: 0] < 2 {
                            sampleCountByStep[stepAtSend, default: 0] += 1
                            samples += 1
                            let path = out.appending(path: "sample-\(samples).txt").path
                            sampled = path
                            let p = Process()
                            p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                            p.arguments = ["\(pid)", "1", "-file", path]
                            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                            try? p.run()   // runs while the stall is (hopefully) still in progress
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    let cpu = MainStacks.mainCPUMs() - cpuAtSend
                    MainStacks.flush()
                    let total = lock.withLock { Double(answer.at!.uptimeNanoseconds - sent.uptimeNanoseconds) / 1e6 }
                    lock.withLock { _latencies.append(total) }
                    if total > 100 {
                        let at = Double(sent.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                        lock.withLock { _stalls.append(Stall(at: at, ms: total, cpuMs: cpu, step: stepAtSend, sample: sampled)) }
                    }
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    @MainActor final class RunState {
        var stepLog: [[String: Any]] = []
        var assertions: [[String: Any]] = []
        var vars: [String: Any] = [:]
        var metrics: [String: Any] = [:]
        var scriptJS = 0
        var expectTerminate = false
        var modalSeen: [String] = []
        var keyLog: [String] = []
        var menuDumps: [(String, String)] = []
    }

    // MARK: Runner

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    @MainActor
    static func run(_ c: Config) async {
        try? FileManager.default.createDirectory(at: c.out, withIntermediateDirectories: true)
        let st = RunState()
        let pid = ProcessInfo.processInfo.processIdentifier
        // The harness app is never frontmost and its windows sit behind everything, so macOS treats it as background
        // work (App Nap, efficiency cores): identical steps then took anywhere from 1x to 5x as long. Run it the way
        // the frontmost app a user is working in runs.
        let activity = CommandLine.arguments.contains("--no-activity") ? nil : ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "UI script")
        _ = activity
        let dog = Watchdog()
        MainStacks.install(out: c.out)
        dog.start(pid: pid, out: c.out)
        /// Runs `body` straight from the main run loop, the way AppKit delivers a real key event. The script itself
        /// runs in a Swift task, i.e. inside a main-queue job, and code that waits for the main queue from there
        /// (NSDocument's synchronous autosave on close) can never be serviced.
        func onRunLoop(_ body: @escaping @MainActor () -> Void) async {
            guard !CommandLine.arguments.contains("--keys-from-task") else { body(); return }
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    MainActor.assumeIsolated { body() }
                    k.resume()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            // AppKit closes the undo manager's by-event group when it fetches the next event. A background app gets
            // no events, so the group typing opened would stay open (document never marked edited). Send one
            // through the real queue. (Ending the group by hand left NSUndoManager's own bookkeeping behind, and
            // NSDocument's commit-editing step on close then threw "endUndoGrouping called with no matching begin".)
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
        }
        let started = Date()

        func currentWindow() -> NSWindow? {
            (NSApp.keyWindow as? DocumentWindow) ?? NSApp.windows.last { $0.windowController is DocumentWindowController && $0.isVisible }
        }
        func currentDoc() -> MarkdownDocument? {
            (NSApp.keyWindow?.windowController?.document as? MarkdownDocument) ?? (NSDocumentController.shared.documents.last as? MarkdownDocument)
        }
        func editorView() -> NSTextView? { currentDoc()?.windowControllers.first?.window?.contentView?.firstDescendant() }
        func adopt(_ doc: NSDocument?) {
            guard let w = doc?.windowControllers.first?.window else { return }
            w.orderBack(nil)
            w.makeKey()
            // An inactive app has no key window, so AppKit would route menu actions into the void. Make this window the
            // app's key/main window (private SPI, DEBUG harness only) so real menu dispatch can be exercised.
            NSApp.perform(NSSelectorFromString("_setKeyWindow:"), with: w)
            NSApp.perform(NSSelectorFromString("_setMainWindow:"), with: w)
        }
        /// An inactive (.accessory) app cannot have a key window, so AppKit would drop menu key equivalents. Look the
        /// shortcut up in the real main menu and dispatch its action along the real responder chain of the
        /// document window instead (first responder -> views -> window -> window controller -> document -> app).
        func performMenuShortcut(_ chars: String, mods: NSEvent.ModifierFlags) -> Bool {
            func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
            guard let menu = NSApp.mainMenu, let w = currentWindow() else { return false }
            let want = mods.intersection(.deviceIndependentFlagsMask)
            guard let item = items(menu).first(where: {
                !$0.keyEquivalent.isEmpty && $0.keyEquivalent.lowercased() == chars.lowercased()
                    && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == want && $0.action != nil
            }), let action = item.action else { return false }
            let start: NSResponder = w.firstResponder ?? w
            if start.tryToPerform(action, with: item) { return true }
            return NSApp.sendAction(action, to: nil, from: item)
        }
        func send(_ chars: String, keyCode: UInt16, mods: NSEvent.ModifierFlags, ignoring: String? = nil) {
            guard let w = currentWindow() else { return }
            if mods.contains(.command) {
                // Without a key window (inactive .accessory app) AppKit's own menu dispatch sends actions into the void:
                // `performKeyEquivalent` returns true but nothing handles them. So find the item in the real installed
                // menu and dispatch its action along the document window's responder chain; AppKit's own matching is the fallback.
                let viaChain = performMenuShortcut(ignoring ?? chars, mods: mods)
                var viaMenu = false
                if !viaChain, let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ignoring ?? chars,
                                             isARepeat: false, keyCode: keyCode) {
                    viaMenu = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
                }
                let ours = NSApp.mainMenu === MainMenu.installed
                st.keyLog.append("cmd-key '\(ignoring ?? chars)' mods=\(mods.rawValue >> 16): chainDispatch=\(viaChain) menuPerformKeyEquivalent=\(viaMenu) ourMenuInstalled=\(ours) titles=\(NSApp.mainMenu?.items.map(\.title).joined(separator: ",") ?? "nil")")
                if viaMenu || viaChain { return }
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: keyCode) {
                    NSApp.sendEvent(e)
                }
            }
        }
        func parseCombo(_ combo: String) -> (chars: String, keyCode: UInt16, mods: NSEvent.ModifierFlags) {
            var mods: NSEvent.ModifierFlags = []
            var key = ""
            for part in combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
                switch part {
                case "cmd", "command": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt", "alt", "option": mods.insert(.option)
                case "ctrl", "control": mods.insert(.control)
                default: key = part.isEmpty ? "+" : part
                }
            }
            switch key {
            case "return", "enter": return ("\r", 36, mods)
            case "esc", "escape": return ("\u{1B}", 53, mods)
            case "tab": return ("\t", 48, mods)
            case "delete", "backspace": return ("\u{7F}", 51, mods)
            case "comma": return (",", 43, mods)
            default: return (key, keyCodes[key.first ?? " "] ?? 0, mods)
            }
        }
        func menuTree() -> String {
            func dump(_ m: NSMenu, _ indent: String) -> [String] {
                m.items.flatMap { item -> [String] in
                    let line = item.isSeparatorItem ? "\(indent)---" : "\(indent)\(item.title) | key=\(item.keyEquivalent.isEmpty ? "-" : item.keyEquivalent) mods=\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue >> 16) | action=\(item.action.map { NSStringFromSelector($0) } ?? "-")"
                    return [line] + (item.submenu.map { dump($0, indent + "  ") } ?? [])
                }
            }
            return NSApp.mainMenu.map { dump($0, "").joined(separator: "\n") } ?? "<no main menu>"
        }
        func sendCombo(_ combo: String) {
            var mods: NSEvent.ModifierFlags = []
            var key = ""
            for part in combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
                switch part {
                case "cmd", "command": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt", "alt", "option": mods.insert(.option)
                case "ctrl", "control": mods.insert(.control)
                default: key = part.isEmpty ? "+" : part
                }
            }
            switch key {
            case "return", "enter": send("\r", keyCode: 36, mods: mods)
            case "esc", "escape": send("\u{1B}", keyCode: 53, mods: mods)
            case "tab": send("\t", keyCode: 48, mods: mods)
            case "delete", "backspace": send("\u{7F}", keyCode: 51, mods: mods)
            case "comma": send(",", keyCode: 43, mods: mods)
            default:
                let ch = key.first ?? " "
                send(key, keyCode: keyCodes[ch] ?? 0, mods: mods)
            }
        }
        func buttons(in v: NSView) -> [NSButton] {
            (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons)
        }
        func ps(_ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cpuSeconds(_ pid: Int32) -> Double {
            // proc_pid_rusage: exact CPU time (ps only has 10 ms resolution, which is noise over a 10 s window).
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { return 0 }
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            return Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9
        }
        func webPID() -> Int32? {
            (currentDoc()?.model.preview.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        }
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            st.assertions.append(["name": name, "pass": pass, "detail": detail])
        }

        guard let data = try? Data(contentsOf: c.script),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = json["steps"] as? [[String: Any]] else {
            Harness.log("ui-script: cannot read \(c.script.path)"); exit(2)
        }

        /// Writes ui-report.json. Also runs when the script makes the app quit (⌘Q), so termination can be asserted.
        func writeReport() {
            dog.stop()
            var m = st.metrics
            m["totalJSCalls"] = currentDoc()?.model.preview.jsCallCount ?? 0
            m["scriptJSCalls"] = st.scriptJS
            m["wallSeconds"] = Date().timeIntervalSince(started)
            let lat = dog.latencies.sorted()
            if !lat.isEmpty {
                m["mainPingAvgMs"] = lat.reduce(0, +) / Double(lat.count)
                m["mainPingP95Ms"] = lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))]
                m["mainPingMaxMs"] = lat.last!
            }
            var rep: [String: Any] = [:]
            rep["steps"] = st.stepLog
            rep["assertions"] = st.assertions
            rep["stalls"] = dog.stalls.map { ["atSeconds": $0.at, "ms": $0.ms, "cpuMs": $0.cpuMs, "step": $0.step, "sample": $0.sample ?? NSNull()] as [String: Any] }
            rep["vars"] = st.vars.mapValues { "\($0)" }
            rep["keyLog"] = st.keyLog
            rep["metrics"] = m
            rep["pass"] = st.assertions.allSatisfy { ($0["pass"] as? Bool) == true }
            if let d = try? JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: c.out.appending(path: "ui-report.json"))
            }
            Harness.log("ui-script done: pass=\(rep["pass"] ?? false) st.assertions=\(st.assertions.count) stalls=\(dog.stalls.count)")
        }
        let terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                check("app terminated (willTerminate)", st.expectTerminate, st.expectTerminate ? "terminating as expected" : "terminated unexpectedly")
                writeReport()
            }
        }
        _ = terminateObserver
        // Never leave a Debug --ui-script process behind, whatever the script does.
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) { exit(3) }
        func scheduleModalDismiss(afterMs ms: Int, button: String?) {
            // A Timer in the common modes: the main dispatch queue is not serviced while an app-modal panel runs.
            let timer = Timer(timeInterval: Double(ms) / 1000, repeats: false) { _ in
                MainActor.assumeIsolated {
                    Harness.log("modal timer: modalWindow=\(String(describing: NSApp.modalWindow)) windows=\(NSApp.windows.map { "\(type(of: $0)) vis=\($0.isVisible) sheet=\(String(describing: $0.attachedSheet.map { "\(type(of: $0))" }))" })")
                    if NSApp.modalWindow == nil, let panel = NSApp.windows.first(where: { $0 is NSSavePanel }) as? NSSavePanel {   // NSOpenPanel is not app-modal here
                        st.modalSeen.append("\(type(of: panel)) (non-modal)"); panel.cancel(nil); return
                    }
                    guard let w = NSApp.modalWindow else { st.modalSeen.append("none"); return }
                    st.modalSeen.append("\(type(of: w)): \(w.contentView.map(buttons)?.map(\.title) ?? [])")
                    if let button, let b = w.contentView.map(buttons)?.first(where: { $0.title == button }) {
                        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: b.tag))
                    } else if let panel = w as? NSSavePanel { panel.cancel(nil) }
                    else { NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        for (i, step) in steps.enumerated() {
            let op = step["op"] as? String ?? "?"
            dog.step = "\(i):\(op) \((step["text"] ?? step["combo"] ?? step["what"] ?? "") )"
            Harness.log("step \(i) \(op)")
            let t0 = Date()
            let jsBefore = currentDoc()?.model.preview.jsCallCount ?? 0
            switch op {
            case "newDocument":
                if let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(false) as? MarkdownDocument {
                    if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
                    adopt(doc)
                }
            case "open":
                let url = URL(fileURLWithPath: step["path"] as? String ?? "")
                if let (doc, _) = try? await NSDocumentController.shared.openDocument(withContentsOf: url, display: false) {
                    if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
                    adopt(doc)
                }
            case "markEdited":
                currentDoc()?.updateChangeCount(.changeDone)
            case "probeClose":
                let w = currentWindow()
                let wc = w?.windowController
                Harness.log("probeClose: window=\(String(describing: w)) delegate=\(String(describing: w?.delegate)) wcIsDelegate=\(w?.delegate === wc) closable=\(w?.styleMask.contains(.closable) ?? false) doc=\(String(describing: wc?.document)) shouldCloseDocument=\(wc?.shouldCloseDocument ?? false) edited=\(currentDoc()?.isDocumentEdited ?? false) hasUnautosaved=\(currentDoc()?.hasUnautosavedChanges ?? false) isDraft=\(currentDoc()?.isDraft ?? false)")
            case "dumpMenu":
                let name = step["name"] as? String ?? "menu"
                let tree = menuTree()
                st.vars["menu:" + name] = tree
                st.menuDumps.append((name, tree))
            case "realKey":
                // AppKit's own key-equivalent matcher against the installed main menu: no harness dispatch involved.
                let (chars, code, mods) = parseCombo(step["combo"] as? String ?? "")
                guard let w = currentWindow() else { check("realKey", false, "no window"); break }
                if step["dismissModalAfterMs"] != nil { scheduleModalDismiss(afterMs: step["dismissModalAfterMs"] as? Int ?? 800, button: nil) }
                if step["expectTerminate"] as? Bool == true { st.expectTerminate = true }
                let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
                let handled = ev.flatMap { NSApp.mainMenu?.performKeyEquivalent(with: $0) } ?? false
                let want = step["handled"] as? Bool ?? true
                check("AppKit performKeyEquivalent(\(step["combo"] ?? "")) == \(want)", handled == want,
                      "handled=\(handled) keyWindow=\(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil") firstResponder=\(type(of: w.firstResponder as Any)) menuIsOurs=\(NSApp.mainMenu === MainMenu.installed)")
                NSApp.windows.filter { $0.windowController is DocumentWindowController && $0.isVisible }.forEach { $0.orderBack(nil) }
            case "focusPreview":
                if let d = currentDoc(), let w = d.windowControllers.first?.window { w.makeFirstResponder(d.model.preview.webView) }
            case "menuAudit":
                // Resolve every main-menu action along the real responder chain from the current first responder.
                guard let w = currentWindow(), let menu = NSApp.mainMenu else { check("menuAudit", false, "no window or menu"); break }
                var chain: [AnyObject] = []
                var r: NSResponder? = w.firstResponder ?? w
                while let x = r { chain.append(x); r = x.nextResponder }
                [w.delegate as AnyObject?, w.windowController, w.windowController?.document, NSApp, NSApp.delegate as AnyObject?, NSDocumentController.shared].forEach { if let o = $0, !chain.contains(where: { $0 === o }) { chain.append(o) } }
                func allItems(_ m: NSMenu, _ path: String) -> [(NSMenuItem, String)] {
                    m.items.flatMap { item -> [(NSMenuItem, String)] in
                        let p = path + "/" + item.title
                        return [(item, p)] + (item.submenu.map { allItems($0, p) } ?? [])
                    }
                }
                var missing: [String] = [], disabled: [String] = [], seen: [String: String] = [:], conflicts: [String] = []
                var count = 0
                for (item, path) in allItems(menu, "") where !item.isSeparatorItem {
                    guard let action = item.action, item.submenu == nil else { continue }
                    count += 1
                    // Items AppKit injects into Edit itself (Dictation, Emoji & Symbols) legitimately repeat key equivalents.
                    let injected = ["startDictation:", "orderFrontCharacterPalette:"].contains(NSStringFromSelector(action))
                    if !item.keyEquivalent.isEmpty, !injected {
                        let key = "\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)+\(item.keyEquivalent)"
                        if let other = seen[key] { conflicts.append("\(path) vs \(other)") } else { seen[key] = path }
                    }
                    guard let target = chain.first(where: { $0.responds(to: action) }) else { missing.append("\(path) (\(NSStringFromSelector(action)))"); continue }
                    if let v = target as? NSMenuItemValidation, !v.validateMenuItem(item) { disabled.append(path) }
                }
                st.vars["menuAudit"] = "items=\(count) missing=\(missing) disabled=\(disabled) conflicts=\(conflicts) firstResponder=\(type(of: w.firstResponder as Any))"
                check("menuAudit: every action has a target (first responder \(type(of: w.firstResponder as Any)))", missing.isEmpty, "\(missing)")
                check("menuAudit: no duplicate key equivalents", conflicts.isEmpty, "\(conflicts)")
            case "caretToEnd":
                if let tv = editorView() { tv.window?.makeFirstResponder(tv); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
            case "focusEditor":
                if let tv = editorView() { tv.window?.makeFirstResponder(tv) }
            case "type":
                for ch in (step["text"] as? String ?? "") {
                    await onRunLoop {
                        if ch == "\n" { send("\r", keyCode: 36, mods: []) }
                        else {
                            let upper = ch.isUppercase && ch.isLetter
                            send(String(ch), keyCode: keyCodes[Character(ch.lowercased())] ?? 0, mods: upper ? [.shift] : [], ignoring: String(ch).lowercased())
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(Int(step["gapMs"] as? Int ?? 30)))
                }
                // Let the posted events drain, so the undo group of the last key is closed before the next step.
                try? await Task.sleep(for: .milliseconds(50))
                Harness.log("after type: groupingLevel=\(currentDoc()?.undoManager?.groupingLevel ?? -1) edited=\(currentDoc()?.isDocumentEdited ?? false)")
            case "key":
                if step["sample"] as? Bool == true {   // stacks for exactly this step (the watchdog only starts after 100 ms)
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    p.arguments = ["\(pid)", "3", "-file", c.out.appending(path: "step-\(i)-sample.txt").path]
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    try? p.run(); try? await Task.sleep(for: .milliseconds(500))
                }
                if step["expectTerminate"] as? Bool == true { st.expectTerminate = true }
                if let ms = step["dismissModalAfterMs"] as? Int { scheduleModalDismiss(afterMs: ms, button: step["modalButton"] as? String) }
                let combo = step["combo"] as? String ?? ""
                await onRunLoop { sendCombo(combo) }
                // Any window the action opened goes behind everything: the harness never takes the screen.
                NSApp.windows.filter { $0.windowController is DocumentWindowController && $0.isVisible }.forEach { $0.orderBack(nil) }
            case "wait":
                try? await Task.sleep(for: .milliseconds(step["ms"] as? Int ?? 100))
            case "sheetButton":
                let title = (step["title"] as? String ?? "").replacingOccurrences(of: "'", with: "’")
                Harness.log("windows: \(NSApp.windows.map { "\(type(of: $0)) vis=\($0.isVisible) sheet=\(String(describing: $0.attachedSheet)) key=\($0.isKeyWindow)" })")
                let sheet = NSApp.windows.compactMap(\.attachedSheet).first
                func labels(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels) }
                if let sheet { Harness.log("sheet text: \(sheet.contentView.map(labels) ?? []) buttons: \(sheet.contentView.map(buttons)?.map(\.title) ?? [])") }
                if let sheet, let b = sheet.contentView.map(buttons)?.first(where: { $0.title == title }) {
                    // performClick needs a live event loop tracking session; end the sheet the way the button's action does.
                    if let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: b.tag)) } else { b.performClick(nil) }
                }
                else { check("sheetButton \(title)", false, "no such button; sheet buttons: \(sheet?.contentView.map(buttons)?.map(\.title) ?? [])") }
            case "js":
                st.scriptJS += 1
                let r = await currentDoc()?.model.preview.evaluate(step["code"] as? String ?? "return null")
                if let name = step["save"] as? String { st.vars[name] = r ?? NSNull() }
            case "scroll":   // programmatic preview scroll for `ms`, one JS call per frame
                let ms = step["ms"] as? Int ?? 3000
                let busyStart = Date()
                var frames = 0
                var y = 0.0
                let end = Date().addingTimeInterval(Double(ms) / 1000)
                while Date() < end {
                    y += 12; frames += 1; st.scriptJS += 1
                    _ = await currentDoc()?.model.preview.evaluate("window.scrollTo(0, y); return true", ["y": y.truncatingRemainder(dividingBy: 3000)])
                    try? await Task.sleep(for: .milliseconds(16))
                }
                st.metrics["scrollFrames"] = frames
                st.metrics["scrollWallMs"] = Date().timeIntervalSince(busyStart) * 1000
            case "idle":
                let secs = step["seconds"] as? Double ?? 10
                dog.paused = true
                let a0 = cpuSeconds(pid), w = webPID(), w0 = w.map(cpuSeconds) ?? 0
                try? await Task.sleep(for: .seconds(secs))
                let a1 = cpuSeconds(pid), w1 = w.map(cpuSeconds) ?? 0
                dog.paused = false
                st.metrics["idleAppCPUPercent"] = (a1 - a0) / secs * 100
                st.metrics["idleWebCPUPercent"] = (w1 - w0) / secs * 100
                st.metrics["idleTotalCPUPercent"] = ((a1 - a0) + (w1 - w0)) / secs * 100
            case "expect":
                let what = step["what"] as? String ?? ""
                switch what {
                case "windowCount":
                    Harness.log("windows: \(NSApp.windows.map { "\(type(of: $0)) vis=\($0.isVisible) doc=\(String(describing: ($0.windowController as? DocumentWindowController)?.document))" })")
                    let n = NSApp.windows.filter { $0.windowController is DocumentWindowController && $0.isVisible }.count
                    check("windowCount == \(step["equals"] ?? "?")", n == (step["equals"] as? Int), "\(n)")
                case "sheetCount":
                    let n = NSApp.windows.compactMap(\.attachedSheet).count
                    check("sheetCount == \(step["equals"] ?? "?")", n == (step["equals"] as? Int), "\(n)")
                case "edited":
                    let e = currentDoc()?.isDocumentEdited ?? false
                    check("edited == \(step["equals"] ?? "?")", e == (step["equals"] as? Bool), "\(e)")
                case "settingsVisible":
                    let v = SettingsWindowController.shared.window?.isVisible ?? false
                    check("settingsVisible == \(step["equals"] ?? true)", v == (step["equals"] as? Bool ?? true), "\(v)")
                case "editorText", "modelText":
                    let text = what == "editorText" ? (editorView()?.string ?? "<no editor>") : (currentDoc()?.model.text ?? "<no doc>")
                    if let eq = step["equals"] as? String { check("\(what) == …", text == eq, text.debugDescription) }
                    if let sub = step["contains"] as? String { check("\(what) contains \(sub.debugDescription)", text.contains(sub), String(text.suffix(200)).debugDescription) }
                    if let n = step["length"] as? Int { check("\(what).count == \(n)", text.count == n, "\(text.count)") }
                case "sidebarPrefMatches":   // the native toolbar button must still record the user's choice
                    let split: NSSplitView? = currentWindow()?.contentView?.firstDescendant()
                    let collapsed = split.flatMap { s in s.arrangedSubviews.first.map { s.isSubviewCollapsed($0) } }
                    let pref = UserDefaults.standard.string(forKey: PrefKey.sidebarChoice) ?? ""
                    check("sidebar \(collapsed == true ? "collapsed" : "visible") matches sidebarChoice", (collapsed == true && pref == "hidden") || (collapsed == false && pref == "shown"),
                          "collapsed=\(String(describing: collapsed)) pref=\(pref)")
                case "fileText":
                    let text = (try? String(contentsOfFile: step["path"] as? String ?? "", encoding: .utf8)) ?? "<unreadable>"
                    if let sub = step["contains"] as? String { check("file contains \(sub.debugDescription)", text.contains(sub), String(text.suffix(120)).debugDescription) }
                case "var":
                    let name = step["name"] as? String ?? ""
                    let v = st.vars[name]
                    check("var \(name)", "\(v ?? "nil")" == "\(step["equals"] ?? "")", "\(v ?? "nil")")
                case "menuStable":
                    // AppKit appends one Window-menu entry per open window (action _activateWindow:); everything else must be identical.
                    let trees = st.menuDumps.map { ($0.0, $0.1.split(separator: "\n").filter { !$0.contains("action=_") && !$0.contains("makeKeyAndOrderFront:") && !$0.hasSuffix("---") && !$0.contains("startDictation:") }.joined(separator: "\n")) }
                    let first = trees.first?.1 ?? ""
                    let same = trees.allSatisfy { $0.1 == first }
                    check("main menu identical at \(trees.map(\.0).joined(separator: ", "))", same && !trees.isEmpty,
                          same ? "\(first.split(separator: "\n").count) lines" : trees.map { "\($0.0): \($0.1.split(separator: "\n").count) lines" }.joined(separator: " / "))
                    let lines = first.split(separator: "\n").map(String.init)
                    let comma = lines.filter { $0.contains("key=, mods=16 ") }
                    let quit = lines.filter { $0.contains("key=q mods=16 ") }
                    check("exactly one ⌘, item", comma.count == 1, "\(comma)")
                    check("exactly one ⌘Q item", quit.count == 1, "\(quit)")
                case "modalSeen":
                    let seenFirst = st.modalSeen.first(where: { $0 != "none" }) ?? "none"
                    check("modal window seen = \(step["contains"] ?? "?")", seenFirst.contains(step["contains"] as? String ?? "?"), "\(st.modalSeen)")
                case "findBarVisible":
                    let v = currentDoc()?.model.findVisible ?? false
                    check("findBarVisible == \(step["equals"] ?? true)", v == (step["equals"] as? Bool ?? true), "\(v)")
                case "editorFindBarVisible":
                    let v = editorView()?.enclosingScrollView?.isFindBarVisible ?? false
                    check("editorFindBarVisible == \(step["equals"] ?? true)", v == (step["equals"] as? Bool ?? true), "\(v)")
                case "mainMenuTitles":
                    let t = (NSApp.mainMenu?.items.map(\.title) ?? []).joined(separator: ",")
                    check("main menu = \(step["equals"] ?? "")", t == (step["equals"] as? String ?? ""), t)
                case "mode":
                    let m = currentDoc()?.model.mode.rawValue ?? "?"
                    check("mode == \(step["equals"] ?? "")", m == (step["equals"] as? String ?? ""), m)
                case "noStalls":
                    let from = step["sinceStep"] as? Int ?? 0
                    let prefix = "\(from):"
                    _ = prefix
                    let limit = step["maxMs"] as? Double ?? 100
                    // On a machine that is busy with other work (load above the core count) the main thread gets
                    // preempted for longer than the limit while doing nothing. Then only stalls in which the main
                    // thread itself used more CPU time than the limit count; the check's name says which rule applied.
                    var load = [Double](repeating: 0, count: 3)
                    getloadavg(&load, 3)
                    let busy = load[0] > Double(ProcessInfo.processInfo.activeProcessorCount)
                    let relevant = dog.stalls.filter { (busy ? $0.cpuMs : $0.ms) > limit && (Int($0.step.split(separator: ":").first ?? "") ?? 0) >= from }
                    check("no main-thread stall > \(Int(limit)) ms \(busy ? "of CPU time (machine busy, load \(Int(load[0])))" : "wall time") since step \(from)", relevant.isEmpty,
                          relevant.map { "\(Int($0.ms)) ms (cpu \(Int($0.cpuMs))) in \($0.step)" }.joined(separator: "; "))
                case "appJSCalls":   // JS round trips the app made itself (excluding the script's own)
                    let d = (currentDoc()?.model.preview.jsCallCount ?? 0) - st.scriptJS
                    check("app JS calls <= \(step["max"] ?? "?")", d <= (step["max"] as? Int ?? 0), "\(d)")
                case "jsCalls":
                    let d = (currentDoc()?.model.preview.jsCallCount ?? 0)
                    check("jsCalls <= \(step["max"] ?? "?")", d <= (step["max"] as? Int ?? 0), "\(d)")
                case "metricBelow":
                    let key = step["metric"] as? String ?? ""
                    let v = st.metrics[key] as? Double ?? -1
                    check("\(key) < \(step["max"] ?? "?")", v >= 0 && v < (step["max"] as? Double ?? 0), "\(v)")
                default:
                    check("unknown expect \(what)", false, "")
                }
            default:
                check("unknown op \(op)", false, "")
            }
            let jsAfter = currentDoc()?.model.preview.jsCallCount ?? 0
            st.stepLog.append(["index": i, "op": op, "detail": "\(step["text"] ?? step["combo"] ?? step["what"] ?? step["ms"] ?? "")",
                            "ms": Int(Date().timeIntervalSince(t0) * 1000), "jsCalls": max(0, jsAfter - jsBefore)])
            try? await Task.sleep(for: .milliseconds(step["after"] as? Int ?? 0))
        }

        writeReport()
        exit(0)
    }
}

#else

enum UIScript {
    struct Config {}
    static var config: Config? { nil }
    static var isActive: Bool { false }
    static func prepareDefaults() {}
    static func run(_ c: Config) async {}
}

#endif
