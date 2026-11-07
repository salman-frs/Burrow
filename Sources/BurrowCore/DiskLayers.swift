import Foundation

public struct DiskLayer: Sendable, Equatable, Identifiable {
    public let name: String
    /// nil for the space macOS manages itself, which has no folder Burrow can open.
    public let path: String?
    public let bytes: Int64
    public var id: String { path ?? name }
}

public enum DiskLayers {
    /// Mole's overview measures Home without ~/Library and lists ~/Library on its own, while its
    /// insights overlap both. Home's layer adds the two back together, as opening the folder shows,
    /// and the rest of the used space goes to macOS.
    public static func make(overview: DiskReport?, used: Int64, home: String = NSHomeDirectory()) -> [DiskLayer] {
        guard let overview else { return [DiskLayer(name: "Used", path: nil, bytes: used)] }
        func size(of path: String) -> Int64 {
            overview.entries.first { $0.path == path }.map { max($0.size, 0) } ?? 0
        }
        let folders: [(name: String, path: String, bytes: Int64)] = [
            ("Library", "/Library", size(of: "/Library")),
            ("Applications", "/Applications", size(of: "/Applications")),
            ("Home", home, size(of: home) + size(of: home + "/Library")),
        ]
        let measured = folders.filter { $0.bytes > 0 }.map { DiskLayer(name: $0.name, path: $0.path, bytes: $0.bytes) }
        let system = max(used - measured.map(\.bytes).reduce(0, +), 0)
        return [DiskLayer(name: "System", path: nil, bytes: system)] + measured
    }
}
