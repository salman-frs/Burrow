import Foundation

/// Where an app keeps a file it would leave behind, as the Apps screen groups them.
public enum FootprintPart: Int, CaseIterable, Sendable {
    case app, data, caches, settings

    public static func of(_ path: String) -> FootprintPart {
        let lowered = path.lowercased()
        if lowered.hasSuffix(".app") { return .app }
        let cacheFolders = ["/caches/", "/logs/", "/webkit/", "/httpstorages/", "/diagnosticreports/"]
        if cacheFolders.contains(where: { lowered.contains($0) || lowered.hasSuffix(String($0.dropLast())) }) {
            return .caches
        }
        let settingsFolders = ["/preferences/", "/saved application state/", "/launchagents/", "/launchdaemons/"]
        if lowered.hasSuffix(".plist") || settingsFolders.contains(where: { lowered.contains($0) }) {
            return .settings
        }
        return .data
    }
}

public enum DirectorySize {
    /// Space a file or folder takes on disk, counting each file's allocated blocks.
    public static func allocated(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
