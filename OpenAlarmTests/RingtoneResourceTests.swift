import XCTest
@testable import OpenAlarm

final class RingtoneResourceTests: XCTestCase {
    func testEveryCatalogRingtoneResourceExistsInAppBundle() {
        for ringtone in RingtoneCatalog.all where !ringtone.isDefault {
            XCTAssertNotNil(resourceURL(for: ringtone.excerptFileName), "Missing excerpt for \(ringtone.id)")
            XCTAssertNotNil(resourceURL(for: ringtone.fullTrackFileName), "Missing full track for \(ringtone.id)")
        }
    }

    private func resourceURL(for filename: String) -> URL? {
        let fileURL = URL(fileURLWithPath: filename)
        return Bundle.main.url(
            forResource: fileURL.deletingPathExtension().lastPathComponent,
            withExtension: fileURL.pathExtension
        )
    }
}
