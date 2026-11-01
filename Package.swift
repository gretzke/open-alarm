// swift-tools-version: 6.2

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
                "AlarmStore.swift",
                "Scheduling/AlarmScheduling.swift",
                "Scheduling/AlarmIntentLifecycle.swift",
                "Scheduling/AlarmStateMachine.swift",
                "Scheduling/BridgeDateCalculator.swift",
                "Models/AlarmDefinition.swift",
                "Models/AlarmSettingsBackup.swift",
                "Models/AlarmSettingsCore.swift",
                "Models/AlertReferenceStore.swift",
                "Models/RingtoneCatalog.swift",
                "Models/TaskLogic/MathProblemGenerator.swift",
                "Models/TaskLogic/ShakeEnergyModel.swift",
                "Models/TaskLogic/MemoryPatternGenerator.swift",
                "Models/TaskLogic/ScanObjectCatalog.swift",
                "Models/AlarmPersistenceStore.swift",
                "Models/PermissionModels.swift",
                "Models/WakeUpCheckModels.swift",
                "Services/AlarmStoreEnvironment.swift",
                "Services/AlarmSettingsBackupCoordinator.swift",
                "Services/BedsideDisplaySession.swift",
                "Services/ICloudAlarmSettingsStore.swift",
                "Services/ICloudKeyValueStore.swift",
                "Screens/Components/FoldContentRegion.swift",
                "Screens/Nap/NapDawnProgress.swift",
                "Screens/Onboarding/OnboardingEngine.swift",
                "Screens/Tasks/ForceCloseAlarmManager.swift",
                "Screens/Tasks/TaskDescriptor.swift",
                "Screens/Tasks/TaskModels.swift",
                "Shared/BackstopSlotStore.swift",
                "Shared/LastRingtoneStore.swift",
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
