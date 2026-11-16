import SwiftUI

/// Theme / typeface / size / width. Settings are `@AppStorage`, so every window updates live.
struct AppearancePopover: View {
    @AppStorage(PrefKey.theme) private var theme = Theme.auto.rawValue
    @AppStorage(PrefKey.typeface) private var typeface = Typeface.system.rawValue
    @AppStorage(PrefKey.fontSize) private var size = 16.0
    @AppStorage(PrefKey.width) private var width = LineWidth.narrow.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            spread(Theme.allCases) { t in
                ThemeSwatch(theme: t, selected: theme == t.rawValue) { theme = t.rawValue }
            }
            spread(Typeface.allCases) { f in
                TypefaceTile(face: f, selected: typeface == f.rawValue) { typeface = f.rawValue }
            }
            HStack(spacing: 8) {
                Text("A").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { size }, set: { size = $0.rounded() }), in: PrefKey.sizeRange)   // no step: no tick marks
                Text("A").font(.system(size: 20)).foregroundStyle(.secondary)
            }
            // Hand-rolled so it spans the popover: a segmented Picker ignores maxWidth on macOS.
            HStack(spacing: 2) {
                ForEach(LineWidth.allCases) { w in
                    Button { width = w.rawValue } label: {
                        Text(w.label).frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(width == w.rawValue ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(width: 260)
    }
}

private func spread<Item: Identifiable, Content: View>(_ items: [Item], @ViewBuilder _ content: @escaping (Item) -> Content) -> some View {
    HStack(spacing: 0) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Spacer(minLength: 8) }
            content(item)
        }
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch theme {
                case .auto: Circle().fill(LinearGradient(stops: [.init(color: .white, location: 0.5), .init(color: Color(white: 0.12), location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                case .light: Circle().fill(.white)
                case .dark: Circle().fill(Color(white: 0.12))
                case .sepia: Circle().fill(Color.sepiaPaper)
                }
            }
            .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-4).opacity(selected ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(theme.label)
        .accessibilityLabel(theme.label)
    }
}

struct TypefaceTile: View {
    let face: Typeface
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("Aa").font(face.font)
                    .frame(width: 64, height: 44)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
                Text(face.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
