import WebKit

/// WKUserContentController retains its handlers; this proxy avoids the controller -> handler retain cycle.
@MainActor
public final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?
    public init(_ target: any WKScriptMessageHandler) { self.target = target }
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
