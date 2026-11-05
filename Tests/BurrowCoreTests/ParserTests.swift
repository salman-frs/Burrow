import Foundation
import Testing
@testable import BurrowCore

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

private func fixtureData(_ name: String) throws -> Data {
    Data(try fixture(name).utf8)
}

@Suite struct JSONModels {
    @Test func statusSnapshotDecodes() throws {
        let status = try MoleJSON.decode(StatusSnapshot.self, from: fixtureData("status.json"))
        #expect(status.healthScore == 67)
        #expect(status.hardware.model == "MacBook Air")
        #expect(status.cpu.coreCount > 0)
        #expect(status.batteries?.first?.cycleCount == 497)
        #expect(status.topProcesses?.isEmpty == false)
    }

    @Test func diskOverviewDecodesInsights() throws {
        let report = try MoleJSON.decode(DiskReport.self, from: fixtureData("analyze-overview.json"))
        #expect(report.overview)
        #expect(report.scanStatus == .partial)
        #expect(report.entries.contains { $0.insight == true && $0.cleanable == true })
    }

    @Test func historyAndAppListDecode() throws {
        let history = try MoleJSON.decode(HistoryReport.self, from: fixtureData("history.json"))
        #expect(history.sessions.map(\.isPreview) == [false, true])
        #expect(history.deletions.map(\.sizeKb) == [84321, nil])
        let apps = try MoleJSON.decode([InstalledApp].self, from: fixtureData("uninstall-list.json"))
        #expect(apps.contains { $0.bundleId == "net.imput.helium" && $0.uninstallName == "Helium" })
    }
}

@Suite struct CleanReport {
    @Test func sectionsRowsAndSummary() throws {
        let report = MoleReportParser.parse(try fixture("clean-dry-run.txt"))
        #expect(report.sections.map(\.title).prefix(3) == ["User essentials", "App caches", "Browsers"])

        let userCache = try #require(report.rows.first { $0.title == "User app cache" })
        #expect(userCache.status == .pending)
        #expect(userCache.bytes == 2_190_000_000)

        let docker = try #require(report.rows.first { $0.title == "Docker Desktop data" })
        #expect(docker.status == .review)

        let homebrew = try #require(report.rows.first { $0.title == "Homebrew cleanup" })
        #expect(homebrew.children.contains("cairo 1.18.4 · 4.7MB"))

        #expect(report.summary.contains { $0.hasPrefix("Potential space: 9.47GB+") })
        #expect(report.notices.contains { $0.status == .attention && $0.title.contains("System caches need sudo") })
    }

    @Test func emptySectionsKeepTheirDoneRow() throws {
        let report = MoleReportParser.parse(try fixture("clean-dry-run.txt"))
        let cloud = try #require(report.sections.first { $0.title == "Cloud & Office" })
        #expect(cloud.rows.map(\.status) == [.done])
        #expect(cloud.measuredBytes == 0)
    }

    @Test func reviewRowsNeverCountAsReclaimable() throws {
        let report = MoleReportParser.parse(try fixture("clean-dry-run.txt"))
        let largeFiles = try #require(report.sections.first { $0.title == "Large files" })
        #expect(largeFiles.rows.allSatisfy { $0.status == .review })
        #expect(largeFiles.measuredBytes == 0)
        #expect(report.summaryBytes(labeled: "Potential space:") == 9_470_000_000)
    }

    @Test func previewListGroupsPathsBySection() throws {
        let groups = CleanListParser.parse(try fixture("clean-list.txt"))
        let essentials = try #require(groups.first { $0.title == "User essentials" })
        let homebrew = try #require(essentials.entries.first { $0.path.hasSuffix("/Library/Caches/Homebrew") })
        #expect(homebrew.bytes == 83_300_000)
        #expect(groups.allSatisfy { group in group.entries.allSatisfy { $0.path.hasPrefix("/") } })
    }

    @Test func optimizeTasksParse() throws {
        let report = MoleReportParser.parse(try fixture("optimize-dry-run.txt"))
        #expect(report.sections.contains { $0.title == "Network Cache Refresh" })
        #expect(report.summary.contains("Would apply 4 optimizations"))
        #expect(report.rows.contains { $0.title == "Optimized 1 databases for Mail, Safari, Messages" && $0.detail.isEmpty })
        let clean = MoleReportParser.parse(try fixture("clean-dry-run.txt"))
        let worker = try #require(clean.rows.first { $0.title == "Chrome Service Worker" })
        #expect(worker.detail == "would clean 115.1MB, 0 protected")
    }
}

@Suite struct SelectionLists {
    @Test func purgePreviewExpandsHome() throws {
        let artifacts = PurgePreviewParser.parse(try fixture("purge-dry-run.txt"))
        #expect(artifacts.count == 12)
        let venv = try #require(artifacts.first { $0.path.hasSuffix("telegram-bot/.venv") })
        #expect(venv.path.hasPrefix(NSHomeDirectory()))
        #expect(venv.bytes == 193_300_000)
    }

