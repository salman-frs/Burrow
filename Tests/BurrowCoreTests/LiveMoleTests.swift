import Foundation
import Testing
@testable import BurrowCore

/// Runs against a real Mole checkout, previews only: set BURROW_MOLE and BURROW_SESSION_HELPER.
private let installation = MoleInstallation.locate()

@Suite(.enabled(if: installation != nil), .serialized)
struct LiveMole {
    let runner = MoleRunner(installation: installation!)

    @Test func statusSnapshotIsReadable() async throws {
        let result = try await runner.capture(["status", "--json"])
        #expect(result.exitCode == 0)
        _ = try MoleJSON.decode(StatusSnapshot.self, from: result.output)
    }

    @Test func installerSelectionDrivesMolesOwnConfirmation() async throws {
        let files = try await InstallerWorkflow.scan(with: runner)
        try #require(files.count >= 2, "needs two installers in ~/Downloads")
        let picked = [files[files.count - 1], files[0]]
        let outcome = try await InstallerWorkflow.remove(picked, with: runner, dryRun: true)
        #expect(outcome.succeeded)
        #expect(outcome.summary.contains { $0.contains("Would remove 2 installers") })
    }

    @Test func purgeSelectionDrivesMolesOwnConfirmation() async throws {
        let (artifacts, _) = try await PurgeWorkflow.scan(with: runner)
        try #require(artifacts.count >= 3, "needs project artifacts")
        let picked = [artifacts[1], artifacts[artifacts.count - 1]]
        let outcome = try await PurgeWorkflow.remove(picked, with: runner, dryRun: true)
        #expect(outcome.transcript.contains("Remove 2 artifacts"))
        #expect(outcome.summary.contains { $0.contains("Items: 2") })
    }

    @Test func uninstallPreviewListsTheBundle() async throws {
        let apps = try await UninstallWorkflow.installedApps(with: runner)
        let app = try #require(apps.first { $0.source == "Homebrew" } ?? apps.first { $0.path.hasPrefix("/Applications/") })
        let plan = try await UninstallWorkflow.preview([app], withData: false, with: runner)
        #expect(plan.apps.count == 1)
        #expect(plan.apps.first?.files.contains(app.path) == true)
    }

    @Test func declinedAdminPromptCancelsAnAuthenticatedRun() async throws {
        let asked = Counter()
        let session = try runner.start(["--version"], options: SessionOptions(
            admin: { _ in asked.increment(); return nil }, authenticateFirst: true
        ))
        await #expect(throws: RunError.adminDeclined) { _ = try await session.exitCode() }
        #expect(asked.value == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
