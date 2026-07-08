> **Superseded (2026-07-09):** These notes describe the pre-Phase-1 architecture (AlarmSchedulePlanner / AlarmScheduleReconcilerTests), replaced wholesale in commit 9e52e0e. Kept as a historical record; see docs/scheduler-functional-inventory.md for current behavior.

# Run Notes — OpenAlarm reconciler/testing (2026-02-27)

## Completion checklist
- [x] Audit AlarmStore + related persistence/intent paths for schedule lifecycle and one-shot exception behavior.
- [x] Add pure/domain reconciliation model + function (desired alarm plan vs actual scheduling state) that returns concrete scheduling operations.
- [x] Integrate AlarmStore through a thin adapter layer that executes reconciler operations with minimal behavior churn.
- [x] Make fire/ring transition handling deterministic and idempotent under duplicate callback sequences.
- [x] Add cold-start reconciliation recovery for persisted temporary/one-shot state (skip-next and modify-next-once).
- [x] Add deterministic tests for required scenarios:
  - [x] skip-next -> one-shot/next valid occurrence -> recurring restore
  - [x] modify-next-once -> recurring restore
  - [x] duplicate fire callback idempotency
  - [x] cold-start recovery from temporary/one-shot mode
- [x] Add minimal XCTest target if missing and wire tests.
- [x] Run relevant checks/tests and capture exact command outputs.
- [x] Commit milestone(s) and final commit with clear messages.

## Notes
- Scope guard respected: no unrelated refactors, no TestFlight/upload actions.
- Deterministic runnable checks are wired via `swift run OpenAlarmSchedulingCoreChecks` because this worker cannot run `xcodebuild` without host-level license acceptance (`sudo xcodebuild -license`).
- XCTest scenarios are present in `OpenAlarmSchedulingCoreTests/AlarmScheduleReconcilerTests.swift` and wired into `OpenAlarmTests` target via `project.yml` + regenerated `OpenAlarm.xcodeproj`.
