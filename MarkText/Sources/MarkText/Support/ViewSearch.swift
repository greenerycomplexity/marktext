import AppKit

extension NSView {
    /// Depth-first search for the first descendant of type `T`.
    /// (Do not write this as `subviews.lazy.compactMap(find).first`: `.first` on a lazy collection evaluates the
    /// closure twice per element, which makes a recursive search exponential in the view depth. That froze the
    /// main thread for seconds on every undo.)
    func firstDescendant<T: NSView>(ofType type: T.Type = T.self) -> T? {
        if let match = self as? T { return match }
        for sub in subviews { if let found = sub.firstDescendant(ofType: type) { return found } }
        return nil
    }
}
