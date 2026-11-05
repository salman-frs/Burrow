import BurrowCore
import Foundation
import Observation

@MainActor
@Observable
final class MoleJob {
    private(set) var lines: [String] = []
    private(set) var isRunning = false
    private(set) var exitCode: Int32?
    private(set) var failure: Error?
    private(set) var stopping = false
    private var control = RunControl()

    var text: String { lines.joined(separator: "\n") }

    var lastMeaningfulLine: String? {
        lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("=") }
    }

    func run(_ arguments: [String], with runner: MoleRunner, options: SessionOptions = SessionOptions(),
             onLine: ((String) -> Void)? = nil) async {
        lines = []
        exitCode = nil
        failure = nil
        stopping = false
        isRunning = true
        let control = RunControl()
        self.control = control
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
        isRunning = false
    }

    /// Asks Mole to stop; `run` keeps waiting until Mole has really exited, so the
    /// one-change-at-a-time rule holds while it winds down.
    func stop() {
        guard isRunning else { return }
        stopping = true
        control.interrupt()
    }
}

extension Error {
    var isAdminDeclined: Bool { (self as? RunError) == .adminDeclined }
}