    @Test func slimPreviewListsApps() throws {
        let apps = SlimPreviewParser.parse(try fixture("slim-dry-run.txt"))
        #expect(apps.count == 16)
        #expect(apps.first == SlimCandidate(name: "Google Chrome", sizeLabel: "405.7MB", bytes: 405_700_000))
        #expect(apps.contains { $0.name == "Microsoft Remote Desktop" && $0.bytes == 552_000 })
    }

    @Test func installerMenuRowsParse() throws {
        let files = InstallerWorkflow.parseMenu(try fixture("installer-dry-run.txt"))
        #expect(files.count == 7)
        let xcode = try #require(files.first { $0.name == "Xcode_27.2_Release_Candidate.xip" })
        #expect(xcode.sizeLabel == "2.05GB")
        #expect(xcode.source == "Downloads")
    }

    @Test func installerConfirmationMustMatchSelectionExactly() throws {
        let files = InstallerWorkflow.parseMenu(try fixture("installer-dry-run.txt"))
        let picked = Array(files.prefix(2))
        let screen = """
            Files to be removed:
              ✓ \(picked[0].name) , \(picked[0].sizeLabel)
              ✓ \(picked[1].name) , \(picked[1].sizeLabel)

            ➤ Delete 2 installers, 9.5MB  Enter confirm, ESC cancel:
            """
        #expect(InstallerWorkflow.confirmationMatches(screen, selection: picked))
        #expect(!InstallerWorkflow.confirmationMatches(screen, selection: Array(files.prefix(1))))
        #expect(!InstallerWorkflow.confirmationMatches(screen, selection: Array(files.prefix(3))))
    }

    @Test func purgeConfirmationComparesFullPaths() {
        let home = NSHomeDirectory()
        let selection = [PathEntry(path: "\(home)/code/a/node_modules", sizeLabel: "1MB", bytes: 1_000_000)]
        let screen = """
            Selected paths:
              ~/code/a/node_modules
            ➤ Remove 1 artifact, 1.00MB  Enter confirm, ESC cancel:
            """
        #expect(PurgeWorkflow.confirmationMatches(screen, selection: selection))
        let extra = screen.replacingOccurrences(of: "  ~/code/a/node_modules", with: "  ~/code/a/node_modules\n  ~/code/b/dist")
        #expect(!PurgeWorkflow.confirmationMatches(extra, selection: selection))
    }

    @Test func installerConfirmationAcceptsShortenedAndHomebrewNames() {
        let long = InstallerFile(row: "a", name: "Microsoft_Office_16.95_Installer_Univ...", sizeLabel: "2.10GB", source: "Downloads")
        let brew = InstallerFile(row: "b", name: "wireshark-4.4.2.dmg", sizeLabel: "70.1MB", source: "Homebrew")
        let hash = String(repeating: "ab", count: 32)
        let screen = """
            Files to be removed:
              ✓ Microsoft_Office_16.95_Installer_Universal.pkg , 2.10GB
              ✓ \(hash)--wireshark-4.4.2.dmg , 70.1MB
            ➤ Delete 2 installers, 2.17GB  Enter confirm, ESC cancel:
            """
        #expect(InstallerWorkflow.confirmationMatches(screen, selection: [long, brew]))
        let otherSize = InstallerFile(row: "c", name: brew.name, sizeLabel: "70.0MB", source: "Homebrew")
        #expect(!InstallerWorkflow.confirmationMatches(screen, selection: [long, otherSize]))
    }

    @Test func purgeConfirmationReadsCloudTaggedPaths() {
        let home = NSHomeDirectory()
        let selection = [PathEntry(path: "\(home)/Library/CloudStorage/Drive/app/node_modules", sizeLabel: "9MB", bytes: nil)]
        let screen = """
            Selected paths:
              [cloud] ~/Library/CloudStorage/Drive/app/node_modules
            ➤ Remove 1 artifact, 9.00MB  Enter confirm, ESC cancel:
            """
        #expect(PurgeWorkflow.confirmationMatches(screen, selection: selection))
    }

