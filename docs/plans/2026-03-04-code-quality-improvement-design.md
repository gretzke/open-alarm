# Code Quality Improvement Design

**Date:** 2026-03-04
**Score:** 6/10 → target 8/10
**Goal:** Make the codebase readable and easy to maintain while preserving the full feature set.

## Current State

- 26 Swift files, ~10,000 lines
- `AlarmStore.swift` is a 2,280-line god object with 5+ responsibilities
- Pure scheduling logic (`AlarmScheduleReconciler.swift`) is well-tested (1,761 lines of tests)
- `AlarmStore` has zero test coverage
- Pending-queue cleanup pattern is copy-pasted 6+ times
- `NapDurationPicker` duplicated across two files
- `MainTabView.swift` has 7+ view structs in 863 lines
- Localization bug: hardcoded English weekday symbols in `AlarmRowView`
- `AlarmStore` imports `SwiftUI` for view-layer helpers

## Approach: Surgical Extraction

Break `AlarmStore` into focused classes, deduplicate shared patterns, fix bugs, and clean up the view layer.

---

## Section 1: Extract WakeUpCheckPipelineController

**New file:** `WakeUpCheckPipelineController.swift` (~400 lines)

**Methods that move:**
- `reconcileWakeUpCheckPipeline(for:settings:referenceDate:)`
- `startWakeUpCheckCycle(for:alarm:settings:)`
- `completeWakeUpCheck(for:)`
- `applyWakeUpCheckArmingFailureResolution(for:resolution:)`
- `clearAllWakeUpCheckSessions()`
- `wakeUpCheckSessionsByAlarmID` dictionary
- `persistWakeUpCheckSessions()`

**Dependencies (injected via init):**
- `AlarmPersistence` — session read/write
- `WakeUpCheckNotificationService` — scheduling notifications
- `WakeUpCheckStopIntentArmService` — arming the stop intent
- Callback/delegate for "alarm needs rescheduling"

**AlarmStore changes:** Holds a `let wakeUpCheckController: WakeUpCheckPipelineController` and delegates all wake-check calls to it.

---

## Section 2: Extract AlarmScheduleCoordinator

**New file:** `AlarmScheduleCoordinator.swift` (~500 lines)

**Methods that move:**
- `reconcileSchedule(target:referenceDate:)` (the `AlarmScheduleReconcileHandling` conformance)
- `reconcileAllAlarmSchedules(referenceDate:)`
- `reconcileSchedulingForAlarm(_:referenceDate:)`
- `deterministicPlanningBarrier(for:referenceDate:)`
- `runtimeConvergenceBarrier(for:plan:referenceDate:)`
- `scheduleManualRuntimeQueueWithRepair(for:desiredDates:referenceDate:)`
- `scheduleRepeatRestore(for:)`
- `pendingRepeatRestores` set

**Dependencies (injected via init):**
- `AlarmManager` — schedule/cancel/stop calls
- `AlarmPersistence` — overrides, pending IDs
- `WakeUpCheckPipelineController` — wake-check reconciliation
- Data-access callback to read current alarms/settings

**AlarmScheduleReconcileEntrypoint:** The coordinator registers itself (or AlarmStore registers the coordinator) as the `AlarmScheduleReconcileHandling` conformer.

---

## Section 3: Make AlarmPersistence Injectable + Deduplicate

**Injectable persistence:**
- Define `AlarmPersistenceProtocol` with all current static methods as instance methods
- `AlarmPersistence` becomes a concrete implementation backed by `UserDefaults`
- All consumers receive it via init

**Pending-queue deduplication:**
- Add `removePendingID(_ id: UUID, from key: PendingIDKey) -> Bool` to `AlarmPersistence`
- `PendingIDKey` enum covers `.snooze`, `.wakeStart`, `.wakeConfirm`
- Replaces 6+ copy-pasted read-modify-write blocks

**Decode error logging:**
- Add `os.Logger` to `AlarmPersistence` for decode failures
- No behavioral change, just visibility

---

## Section 4: View Layer Cleanup

**Split `MainTabView.swift`:**
- `AlarmHomeView.swift` — `AlarmHomeView`, `AlarmRowView`, `NapBannerView`, `ActiveNapRowView`
- `SettingsHomeView.swift` — `SettingsHomeView`, `DefaultSharedSettingsView`
- `NapDurationPicker.swift` — consolidated from two duplicate pickers
- `MainTabView.swift` — just the tab shell (~50 lines)

**Move UI helpers out of AlarmStore:**
- `lifecycleLabel(for:)`, `permissionStatusLabel()`, `userFacingErrorMessage(for:)` → view-layer extensions
- Remove `SwiftUI` import from `AlarmStore`

**Fix localization bug:**
- Replace `mondayFirstWeekdays` in `AlarmRowView` with `AlarmWeekday.orderedForCurrentLocale()` + `veryShortSymbol()`
- Remove duplicated `nextRepeatingDate` — use `AlarmSchedulePlanner.nextCanonicalOccurrence`

**Consolidate NapDurationPicker:**
- Merge `NapDurationEditorPicker` and `NapDurationPicker` into one shared component

---

## Expected Outcome

| Metric | Before | After |
|---|---|---|
| `AlarmStore.swift` lines | 2,280 | ~1,200 |
| Files with 1 clear responsibility | ~18/26 | ~24/30 |
| Duplicated pending-queue blocks | 6+ | 1 |
| Duplicated duration pickers | 2 | 1 |
| Duplicated next-date computations | 3 | 1 |
| `AlarmStore` testable without UI | No | Yes (with injected persistence) |
| Localization bug | Yes | Fixed |

**Target score:** 8/10 (up from 6/10). The remaining 2 points would come from adding comprehensive unit tests for the extracted coordinators and `OnboardingEngine`, which is a separate effort.
