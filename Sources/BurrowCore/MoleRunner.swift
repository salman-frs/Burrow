import Darwin
import Foundation

public enum RunEvent: Sendable, Equatable {
    case line(String)
    case finished(exitCode: Int32)
}

public enum RunError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case adminDeclined
    case adminRejected
    case timedOut(String)
    case planMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "Mole could not start: \(reason)"
        case .adminDeclined: "Administrator access was cancelled."
        case .adminRejected: "macOS did not accept the password."
        case .timedOut(let step): "Mole stopped responding while \(step)."
        case .planMismatch(let reason): "Nothing was changed: \(reason)"
        }
    }
}

/// Asked for the administrator password; `attempt` counts from 1. Returning nil cancels the run.
public typealias AdminPasswordProvider = @Sendable (_ attempt: Int) async -> String?

public struct SessionOptions: Sendable {
    /// Mole only shows its menus and confirmations when stdin is a terminal.
    public var interactive = false
    /// `mo slim` also requires stdout to be a terminal before it lets anyone choose.
    public var outputOnTerminal = false
    /// Answers every sudo password prompt raised inside the run.
    public var admin: AdminPasswordProvider?
    /// `mo clean` only reuses a ticket when stdin is not a terminal, so it needs one before it starts.
    public var authenticateFirst = false
    /// Keeps stderr out of stdout, for commands whose stdout is JSON.
    public var separateErrors = false
    public var environment: [String: String] = [:]

    public init(interactive: Bool = false, outputOnTerminal: Bool = false,
                admin: AdminPasswordProvider? = nil, authenticateFirst: Bool = false,
                separateErrors: Bool = false, environment: [String: String] = [:]) {
        self.interactive = interactive
        self.outputOnTerminal = outputOnTerminal
        self.admin = admin
        self.authenticateFirst = authenticateFirst
        self.separateErrors = separateErrors
        self.environment = environment
    }
}

public final class MoleRunner: Sendable {
    public let installation: MoleInstallation
    private let environmentCache = EnvironmentCache()

    public init(installation: MoleInstallation) {
        self.installation = installation
    }

    /// Asking the login shell for PATH can take seconds, so the first caller pays for it once.
    var environment: [String: String] { environmentCache.value }

    /// Resolves the launch environment ahead of the first run. Call it off the main thread.
    public func prepare() {
        _ = environmentCache.value
    }

    public func start(_ arguments: [String], options: SessionOptions = SessionOptions(),
                      onLine: (@Sendable (String) -> Void)? = nil) throws -> MoleSession {
        let session = MoleSession(runner: self, arguments: arguments, options: options, onLine: onLine)
        try session.launch()
        return session
    }

    /// Cancelling the stream interrupts Mole; `control` interrupts it while the stream keeps
    /// running until Mole has actually exited.
    public func run(_ arguments: [String], options: SessionOptions = SessionOptions(),
                    control: RunControl? = nil) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let launch = Task.detached { [self] in
                let session: MoleSession
                do {
                    session = try start(arguments, options: options) { continuation.yield(.line($0)) }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                control?.attach(session)
                await withTaskCancellationHandler {
                    do {
                        let code = try await session.exitCode()
                        continuation.yield(.finished(exitCode: code))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } onCancel: {
                    session.interrupt()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { launch.cancel() }
            }
        }
    }

    public func capture(_ arguments: [String]) async throws -> (output: Data, exitCode: Int32) {
        let session = try start(arguments, options: SessionOptions(separateErrors: true))
        let code = try await withTaskCancellationHandler {
            try await session.exitCode()
        } onCancel: {
            session.interrupt()
        }
        return (session.stdoutData, code)
    }
}

private final class EnvironmentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: [String: String]?

    var value: [String: String] {
        lock.withLock {
            if let resolved { return resolved }
            let environment = LaunchEnvironment.make(loginPath: LaunchEnvironment.resolveLoginPath())
            resolved = environment
            return environment
        }
    }
}

/// One Mole process, always in its own session so an interrupt reaches every worker.
public final class MoleSession: @unchecked Sendable {
    static let sudoPromptMarker = "[burrow-sudo-prompt]"
    static let adminFailedExit: Int32 = 77

