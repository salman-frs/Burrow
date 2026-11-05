import Foundation

public struct DiskLayer: Sendable, Equatable, Identifiable {
    public let name: String
    /// nil for the space macOS manages itself, which has no folder Burrow can open.
    public let path: String?
    public let bytes: Int64
    public var id: String { path ?? name }
}

public enum DiskLayers {
    /// Mole's overview measures folders that overlap (Home contains User Library and every insight),
    /// so the layers use only the disjoint top-level folders and give the rest of the used space to macOS.
    public static func make(overview: DiskReport?, used: Int64, home: String = NSHomeDirectory()) -> [DiskLayer] {
        guard let overview else { return [DiskLayer(name: "Used", path: nil, bytes: used)] }
        let folders: [(name: String, path: String)] = [("Library", "/Library"), ("Applications", "/Applications"), ("Home", home)]
        let measured = folders.compactMap { folder -> DiskLayer? in
            guard let entry = overview.entries.first(where: { $0.path == folder.path }), entry.size > 0 else { return nil }
            return DiskLayer(name: folder.name, path: folder.path, bytes: entry.size)
        }
        let system = max(used - measured.map(\.bytes).reduce(0, +), 0)
        return [DiskLayer(name: "System", path: nil, bytes: system)] + measured
    }
}
