import BurrowCore
import Foundation
import Testing
@testable import Burrow

/// The session helper is built by scripts/test.sh; a shell script stands in for Mole.
private let helper = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/debug/burrow-session")

private let fakeMole = """
    #!/bin/sh
    case "$1" in
        succeed) echo first; echo second; exit 0 ;;
        fail) echo "Mole gave up"; exit 3 ;;
        linger) trap 'echo winding down; exit 0' INT; echo started; while :; do sleep 0.1; done ;;
    esac
    """

private func fakeRunner() throws -> MoleRunner {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let executable = folder.appendingPathComponent("mole")
    try fakeMole.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return MoleRunner(installation: MoleInstallation(executable: executable, sessionHelper: helper))
}

@MainActor
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: helper.path)))
struct MoleJobOutcome {
    @Test func aCleanExitCompletesWithEveryLine() async throws {
        let job = MoleJob()
        let outcome = await job.run(["succeed"], with: try fakeRunner())
        guard case .completed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(job.lines == ["first", "second"])
        #expect(job.state == .idle)
    }

    @Test func aFailingExitKeepsItsCode() async throws {
        let job = MoleJob()
        let outcome = await job.run(["fail"], with: try fakeRunner())
        guard case .exited(let code) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(code == 3)
        #expect(job.lastMeaningfulLine == "Mole gave up")
    }

    @Test func aStopWinsOverACleanExit() async throws {
        let job = MoleJob()
        let outcome = await job.run(["linger"], with: try fakeRunner()) { line in
            if line == "started" { job.stop() }
        }
        guard case .stopped = outcome else { Issue.record("got \(outcome)"); return }
        #expect(job.lines.last == "winding down")
        #expect(job.state == .idle)
    }
}

@MainActor
@Suite struct AdminPrompt {
    private func pendingRequest(_ broker: AdminBroker) async -> AdminBroker.Request {
        while broker.request == nil { await Task.yield() }
        return broker.request!
    }

    @Test func theAnswerReachesTheWaitingRun() async {
        let broker = AdminBroker()
        let ask = broker.provider(reason: "Testing")
        let reply = Task { await ask(1) }
        broker.answer("secret", to: await pendingRequest(broker))
        #expect(await reply.value == "secret")
        #expect(broker.request == nil)
    }

    @Test func aNewerPromptDeclinesTheOneLeftOpen() async {
        let broker = AdminBroker()
        let ask = broker.provider(reason: "Testing")
        let first = Task { await ask(1) }
        let replaced = await pendingRequest(broker)
        let second = Task { await ask(2) }
        #expect(await first.value == nil)
        let current = await pendingRequest(broker)
        #expect(current.attempt == 2)

        broker.answer("stale", to: replaced)
        #expect(broker.request?.id == current.id)
        broker.answer("fresh", to: current)
        #expect(await second.value == "fresh")
    }
}
