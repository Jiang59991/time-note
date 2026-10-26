import Foundation

// URL.resolvingSymlinksInPath alone does not resolve a missing leaf's parent on
// every macOS version. Resolve the nearest existing ancestor, then append it.
enum ExportDestination {
    private static func canonical(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { result.appendPathComponent(component) }
        return result.path
    }
    static func isAllowed(_ destination: URL, dataDirectory: URL) -> Bool {
        let root = canonical(dataDirectory)
        let target = canonical(destination)
        return target != root && !target.hasPrefix(root + "/")
    }
}
