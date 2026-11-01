import XCTest
@testable import OpenAlarmSchedulingCore

final class RingtoneResourceTests: XCTestCase {
    func testEveryCatalogRingtoneResourceExistsInAppBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENALARM_APP_BUNDLE_PATH"], !path.isEmpty else {
            throw XCTSkip("Supply the SDK-built app with make test-app-resources APP_BUNDLE_PATH=...")
        }
        let appURL = URL(fileURLWithPath: path).standardizedFileURL
        XCTAssertEqual(appURL.pathExtension, "app")
        let appBundle = try XCTUnwrap(Bundle(url: appURL), "No app bundle at \(path)")
        let executableURL = try XCTUnwrap(appBundle.executableURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executableURL.path), "Missing built app executable")
        for ringtone in RingtoneCatalog.all {
            XCTAssertNotNil(resourceURL(for: ringtone.excerptFileName, in: appBundle), "Missing excerpt for \(ringtone.id)")
            XCTAssertNotNil(resourceURL(for: ringtone.fullTrackFileName, in: appBundle), "Missing full track for \(ringtone.id)")
        }
    }

    private func resourceURL(for filename: String, in bundle: Bundle) -> URL? {
        let fileURL = URL(fileURLWithPath: filename)
        return bundle.url(
            forResource: fileURL.deletingPathExtension().lastPathComponent,
            withExtension: fileURL.pathExtension
        )
    }
}
