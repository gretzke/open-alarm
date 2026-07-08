> **Superseded (2026-07-09):** These notes describe the pre-Phase-1 architecture (AlarmSchedulePlanner / AlarmScheduleReconcilerTests), replaced wholesale in commit 9e52e0e. Kept as a historical record; see docs/scheduler-functional-inventory.md for current behavior.

# Run Notes — Unified Scheduling Redesign (2026-02-28)

## Objective
Implement unified scheduling redesign so temporary schedule overrides are deterministic and independent from wake-check/snooze/ringtone config.

## Execution Checklist

- [x] 1) Create checklist in run notes and follow it.
- [x] 2) Design data model for temporary override mode and manual-queue anchors.
- [x] 3) Implement planner/reconciler producing deterministic scheduling operations.
- [x] 4) Integrate AlarmStore callbacks and app-open reconciliation hook.
- [x] 5) Ensure duplicate callback idempotency.
- [x] 6) Add deterministic tests for disable-next/modify-next earlier/later + mutual exclusivity + schedule-change-clears-overrides.
- [x] 7) Run checks/tests and capture exact outputs.
- [x] 8) Commit milestone(s) and final commit with clear messages.

## Design Notes

- Added explicit `AlarmSchedulePlanner` state machine primitives:
  - canonical schedule spec/signature
  - temporary override state (`disableNext`, `modifyNext`)
  - manual queue bridge planning (depth = 5)
  - restore criterion: `firedAt >= restoreAnchorDate`
- Added persistent model fields on `UserAlarm`:
  - `scheduleConfigReferenceID` (stable config identity)
  - `temporaryScheduleOverride`
  - `manualScheduleQueue`
- Kept `nextTriggerOverrideDate` and `skipNextUntilDate` as compatibility/display fields only.

## Reconciliation Strategy

- Any lifecycle opportunity now reconciles schedule state:
  - app bootstrap
  - app foreground/open
  - alarm callback stream updates
  - explicit schedule/config writes
- When temporary override active:
  - recurring runtime alarm is removed
  - next 5 one-shot manual bridges are (re)scheduled deterministically
  - callback/cold-start completion restores recurring only when fired time reaches restore anchor

## Idempotency

- Duplicate callback handling is idempotent by persisted state transition:
  - once override is cleared, duplicate callbacks no longer trigger restore mutations.

## Verification Commands + Output

### 1) Build
```bash
xcodebuild -project OpenAlarm.xcodeproj -scheme OpenAlarm -destination 'generic/platform=iOS' build
```
Result:
- `** BUILD SUCCEEDED **`

### 2) Deterministic scheduler checks
```bash
swift run OpenAlarmSchedulingCoreChecks
```
Result:
- `✅ Deterministic scheduling checks passed (18/18)`

### 3) XCTest suite
```bash
xcodebuild -project OpenAlarm.xcodeproj -scheme OpenAlarmTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' test
```
Result:
- `Test Suite 'All tests' passed`
- `Executed 18 tests, with 0 failures (0 unexpected)`
- `** TEST SUCCEEDED **`
