import Foundation

public struct MoleInstallation: Sendable {
    public let executable: URL
    public let sessionHelper: URL

    public init(executable: URL, sessionHelper: URL) {
        self.executable = executable
        self.sessionHelper = sessionHelper
    }

    /// The app bundle carries a pinned Mole under Resources/mole and the helper in
    /// Contents/Helpers. Debug builds accept `BURROW_MOLE` and `BURROW_SESSION_HELPER`
    /// to run against a source checkout; release builds only trust their own bundle.
    public static func locate(in bundle: Bundle = .main) -> MoleInstallation? {
        let fileManager = FileManager.default
        var executable = bundle.resourceURL?.appendingPathComponent("mole/mole")
        var helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/burrow-session")
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["BURROW_MOLE"] { executable = URL(fileURLWithPath: path) }
        if let path = environment["BURROW_SESSION_HELPER"] { helper = URL(fileURLWithPath: path) }
        #endif

        guard let executable, fileManager.isExecutableFile(atPath: executable.path),
              fileManager.isExecutableFile(atPath: helper.path)
        else { return nil }
        return MoleInstallation(executable: executable, sessionHelper: helper)
    }
}

enum LaunchEnvironment {
    /// Apps launched from Finder get a bare PATH, which would hide Homebrew, npm and
    /// the other tools whose caches Mole cleans through their own commands.
    static func make(loginPath: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallback = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var entries = (loginPath ?? environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for entry in fallback where !entries.contains(entry) {
            entries.append(entry)
        }
        environment["PATH"] = entries.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        return environment
    }

    static func resolveLoginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__BURROW_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}