    @Test func incompletePurgeNamesWhatMoleKept() {
        let screen = """
            ◎ Could not inspect ~/Library/CloudStorage/Drive/app/.venv; kept\r
            ◎ Skipped 2 project scan roots because scanning did not complete:
              ~/code/big (status 124)
              ~/work/huge (status 124)
            Re-run with 'mo purge --debug' to inspect the scan failure.
            Selected paths:
              ~/code/a/node_modules
            ◎ Could not inspect ~/Library/CloudStorage/Drive/app/.venv; kept
            ======================================================================
            Purge incomplete
            ◎ 1 more failed
            ======================================================================
            """
        #expect(Rows.notices(in: screen) == [
            "Could not inspect ~/Library/CloudStorage/Drive/app/.venv; kept",
            "Skipped 2 project scan roots because scanning did not complete:",
            "~/code/big (status 124)",
            "~/work/huge (status 124)",
        ])
        #expect(Rows.summary(in: screen) == ["Purge incomplete", "◎ 1 more failed"])
    }

    @Test func purgePreviewKeepsMolesUninspectedNote() {
        let report = MoleReportParser.parse("◎ Could not inspect ~/code/app/.venv; kept\n✓ [DRY RUN] ~/code/a/node_modules, 1.0MB\n")
        let attention = report.notices.filter { $0.status == .attention }.map(\.title)
        #expect(attention == ["Could not inspect ~/code/app/.venv; kept"])
    }

    @Test func slimTerminalScriptQuotesTheEnginePath() {
        let script = SlimWorkflow.terminalScript(moleExecutable: URL(fileURLWithPath: "/Applications/Bur'row.app/mole"))
        #expect(script.contains("exec '/Applications/Bur'\\''row.app/mole' slim"))
    }
}

@Suite struct Uninstall {
    static let review = """
        ◎ Matched 2 app(s):
        Files to be removed:
        ◎ Keka [Brew] , 37.9MB
          ✓ /Applications/Keka.app , 37.9MB
          ◎ System: /Library/LaunchDaemons/com.aone.keka.helper.plist
        ◎ Arc , 400MB [Running]
          ✓ /Applications/Arc.app , 400MB
          ✓ ~/Library/Caches/company.thebrowser.Browser , 2MB

        Personal data kept:
          ⊙ ~/Library/Containers/com.aone.keka

        D choose personal data
        ➤ Remove 2 app(s), 437.9MB [Running]  Enter confirm, ESC cancel:
        """

    static func app(_ name: String) -> InstalledApp {
        InstalledApp(name: name, bundleId: "x.\(name)", source: "App", uninstallName: name,
                     path: "/Applications/\(name).app", size: "--")
    }

    @Test func planGroupsFilesUnderEachApp() {
        let plan = UninstallPlanParser.parse(Self.review)
        #expect(plan.apps.map(\.name) == ["Keka", "Arc"])
        #expect(plan.apps[0].viaHomebrew)
        #expect(plan.apps[0].systemPaths == ["/Library/LaunchDaemons/com.aone.keka.helper.plist"])
        #expect(plan.apps[1].isRunning)
        #expect(plan.apps[1].files.last == NSHomeDirectory() + "/Library/Caches/company.thebrowser.Browser")
        #expect(plan.personalDataKept.count == 1)
        #expect(plan.notes.isEmpty)
    }

    @Test func confirmationTiesEachAppToItsBundlePath() {
        let both = [Self.app("Keka"), Self.app("Arc")]
        #expect(UninstallWorkflow.confirmationMatches(Self.review, apps: both, withData: false))
        #expect(!UninstallWorkflow.confirmationMatches(Self.review, apps: [Self.app("Keka")], withData: false))

        let otherCopy = InstalledApp(name: "Arc", bundleId: "x.Arc", source: "App", uninstallName: "Arc",
                                     path: NSHomeDirectory() + "/Applications/Arc.app", size: "--")
        #expect(!UninstallWorkflow.confirmationMatches(Self.review, apps: [Self.app("Keka"), otherCopy], withData: false))

        let withData = Self.review.replacingOccurrences(of: "437.9MB [Running]", with: "437.9MB, including personal data")
        #expect(!UninstallWorkflow.confirmationMatches(withData, apps: both, withData: false))
        #expect(UninstallWorkflow.confirmationMatches(withData, apps: both, withData: true))
    }

    @Test func appsMoleCannotTellApartAreRefused() {
        let store = InstalledApp(name: "Telegram", bundleId: "ru.keepcoder.Telegram", source: "App",
                                 uninstallName: "Telegram", path: "/Applications/Telegram.app", size: "--")
        let desktop = InstalledApp(name: "Telegram Desktop", bundleId: "com.tdesktop.Telegram", source: "App",
                                   uninstallName: "Telegram", path: NSHomeDirectory() + "/Applications/Telegram.app", size: "--")
        let keka = Self.app("Keka")
        #expect(UninstallWorkflow.ambiguous([desktop], among: [store, desktop, keka]) == [desktop])
        #expect(UninstallWorkflow.ambiguous([keka], among: [store, desktop, keka]).isEmpty)
    }

