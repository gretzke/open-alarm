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
                "AlarmScheduleReconciler.swift"
            ]
        ),
        .executableTarget(
            name: "OpenAlarmSchedulingCoreChecks",
            dependencies: [
                "OpenAlarmSchedulingCore"
            ],
            path: "OpenAlarmSchedulingCoreChecks"
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
