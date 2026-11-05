import Foundation

// MARK: mo status --json / --watch

public struct StatusSnapshot: Decodable, Sendable, Equatable {
    public let collectedAt: String
    public let host: String
    public let uptime: String
    public let procs: Int
    public let hardware: Hardware
    public let healthScore: Int
    public let healthScoreMsg: String
    public let cpu: CPU
    public let memory: Memory
    public let disks: [Disk]
    public let trashSize: Int64
    public let network: [NetworkInterface]
    public let batteries: [Battery]?
    public let thermal: Thermal?
    public let topProcesses: [ProcessUsage]?

    public struct Hardware: Decodable, Sendable, Equatable {
        public let model: String
        public let cpuModel: String
        public let totalRam: String
        public let diskSize: String
        public let osVersion: String
    }

    public struct CPU: Decodable, Sendable, Equatable {
        public let usage: Double
        public let perCore: [Double]?
        public let load1: Double
        public let load5: Double
        public let load15: Double
        public let coreCount: Int
        public let pCoreCount: Int?
        public let eCoreCount: Int?
    }

    public struct Memory: Decodable, Sendable, Equatable {
        public let used: Int64
        public let total: Int64
        public let usedPercent: Double
        public let swapUsed: Int64
        public let swapTotal: Int64
        public let pressure: String?
    }

    public struct Disk: Decodable, Sendable, Equatable, Identifiable {
        public let mount: String
        public let used: Int64
        public let total: Int64
        public let usedPercent: Double
        public let external: Bool
        public var id: String { mount }
    }

    public struct NetworkInterface: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let rxRateMbs: Double
        public let txRateMbs: Double
        public let ip: String
        public var id: String { name }
    }

    public struct Battery: Decodable, Sendable, Equatable {
        public let percent: Double
        public let status: String
        public let timeLeft: String
        public let health: String
        public let cycleCount: Int
        public let capacity: Int
    }

    public struct Thermal: Decodable, Sendable, Equatable {
        public let cpuTemp: Double
        public let batteryTemp: Double
        public let fanSpeed: Int
        public let systemPower: Double
    }

    public struct ProcessUsage: Decodable, Sendable, Equatable, Identifiable {
        public let pid: Int
        public let name: String
        public let cpu: Double
        public let memoryBytes: Int64
        public var id: Int { pid }
    }
}

// MARK: mo analyze --json

public enum ScanStatus: String, Decodable, Sendable {
    case complete, partial, unavailable
}

public struct DiskReport: Decodable, Sendable, Equatable {
    public let scanStatus: ScanStatus
    public let path: String
    public let overview: Bool
    public let entries: [DiskEntry]
    public let largeFiles: [LargeFile]?
    public let totalSize: Int64
    public let totalFiles: Int64?
}

public struct DiskEntry: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public let scanStatus: ScanStatus
    public let name: String
    public let path: String
    public let size: Int64
    public let isDir: Bool
    public let insight: Bool?
    public let cleanable: Bool?
    public let lastAccess: String?
    public var id: String { path }
}

public struct LargeFile: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    public let path: String
    public let size: Int64
    public var id: String { path }
}

// MARK: mo history --json

public struct HistoryReport: Decodable, Sendable, Equatable {
    public let sessions: [HistorySession]
    public let deletions: [HistoryDeletion]
}

public struct HistorySession: Decodable, Sendable, Equatable, Identifiable {
    public let command: String
    public let runId: String
    public let startedAt: String
    public let endedAt: String
    public let items: Int
    public let size: String
    public let operationCount: Int
    public let failedTasks: Int
    public let actions: Actions
    public var id: String { "\(command)|\(startedAt)|\(runId)" }

    public var isPreview: Bool { command.hasSuffix("-dry-run") }

    public struct Actions: Decodable, Sendable, Equatable {
        public let removed: Int
        public let trashed: Int
        public let skipped: Int
        public let failed: Int
        public let rebuilt: Int
    }
}

public struct HistoryDeletion: Decodable, Sendable, Equatable, Identifiable {
    public let timestamp: String
    public let mode: String
    public let status: String
    public let sizeKb: Int64?
    public let path: String
    public var id: String { "\(timestamp)|\(path)" }
}

// MARK: mo uninstall --list

public struct InstalledApp: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    public let bundleId: String
    public let source: String
    public let uninstallName: String
    public let path: String
    public let size: String
    public var id: String { path }
}

public enum MoleJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}
