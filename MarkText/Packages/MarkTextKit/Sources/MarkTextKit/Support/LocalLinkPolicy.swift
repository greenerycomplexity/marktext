import Foundation
import UniformTypeIdentifiers

/// Links in a document must never launch code. Applications, executables, scripts and
/// directories/packages are revealed in Finder instead of opened.
public enum LocalLinkPolicy {
    public static func shouldRevealInsteadOfOpen(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isApplicationKey, .contentTypeKey, .isExecutableKey, .isRegularFileKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return false }
        if v.isDirectory == true || v.isPackage == true || v.isApplication == true { return true }
        if let type = v.contentType {
            let dangerous: [UTType] = [.application, .executable, .script, .shellScript, .unixExecutable]
            if dangerous.contains(where: { type.conforms(to: $0) }) { return true }
        }
        return false
    }
}