    /// `sudo -v` asks once on the session terminal; the loop keeps the ticket fresh for
    /// long runs, since Mole only renews a ticket it acquired itself. The loop must not
    /// hold the output pipe, or the run would only end when its `sleep` does.
    private static let adminScript = """
        sudo -v < /dev/tty > /dev/tty 2>&1 || exit 77
        ( while sleep 45; do sudo -n -v || exit 0; done ) > /dev/null 2>&1 &
        keepalive=$!
        "$@"
        status=$?
        kill "$keepalive" 2> /dev/null
        exit "$status"
        """

    private let runner: MoleRunner
    private let arguments: [String]
    private let options: SessionOptions
    private let lineHandler: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let terminalQueue = DispatchQueue(label: "burrow.session.terminal")
    private var lineBuffer = LineBuffer()
    private var stdout = Data()
    private var screenBytes = Data()
    private var screenWaiters: [ScreenWaiter] = []
    private var terminal: (master: Int32, slave: Int32)?
    private var terminalSource: DispatchSourceRead?
    private var promptScan = ""
    private var passwordAttempts = 0
    private var declined = false
    private var exitWaiters: [CheckedContinuation<Int32, Error>] = []
    private var exitResult: Result<Int32, Error>?

    init(runner: MoleRunner, arguments: [String], options: SessionOptions,
         onLine: (@Sendable (String) -> Void)?) {
        self.runner = runner
        self.arguments = arguments
        self.options = options
        self.lineHandler = onLine
    }

    var stdoutData: Data { lock.withLock { stdout } }

