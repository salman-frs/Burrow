import Foundation
import Testing
@testable import BurrowCore

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct DiskLayering {
    @Test func layersSkipOverlappingFoldersAndGiveTheRestToMacOS() throws {
        let overview = try MoleJSON.decode(DiskReport.self, from: Data(try fixture("analyze-overview.json").utf8))
        let layers = DiskLayers.make(overview: overview, used: 200_000_000_000, home: "/Users/alex")
        #expect(layers.map(\.name) == ["System", "Library", "Applications", "Home"])
        #expect(layers.map(\.bytes).reduce(0, +) == 200_000_000_000)
        #expect(layers.first?.path == nil)
    }

    @Test func homeLayerCountsTheUserLibraryMoleMeasuresSeparately() throws {
        let overview = try MoleJSON.decode(DiskReport.self, from: Data(try fixture("analyze-overview.json").utf8))
        let home = try #require(DiskLayers.make(overview: overview, used: 200_000_000_000, home: "/Users/alex").last)
        #expect(home.bytes == 75_222_768_874 + 43_610_128_384)
    }

    @Test func systemLayerNeverGoesNegative() throws {
        let overview = try MoleJSON.decode(DiskReport.self, from: Data(try fixture("analyze-overview.json").utf8))
        #expect(DiskLayers.make(overview: overview, used: 1_000, home: "/Users/alex").first?.bytes == 0)
    }

    @Test func withoutAnOverviewTheDiskIsOneUsedLayer() {
        #expect(DiskLayers.make(overview: nil, used: 42) == [DiskLayer(name: "Used", path: nil, bytes: 42)])
    }
}

@Suite struct CleanFindings {
    @Test func reviewItemsNeedAPathAndAppearOnce() throws {
        let report = MoleReportParser.parse(try fixture("clean-dry-run.txt"))
        let items = report.reviewItems
        #expect(items.first?.title == "Docker data")
        #expect(items.first?.path == NSHomeDirectory() + "/Library/Containers/com.docker.docker/Data")
        #expect(!items.contains { $0.title == "Docker Desktop data" || $0.title == "Build artifacts" })
        #expect(items.contains { $0.title == "pnpm store" && $0.path.hasSuffix("/Library/pnpm/store") })
        #expect(items.map(\.bytes) == items.map(\.bytes).sorted(by: >))
    }

    @Test func cleanableSectionsLeaveOutReviewOnlySections() throws {
        let report = MoleReportParser.parse(try fixture("clean-dry-run.txt"))
        let titles = report.cleanableSections.map(\.title)
        #expect(titles.contains("Developer tools"))
        #expect(!titles.contains("Large files"))
        #expect(!titles.contains("Cloud & Office"))
    }

    @Test func optimizeTasksMoveFromRunningToTheirOutcome() {
        let streamed = MoleReportParser.parse("""
            ➤ Network Cache Refresh
              ✓ DNS cache refreshed
            ➤ Spotlight Optimization
              ◎ Spotlight indexing is disabled
            ➤ Permission Repair
            """)
        #expect(streamed.progress(of: "Network Cache Refresh", finished: false) == .done)
        #expect(streamed.progress(of: "Spotlight Optimization", finished: false) == .skipped)
        #expect(streamed.progress(of: "Permission Repair", finished: false) == .running)
        #expect(streamed.progress(of: "Permission Repair", finished: true) == .done)
        #expect(streamed.progress(of: "Disk Health", finished: false) == .pending)
    }
}

@Suite struct AppFootprint {
    @Test func leftoversSortIntoParts() {
        #expect(FootprintPart.of("/Applications/Arc.app") == .app)
        #expect(FootprintPart.of("~/Library/Caches/company.thebrowser.Browser") == .caches)
        #expect(FootprintPart.of("~/Library/WebKit/company.thebrowser.Browser") == .caches)
        #expect(FootprintPart.of("~/Library/Preferences/company.thebrowser.Browser.plist") == .settings)
        #expect(FootprintPart.of("/Library/LaunchDaemons/com.aone.keka.helper.plist") == .settings)
        #expect(FootprintPart.of("~/Library/Application Support/Arc") == .data)
    }

    @Test func sizesCountFilesAndFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("blob")
        try Data(count: 100_000).write(to: file)
        #expect(DirectorySize.allocated(at: file) >= 100_000)
        #expect(DirectorySize.allocated(at: folder) == DirectorySize.allocated(at: file))
    }
}