    @Test func homebrewCasksAreNamedByTheirAppFolder() throws {
        let apps = try MoleJSON.decode([InstalledApp].self, from: fixtureData("uninstall-list.json"))
        let code = try #require(apps.first { $0.bundleId == "com.microsoft.VSCode" })
        #expect(code.uninstallName == "visual-studio-code")
        #expect(UninstallWorkflow.arguments(for: [code], withData: false, dryRun: true)
            == ["uninstall", "--dry-run", "Visual Studio Code"])
    }

    @Test func dryRunPlanFixture() {
        let text = """
            Files to be removed:
            ◎ Keka [Brew] , 37.9MB
              ✓ /Applications/Keka.app , 37.9MB

            Personal data kept:
              ⊙ ~/Library/Containers/com.aone.keka

            D choose personal data

            Dry run complete; the list above is the plan and no apps were removed.
            """
        let plan = UninstallPlanParser.parse(text)
        #expect(plan.apps.first?.files == ["/Applications/Keka.app"])
        #expect(plan.personalDataKept == [NSHomeDirectory() + "/Library/Containers/com.aone.keka"])
    }
}

@Suite struct MenuFrames {
    @Test func lastFrameFindsCursorAndSelection() {
        let screen = """
            Select Installers to Remove , 0B, 0 selected
              ○ a.dmg   1MB | Downloads
            Q Quit
            Select Installers to Remove , 1MB, 1 selected
              ● a.dmg   1MB | Downloads
            ➤ ○ b.pkg   2MB | Desktop
            ↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
            """
        let frame = MenuFrameParser.lastFrame(in: screen, title: "Select Installers to Remove")
        #expect(frame?.rows.count == 2)
        #expect(frame?.rows.first?.selected == true)
        #expect(frame?.cursor?.text == "b.pkg   2MB | Desktop")
        #expect(MenuFrameParser.isComplete(screen, title: "Select Installers to Remove"))
        #expect(!MenuFrameParser.isComplete("Select Installers to Remove\n  ○ a", title: "Select Installers to Remove"))
    }

    @Test func purgeFrameReadsCursorPath() {
        let screen = """
            Select Artifacts to Purge
            ➤ ● ┌ ~/code/a   10MB | node_modules | 2mo
              ○ └ ~/code/a    1MB | dist | <7d
            Path: ~/code/a/node_modules
            ↑↓ | Space Select | Enter Confirm | Q Quit
            """
        let frame = MenuFrameParser.lastFrame(in: screen, title: "Select Artifacts to Purge")
        #expect(frame?.cursorPath == "~/code/a/node_modules")
        #expect(frame?.cursor?.selected == true)
    }
}

@Suite struct Settings {
    @Test func defaultWhitelistComesFromMoleSource() {
        let source = """
            declare -a DEFAULT_WHITELIST_PATTERNS=(
                "$HOME/Library/Caches/ms-playwright*"
                "$FINDER_METADATA_SENTINEL"
            )
            """
        let raw = MoleDefaults.arrayLiteral(named: "DEFAULT_WHITELIST_PATTERNS", in: source)
        #expect(raw == ["$HOME/Library/Caches/ms-playwright*", "$FINDER_METADATA_SENTINEL"])
    }

    @Test func patternRulesRejectWhatMoleWouldDrop() {
        #expect(PatternRules.problem(with: "~/Library/Caches/foo") == nil)
        #expect(PatternRules.problem(with: "FINDER_METADATA") == nil)
        #expect(PatternRules.problem(with: "/Library/Caches/com.example") == nil)
        #expect(PatternRules.problem(with: "Library/Caches") != nil)
        #expect(PatternRules.problem(with: "~/a..b") != nil)
        #expect(PatternRules.problem(with: "/System/Library") != nil)
        #expect(PatternRules.problem(with: "/var/db/x") != nil)
    }

    @Test func patternFileIgnoresComments() {
        #expect(PatternFile.patterns(in: "# header\n\n~/a\n  /b  \n#c") == ["~/a", "/b"])
    }
}

@Suite struct Text {
    @Test func linesSplitOnCarriageReturnsAndStripEscapes() {
        var buffer = LineBuffer()
        let lines = buffer.append(Data("one\rtwo\nthr".utf8))
        #expect(lines == ["one", "two"])
        #expect(buffer.finish() == ["thr"])
        #expect(TerminalText.plain("\u{1B}[0;32m✓\u{1B}[0m done\u{1B}[2K") == "✓ done")
    }

    @Test func screenTextNeverSplitsACharacter() {
        let bytes = Data("a ➤ ●".utf8)
        let insideArrow = 3
        #expect(MoleSession.plainText(of: bytes, from: insideArrow) == "➤ ●")
        #expect(MoleSession.plainText(of: bytes.dropLast(1), from: 0) == "a ➤ ")
    }

    @Test func byteSizesUseMolesDecimalUnits() {
        #expect(ByteSize.firstSize(in: "26 items, 2.19GB dry") == 2_190_000_000)
        #expect(ByteSize.firstSize(in: "would clean") == nil)
        #expect(ByteSize.firstSize(in: "0B dry") == 0)
    }
}
