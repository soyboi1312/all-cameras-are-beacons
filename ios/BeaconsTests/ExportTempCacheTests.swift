import XCTest
@testable import Beacons

/// "Clear log" must not leave copies of the history behind. These pin the three pieces that make
/// that true without touching real user state:
///  - ExportTempCache.sweep, run over a temp root THIS TEST creates (its name is not a UUID, so the
///    app's own launch sweep of the host's tmp can never match it, and it is removed in tearDown);
///  - the notification-identifier scope used to remove delivered/pending detection notifications;
///  - the banner-text sanitizer for radio-controlled device names.
final class ExportTempCacheTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("ExportTempCacheTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - fixtures

    @discardableResult
    private func makeDir(_ name: String = UUID().uuidString, files: [String],
                         modified: Date? = nil) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let url = dir.appendingPathComponent(f)
            try Data("mac,lat,lon\n".utf8).write(to: url)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        // The directory last: adding children bumps its own mtime.
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: dir.path) }
        return dir
    }

    @discardableResult
    private func makeFile(_ name: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    // MARK: - Clear log form (no age bound)

    func testClearRemovesEveryOwnedExportDirAndNothingElse() throws {
        let logCSV = try makeDir(files: ["acab-detections.csv"])
        let logGPX = try makeDir(files: ["acab-detections-body-cam.gpx"])
        let share = try makeDir(files: ["beacons-observation.csv", "beacons-observation.jpg"])

        // Foreign or ambiguous: every one of these must survive.
        let foreign = try makeDir(files: ["firmware.zip"])                      // e.g. a DFU stage
        let mixed = try makeDir(files: ["acab-detections.csv", "other.bin"])    // not provably ours
        let empty = try makeDir(files: [])
        let notUUID = try makeDir("exports", files: ["acab-detections.csv"])
        let dfuZip = try makeFile("beacon-nrf-dfu-1.2.3-\(UUID().uuidString).zip")
        // Loose contribution photo: a live contribution flow may still hold it, so Clear keeps it.
        let photo = try makeFile("beacons-observation-\(UUID().uuidString).jpg")

        let removed = ExportTempCache.sweep(root: root, olderThan: nil)

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)),
                       Set([logCSV, logGPX, share].map(\.lastPathComponent)))
        for gone in [logCSV, logGPX, share] { XCTAssertFalse(exists(gone), gone.lastPathComponent) }
        for kept in [foreign, mixed, empty, notUUID, dfuZip, photo] {
            XCTAssertTrue(exists(kept), kept.lastPathComponent)
        }
    }

    // MARK: - launch form (1-hour bound)

    func testLaunchSweepHonoursAgeAndNewestEntry() throws {
        let now = Date()
        let old = now.addingTimeInterval(-(ExportTempCache.maxAge + 60))
        let fresh = now.addingTimeInterval(-(ExportTempCache.maxAge - 60))

        let oldExport = try makeDir(files: ["acab-detections.csv"], modified: old)
        let freshExport = try makeDir(files: ["acab-detections.csv"], modified: fresh)
        // Old directory, but one child written recently: the NEWEST date decides, so it stays.
        let freshChild = try makeDir(files: ["beacons-observation.csv"], modified: old)
        try fm.setAttributes([.modificationDate: fresh],
                             ofItemAtPath: freshChild.appendingPathComponent("beacons-observation.csv").path)
        let oldPhoto = try makeFile("beacons-observation-\(UUID().uuidString).jpg", modified: old)
        let oldSource = try makeFile("beacons-photo-source-\(UUID().uuidString)", modified: old)
        let freshPhoto = try makeFile("beacons-observation-\(UUID().uuidString).jpg", modified: fresh)
        let oldDfu = try makeFile("beacon-nrf-dfu-1.2.3-\(UUID().uuidString).zip", modified: old)
        let oldForeign = try makeDir(files: ["firmware.zip"], modified: old)

        ExportTempCache.sweep(root: root, olderThan: ExportTempCache.maxAge, now: now)

        for gone in [oldExport, oldPhoto, oldSource] { XCTAssertFalse(exists(gone), gone.lastPathComponent) }
        for kept in [freshExport, freshChild, freshPhoto, oldDfu, oldForeign] {
            XCTAssertTrue(exists(kept), kept.lastPathComponent)
        }
    }

    func testMaxAgeIsOneHourLikeAndroid() {
        // Android twin: ExportCache.kt uses the same 1-hour startup sweep.
        XCTAssertEqual(ExportTempCache.maxAge, 3600)
    }

    // MARK: - name filter

    func testExportLeafNames() {
        for ok in ["acab-detections.csv", "acab-detections.gpx", "acab-detections-alpr.csv",
                   "acab-detections-body-cam.gpx", "beacons-observation.csv", "beacons-observation.jpg"] {
            XCTAssertTrue(ExportTempCache.isExportLeaf(ok), ok)
        }
        for bad in ["acab-detectionsx.csv", "acab-detections.txt", "acab-detections.csv.tmp",
                    "beacons-observation.png", "beacons-observation-1.csv", "firmware.zip", ""] {
            XCTAssertFalse(ExportTempCache.isExportLeaf(bad), bad)
        }
    }

    func testLooseContributionFileNames() {
        let id = UUID().uuidString
        XCTAssertTrue(ExportTempCache.isLooseContributionFile("beacons-observation-\(id).jpg"))
        XCTAssertTrue(ExportTempCache.isLooseContributionFile("beacons-photo-source-\(id)"))
        XCTAssertFalse(ExportTempCache.isLooseContributionFile("beacons-observation-notauuid.jpg"))
        XCTAssertFalse(ExportTempCache.isLooseContributionFile("beacons-photo-source-\(id).zip"))
        XCTAssertFalse(ExportTempCache.isLooseContributionFile("beacon-nrf-dfu-1.0-\(id).zip"))
    }

    // MARK: - notifications

    func testDetectionNotificationScope() {
        let ids = ["acab.det.AA:BB:CC:DD:EE:FF", "acab.det.11:22:33:44:55:66", "acab.other.1", "x"]
        XCTAssertEqual(DetectionNotifier.detectionNotificationIDs(ids),
                       ["acab.det.AA:BB:CC:DD:EE:FF", "acab.det.11:22:33:44:55:66"])
    }

    func testNotificationSafeNameStripsSpoofingCharacters() {
        XCTAssertEqual(DetectionNotifier.notificationSafeName("Axon\nConfirmed safe"), "AxonConfirmed safe")
        XCTAssertEqual(DetectionNotifier.notificationSafeName("a\r\tb\u{0}c\u{7F}d\u{85}e\u{9F}f"), "abcdef")
        XCTAssertEqual(DetectionNotifier.notificationSafeName("x\u{2028}y\u{2029}z"), "xyz")
        XCTAssertEqual(DetectionNotifier.notificationSafeName(
            "\u{202A}a\u{202B}b\u{202C}c\u{202D}d\u{202E}e\u{2066}f\u{2067}g\u{2068}h\u{2069}i"),
                       "abcdefghi")
        XCTAssertEqual(DetectionNotifier.notificationSafeName("\u{200E}l\u{200F}r\u{061C}"), "lr")
        XCTAssertEqual(DetectionNotifier.notificationSafeName("  \n\u{202E}  "), "")
    }

    func testNotificationSafeNameKeepsOrdinaryNames() {
        for name in ["Flock-Falcon", "Café 東京 📷", "Ray-Ban | Meta", "مرحبا", "My Tag (2)"] {
            XCTAssertEqual(DetectionNotifier.notificationSafeName(name), name)
        }
    }
}
