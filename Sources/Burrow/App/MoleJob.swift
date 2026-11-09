import BurrowCore
import Foundation
import Observation

@MainActor
@Observable
final class MoleJob {
    enum State { case idle, running, stopping }

    /// A stop wins over the exit code: Mole may still exit cleanly after skipping the rest of its steps.
    enum Outcome {
        case completed
        case exited(Int32)
        case stopped
        case failed(Error)
    }

    private(set) var state = State.idle
    private(set) var lines: [String] = []
    private var control = RunControl()

    var text: String { lines.joined(separator: "\n") }

    var lastMeaningfulLine: String? {
        lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("=") }
    }

    @discardableResult
    func run(_ arguments: [String], with runner: MoleRunner, options: SessionOptions = SessionOptions(),
             onLine: ((String) -> Void)? = nil) async -> Outcome {
        lines = []
        state = .running
        let control = RunControl()
        self.control = control
        var exitCode: Int32 = 0
        var failure: Error?
        do {
            for try await event in runner.run(arguments, options: options, control: control) {
                switch event {
                case .line(let line):
                    lines.append(line)
                    onLine?(line)
                case .finished(let code):
                    exitCode = code
                }
            }
        } catch {
            failure = error
        }
        let stopped = state == .stopping
        state = .idle
        if let failure { return .failed(failure) }
        if stopped { return .stopped }
        return exitCode == 0 ? .completed : .exited(exitCode)
    }

    /// Asks Mole to stop; `run` keeps waiting until Mole has really exited, so the
    /// one-change-at-a-time rule holds while it winds down.
    func stop() {
        guard state == .running else { return }
        state = .stopping
        control.interrupt()
    }
}

extension Error {
    var isAdminDeclined: Bool { (self as? RunError) == .adminDeclined }
}
