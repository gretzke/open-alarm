import XCTest

@testable import OpenAlarm

@MainActor
final class TaskRegistryTests: XCTestCase {
    private let representativeTasks: [AlarmTask] = [
        .dummy,
        .math(difficulty: .medium, count: 3),
        .shake(intensity: 3),
        .memory(difficulty: 3, rounds: 3),
        .steps(count: 30),
        .scanObject(objectClass: "mug"),
    ]

    func testDescriptorTypeIDsAreUnique() {
        let typeIDs = TaskRegistry.descriptors.map(\.typeID)

        XCTAssertEqual(Set(typeIDs).count, typeIDs.count)
    }

    func testExactlyOneDescriptorMatchesEachTaskCase() {
        for task in representativeTasks {
            XCTAssertEqual(
                TaskRegistry.descriptors.filter { $0.matches(task) }.count,
                1,
                "Expected exactly one descriptor for \(task)"
            )
        }
    }

    func testPickerHidesDummyOutsideTestingWithoutAffectingRuntimeLookup() {
        XCTAssertFalse(TaskRegistry.pickerDescriptors(testingMode: false).contains { $0.typeID == "dummy" })
        XCTAssertEqual(TaskRegistry.descriptor(for: .dummy).typeID, "dummy")
    }
}