    func launch() throws {
        let installation = runner.installation
        var environment = runner.environment.merging(options.environment) { _, override in override }
        let needsTerminal = options.admin != nil || options.interactive || options.outputOnTerminal
        process.executableURL = installation.sessionHelper

        var terminalPath = "-"
        if needsTerminal {
            guard let path = openTerminal() else { throw RunError.launchFailed("no pseudo-terminal available") }
            terminalPath = path
            environment["LINES"] = "\(Self.terminalRows)"
            environment["COLUMNS"] = "\(Self.terminalColumns)"
        }

        if options.interactive, let terminal {
            process.standardInput = FileHandle(fileDescriptor: terminal.slave, closeOnDealloc: false)
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        if options.outputOnTerminal, let terminal {
            let handle = FileHandle(fileDescriptor: terminal.slave, closeOnDealloc: false)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = output
            process.standardError = options.separateErrors ? errors : output
        }

        var command = [installation.executable.path] + arguments
        if options.admin != nil {
            environment["SUDO_PROMPT"] = Self.sudoPromptMarker
            if options.authenticateFirst {
                command = ["/bin/sh", "-c", Self.adminScript, "burrow"] + command
            }
        }
        process.arguments = [terminalPath] + command
        process.environment = environment

        let drained = DispatchGroup()
        if !options.outputOnTerminal {
            drain(output, into: drained) { [weak self] chunk in self?.receiveOutput(chunk) }
            if options.separateErrors {
                drain(errors, into: drained) { _ in }
            }
        }
        drained.enter()
        process.terminationHandler = { _ in drained.leave() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            closeTerminal()
            throw RunError.launchFailed(error.localizedDescription)
        }

        drained.notify(queue: .global()) { [self] in
            if options.outputOnTerminal { drainTerminal() }
            closeTerminal()
            settle(exitCode: process.terminationStatus)
        }
    }

    private func drain(_ pipe: Pipe, into group: DispatchGroup, receive: @escaping @Sendable (Data?) -> Void) {
        group.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                receive(nil)
                group.leave()
            } else {
                receive(chunk)
            }
        }
    }

    // MARK: Control

    public func exitCode() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Int32, Error>? = lock.withLock {
                if exitResult == nil { exitWaiters.append(continuation) }
                return exitResult
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// SIGINT lets Mole finish the step it is in and stop cleanly, and SIGTERM follows if it
    /// keeps going. `force` adds SIGKILL, which is only safe before anything was confirmed:
    /// a killed step can leave items in Mole's privileged staging instead of the Trash.
    public func interrupt(force: Bool = false) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        kill(-pid, SIGINT)
        let escalation = force ? [10.0, 20.0] : [10.0]
        for delay in escalation {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [process] in
                if process.isRunning { kill(-pid, SIGTERM) }
            }
        }
    }

    public enum Key: Sendable {
        case down, up, space, enter, escape
        case text(String)

        var bytes: [UInt8] {
            switch self {
            case .down: [0x1B, 0x5B, 0x42]
            case .up: [0x1B, 0x5B, 0x41]
            case .space: [0x20]
            case .enter: [0x0D]
            case .escape: [0x1B]
            case .text(let text): Array(text.utf8)
            }
        }
    }

    public func send(_ key: Key) {
        writeToTerminal(key.bytes)
    }

    /// Writes under the lock that `closeTerminal` takes, so bytes never reach a descriptor
    /// number that was closed and handed to another file after Mole exited.
    private func writeToTerminal(_ bytes: [UInt8]) {
        lock.withLock {
            guard let master = terminal?.master else { return }
            _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        }
    }

    // MARK: Screen

    public func mark() -> Int { lock.withLock { screenBytes.count } }

    public func screen(since mark: Int = 0) -> String {
        lock.withLock { Self.plainText(of: screenBytes, from: mark) }
    }

    public func waitForScreen(since mark: Int, timeout: TimeInterval, step: String,
                              until condition: @escaping @Sendable (String) -> Bool) async throws -> String {
        enum Outcome { case matched(String), exited, waiting }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let outcome: Outcome = lock.withLock {
                let text = Self.plainText(of: screenBytes, from: mark)
                if condition(text) { return .matched(text) }
                if exitResult != nil { return .exited }
                screenWaiters.append(ScreenWaiter(id: id, mark: mark, condition: condition, continuation: continuation))
                return .waiting
            }
            switch outcome {
            case .matched(let text):
                continuation.resume(returning: text)
            case .exited:
                continuation.resume(throwing: RunError.timedOut(step))
            case .waiting:
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.expireWaiter(id, step: step)
                }
            }
        }
    }

    private struct ScreenWaiter {
        let id: UUID
        let mark: Int
        let condition: @Sendable (String) -> Bool
        let continuation: CheckedContinuation<String, Error>
    }

    private func expireWaiter(_ id: UUID, step: String) {
        let expired: ScreenWaiter? = lock.withLock {
            guard let index = screenWaiters.firstIndex(where: { $0.id == id }) else { return nil }
            return screenWaiters.remove(at: index)
        }
        expired?.continuation.resume(throwing: RunError.timedOut(step))
    }

    /// Output arrives in arbitrary chunks, so a mark can fall inside a multi-byte character;
    /// decoding starts at the character it belongs to and stops before an incomplete one.
    static func plainText(of bytes: Data, from mark: Int) -> String {
        var start = bytes.startIndex + min(max(mark, 0), bytes.count)
        while start > bytes.startIndex, start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
            start -= 1
        }
        var end = bytes.endIndex
        var back = end
        while back > start, end - back < 4 {
            back -= 1
            let byte = bytes[back]
            if byte & 0xC0 == 0x80 { continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if end - back < length { end = back }
            break
        }
        return TerminalText.plain(String(decoding: bytes[start..<end], as: UTF8.self))
    }

    private func appendScreen(_ chunk: Data) {
        let ready: [(ScreenWaiter, String)] = lock.withLock {
            screenBytes.append(chunk)
            var matched: [(ScreenWaiter, String)] = []
            screenWaiters.removeAll { waiter in
                let screen = Self.plainText(of: screenBytes, from: waiter.mark)
                guard waiter.condition(screen) else { return false }
                matched.append((waiter, screen))
                return true
            }
            return matched
        }
        for (waiter, screen) in ready { waiter.continuation.resume(returning: screen) }
    }

    // MARK: Output

    private func receiveOutput(_ chunk: Data?) {
        let lines: [String] = lock.withLock {
            guard let chunk else { return lineBuffer.finish() }
            stdout.append(chunk)
            return lineBuffer.append(chunk)
        }
        if let chunk { appendScreen(chunk) }
        for line in lines { lineHandler?(TerminalText.plain(line)) }
    }

    private func settle(exitCode: Int32) {
        let (attempts, wasDeclined) = lock.withLock { (passwordAttempts, declined) }
        let result: Result<Int32, Error>
        if options.authenticateFirst, exitCode == Self.adminFailedExit {
            result = .failure(wasDeclined || attempts == 0 ? RunError.adminDeclined : RunError.adminRejected)
        } else {
            result = .success(exitCode)
        }
        let (exitWaiting, screenWaiting) = lock.withLock {
            exitResult = result
            defer { exitWaiters.removeAll(); screenWaiters.removeAll() }
            return (exitWaiters, screenWaiters)
        }
        for waiter in exitWaiting { waiter.resume(with: result) }
        for waiter in screenWaiting { waiter.continuation.resume(throwing: RunError.timedOut("waiting for Mole")) }
    }

    // MARK: Terminal

    static let terminalRows: UInt16 = 56
    static let terminalColumns: UInt16 = 160

    private func openTerminal() -> String? {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: Self.terminalRows, ws_col: Self.terminalColumns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        guard let name = ttyname(slave) else {
            close(master)
            close(slave)
            return nil
        }
        // macOS drops the session's controlling terminal once the last slave
        // descriptor closes, so the slave stays open here until Mole exits.
        terminal = (master, slave)
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: terminalQueue)
        source.setEventHandler { [weak self] in self?.readTerminal(master) }
        source.setCancelHandler {
            close(master)
            close(slave)
        }
        source.resume()
        terminalSource = source
        return String(cString: name)
    }

    private func readTerminal(_ master: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = read(master, &buffer, buffer.count)
        guard count > 0 else { return }
        let chunk = Data(buffer[0..<count])
        let promptSeen: Bool = lock.withLock {
            promptScan += String(decoding: chunk, as: UTF8.self)
            guard promptScan.contains(Self.sudoPromptMarker) else {
                if promptScan.count > 4096 { promptScan = String(promptScan.suffix(256)) }
                return false
            }
            promptScan = ""
            passwordAttempts += 1
            return true
        }
        if promptSeen {
            requestPassword()
        } else if options.outputOnTerminal {
            appendScreen(chunk)
        }
    }

    /// Runs on the terminal queue, after any read already in flight, so the tail stays in order.
    private func drainTerminal() {
        terminalQueue.sync {
            guard let master = lock.withLock({ terminal?.master }) else { return }
            let flags = fcntl(master, F_GETFL)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            while true {
                var buffer = [UInt8](repeating: 0, count: 16384)
                let count = read(master, &buffer, buffer.count)
                guard count > 0 else { break }
                appendScreen(Data(buffer[0..<count]))
            }
        }
    }

    /// Declining sends end-of-input, which fails only that sudo call: Mole then skips the
    /// privileged steps, or the run stops if it authenticated first.
    private func requestPassword() {
        guard let admin = options.admin else { return }
        let attempt = lock.withLock { passwordAttempts }
        Task {
            guard let password = await admin(attempt) else {
                lock.withLock { declined = true }
                writeToTerminal([0x04])
                return
            }
            var reply = Array((password + "\n").utf8)
            writeToTerminal(reply)
            reply.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) }
        }
    }

    /// The descriptors close in the read source's cancel handler, after its last read.
    private func closeTerminal() {
        let source: DispatchSourceRead? = lock.withLock {
            defer {
                terminal = nil
                terminalSource = nil
            }
            return terminalSource
        }
        source?.cancel()
    }
}

/// Lets a caller stop a streamed run while still waiting for Mole to exit. A stop that
/// arrives before Mole has started is applied as soon as it does.
public final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var session: MoleSession?
    private var interrupted = false

    public init() {}

    public func interrupt() {
        let running: MoleSession? = lock.withLock {
            interrupted = true
            return session
        }
        running?.interrupt()
    }

    func attach(_ session: MoleSession) {
        let stopNow: Bool = lock.withLock {
            self.session = session
            return interrupted
        }
        if stopNow { session.interrupt() }
    }
}
