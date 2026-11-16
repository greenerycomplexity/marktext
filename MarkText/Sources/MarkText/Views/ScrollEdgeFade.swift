import SwiftUI

/// Soft edge between the glass toolbar and content scrolling under it. AppKit's scroll-edge styles
/// (`NSScrollEdgeEffectStyle`) only attach to split-view accessories and titlebar accessories, and
/// neither the editor's NSScrollView nor WKWebView picks one up, so this is drawn by hand:
/// a blur tinted with the window background, fading from opaque at the top to clear.
struct ScrollEdgeFade: View {
    let visible: Bool
    @AppStorage(PrefKey.theme) private var theme = Theme.auto.rawValue

    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay((theme == Theme.sepia.rawValue ? Color.sepiaPaper : Color(nsColor: .windowBackgroundColor)).opacity(0.92))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(height: inset + 16)
                .offset(y: -inset)
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: visible)
        }
        .allowsHitTesting(false)
    }
}
