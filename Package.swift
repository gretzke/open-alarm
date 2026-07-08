// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenAlarmSchedulingCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "OpenAlarmSchedulingCore",
            targets: ["OpenAlarmSchedulingCore"]
        )
    ],
    targets: [
        .target(
            name: "OpenAlarmSchedulingCore",
            path: "OpenAlarm",
            sources: [
                "Scheduling/AlarmStateMachine.swift",
                "Scheduling/BridgeDateCalculator.swift",
                "Models/AlarmDefinition.swift",
                "Models/AlarmSettingsCore.swift",
                "Models/AlarmPersistenceStore.swift",
                "Shared/OpenAlarmSharedDefaults.swift"
            ],
            swiftSettings: [
                .define("OPENALARM_SCHEDULING_CORE_SPM")
            ]
        ),
        .testTarget(
            name: "OpenAlarmSchedulingCoreTests",
            dependencies: [
                "OpenAlarmSchedulingCore"
            ],
            path: "OpenAlarmSchedulingCoreTests"
        )
    ]
)
