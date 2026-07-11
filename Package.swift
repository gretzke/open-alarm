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
                "Models/AlertReferenceStore.swift",
                "Models/RingtoneCatalog.swift",
                "Models/TaskLogic/MathProblemGenerator.swift",
                "Models/TaskLogic/ShakeEnergyModel.swift",
                "Models/TaskLogic/MemoryPatternGenerator.swift",
                "Models/TaskLogic/ScanObjectCatalog.swift",
                "Models/AlarmPersistenceStore.swift",
                "Shared/BackstopSlotStore.swift",
                "Shared/IntentDiagnostics.swift",
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
