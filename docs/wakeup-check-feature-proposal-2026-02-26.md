# Wake-up Check feature proposal (2026-02-26)

## Goal
After an alarm is dismissed, optionally require an explicit wake confirmation. If not confirmed within a fixed window, ring again. Repeat until user confirms awake.

## Product behavior (target)

1. User enables Wake-up Check for an alarm (or via defaults).
2. User dismisses alarm.
3. App schedules a wake-check notification after configurable delay (`delayMinutes`).
4. User must confirm awake within **3 minutes** of notification delivery.
5. If not confirmed in time, alarm rings again.
6. Repeat until confirmed.
7. Optionally disable snooze on wake-check re-rings.

---

## Architecture fit (current code)

Current app already has:
- App-owned alarm state in `AlarmStore`
- AlarmKit projection + reconciliation via `applyRemoteAlarms`
- Intent path (`SnoozeIntent`) and foreground refresh hooks

This feature should follow the same pattern:
- **Single source of truth in app state/persistence**
- **One idempotent reconciliation function** invoked from:
  1. intents
  2. `alarmUpdates`
  3. foreground/app-open

This avoids divergent implementations over time.

---

## Proposed data model additions

## 1) Wake-check defaults (global/shared)

```swift
struct WakeCheckDefaults: Codable, Equatable {
    var enabledByDefault: Bool           // for new alarms
    var delayMinutes: Int                // e.g. 5, 10, 15
    var disableSnoozeOnRealert: Bool     // “no snooze this time”
}
```

## 2) Per-alarm wake-check settings

Either:
- integrated into shared settings model, or
- explicit on `UserAlarm` (with default inheritance)

Recommended long-term: integrate with shared/default model for consistency.

## 3) Active wake-check session persistence

```swift
struct WakeCheckSession: Codable, Equatable {
    var alarmID: UUID
    var cycle: Int
    var checkAt: Date                    // when notification should fire
    var deadlineAt: Date                 // checkAt + 3 minutes
    var notificationID: String
    var isAwaitingConfirmation: Bool
}
```

Persist sessions in `AlarmPersistence` to survive app restarts/device state changes.

---

## Scheduling model

## On alarm dismissal (wake-check enabled)

1. Create/update wake-check session (`cycle += 1` as needed).
2. Schedule local notification at `now + delayMinutes` with actions.
3. Schedule fallback re-alert alarm at `notificationFire + 3 minutes`.
   - If `disableSnoozeOnRealert == true`, configure alert with no snooze button.
4. Set lifecycle to `.awaitingWakeCheck`.

## On wake confirmation action

1. Cancel pending fallback re-alert.
2. Cancel pending wake-check notification.
3. Clear wake-check session.
4. Restore canonical alarm projection:
   - repeating alarm -> restore repeating schedule
   - one-time alarm -> complete/delete according current rules

## On timeout / no confirmation

1. Fallback alarm rings again.
2. On dismissal, start next cycle (same algorithm).

---

## Permission model (as requested)

## Rules
- Do **not** request notification permission by default.
- Request only when user enables wake-check feature.
- Use pre-prompt screen before system permission request.

## Enable flow

1. User toggles Wake-up Check ON.
2. If notification status:
   - `.authorized` -> enable immediately
   - `.notDetermined` -> show explainer screen, then request
   - `.denied` -> show blocked screen

## Blocked screen actions

- **Open Settings** (deep link app settings)
- **Disable Wake-up Check**
  - set wake-check OFF in defaults
  - set wake-check OFF for all alarms
  - cancel all active wake-check sessions + notifications

This matches your requested behavior.

---

## Notification interaction design

Use a dedicated notification category with actions:
- **I’m awake** → confirms and clears session
- Optional secondary action (e.g. “Ring me again”) depending on UX decision

Implementation options:
1. `UNUserNotificationCenterDelegate` with action identifiers (recommended)
2. open-app-only confirmation fallback if background action handling is restricted

---

## Reconciliation entry points (single shared path)

Create one function (example):

```swift
reconcileWakeCheck(for alarmID: UUID, trigger: WakeCheckTrigger)
```

Call from:
- `SnoozeIntent` / future wake-check intent handlers
- `applyRemoteAlarms` transition processing
- `handleAppOpened` foreground refresh

Function must be idempotent and safe to call repeatedly.

---

## Edge-case handling

1. **Phone off / app killed during cycle**
   - Session persistence + reconciliation on next app open.

2. **Notification permission revoked mid-cycle**
   - stop creating new cycles; surface blocked state; offer settings/disable actions.

3. **Repeating schedule interactions**
   - wake-check re-alert should never permanently break canonical recurrence.
   - always restore schedule projection when session resolves.

4. **Duplicate scheduling safety**
   - cancel stale notification/alarm refs before creating next session cycle.

---

## Suggested delivery phases

## Phase 1 — Infrastructure
- Notification permission service
- Wake-check defaults + persistence model
- Session persistence + reconciliation skeleton

## Phase 2 — Permission UX + settings
- Pre-prompt + denied flows
- Defaults UI integration
- Global disable path (defaults + all alarms)

## Phase 3 — Runtime scheduling
- Session lifecycle hooks on alarm dismissal
- Notification + fallback re-alert scheduling
- Confirm action handling

## Phase 4 — QA hardening
- Real-device matrix for permission states, repeats, skips, overrides
- Kill/restart/offline resilience checks

---

## Manual QA plan (recommended)

- Don’t change device clock.
- Use near-future alarms (2–3 minutes).
- Validate each path:
  - confirm within window
  - timeout -> re-ring
  - repeated cycles
  - permission denied flow
  - disable wake-check globally path
  - repeating schedule restore correctness
