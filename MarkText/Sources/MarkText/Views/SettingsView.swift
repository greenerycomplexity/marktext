import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.defaultMode) private var defaultMode = ViewMode.read.rawValue
    @AppStorage(PrefKey.outline) private var outline = OutlineVisibility.automatic.rawValue
    @AppStorage(PrefKey.theme) private var theme = Theme.auto.rawValue
    @AppStorage(PrefKey.typeface) private var typeface = Typeface.system.rawValue
    @AppStorage(PrefKey.fontSize) private var size = 16.0
    @AppStorage(PrefKey.width) private var width = LineWidth.narrow.rawValue
    @AppStorage(PrefKey.reloadOnChange) private var reload = true
    @AppStorage(PrefKey.showFrontMatter) private var frontMatter = false

    var body: some View {
        Form {
            Section("Documents") {
                Picker("Open documents in", selection: $defaultMode) {
                    Text("Read").tag(ViewMode.read.rawValue)
                    Text("Split").tag(ViewMode.split.rawValue)
                }
                Picker("Show outline", selection: $outline) {
                    ForEach(OutlineVisibility.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Show front matter", isOn: $frontMatter)
                Toggle("Reload when the file changes on disk", isOn: $reload)
            }
            Section("Appearance") {
                Picker("Theme", selection: $theme) { ForEach(Theme.allCases) { Text($0.label).tag($0.rawValue) } }
                Picker("Typeface", selection: $typeface) { ForEach(Typeface.allCases) { Text($0.label).tag($0.rawValue) } }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $size, in: PrefKey.sizeRange, step: 1)
                        Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Width", selection: $width) { ForEach(LineWidth.allCases) { Text($0.label).tag($0.rawValue) } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
