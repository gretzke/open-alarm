# Alarm exception edge cases & mitigation ideas (draft)

**Status:** Design notes only. No fixes in this doc are implemented yet.

## Why this exists
Track known failure modes for recurring alarms when we apply one-off exceptions ("skip next" / "change next time") and then need to restore normal scheduling.

## Current design direction (context)
1. User has a canonical recurring schedule (e.g. M/W/F 09:00).
2. For a one-off exception, recurring AlarmKit schedule is paused/canceled and a one-shot alarm is scheduled.
3. Recurring schedule is restored when the exception lifecycle is complete.

---

## Edge cases / potential issues

### EC-001 — Exception active, phone off, restore never runs
- **Scenario:** User skips or modifies next ring, then phone is off / app never resumes / no intent callback arrives.
- **Risk:** Recurring schedule may not restore in time.
- **Fix idea (requested):** Fallback local notification to prompt recovery.
  - Schedule a local notification for shortly **after** the expected ring time, asking user to open OpenAlarm to reactivate/verify alarms.
  - Delete pending fallback notification as soon as the alarm actually enters ringing flow (or equivalent successful lifecycle signal).
  - If ring is missed (e.g. device off), fallback notification still appears later and nudges recovery.
- **Status:** Not implemented.
- **Open questions:**
  - What delay after expected ring (e.g. +5 min vs +15 min)?
  - Notification copy + tone.
  - Should this be optional in settings?

### EC-002 — Only next occurrence is scheduled, increasing miss risk
- **Scenario:** During exception mode we schedule only one upcoming alarm.
- **Risk:** If restore path fails once, future occurrences may be lost.
- **Fix idea (requested):** Materialize a rolling window of next occurrences.
  - Instead of scheduling only the immediate next, schedule the **next 5** occurrences derived from canonical schedule + exceptions.
  - On each lifecycle completion/edit, recompute and refill window.
- **Status:** Not implemented.
- **Open questions:**
  - Should window size be fixed at 5 or configurable?
  - How to handle dense schedules + many alarms with AlarmKit limits (`maximumLimitReached`)?

### EC-003 — Duplicate ringing from stale refs
- **Scenario:** Old schedule ref is not fully canceled before exception ref is added.
- **Risk:** Double ring on same day (e.g. modified 07:00 and stale 09:00 both fire).
- **Fix idea:** Atomic replace of per-alarm AlarmKit refs (`cancel/stop old -> schedule new -> verify`).
- **Status:** Not implemented.

### EC-004 — Restore trigger tied to wrong event
- **Scenario:** Restore happens on first interaction event (e.g. snooze) instead of lifecycle completion.
- **Risk:** Can race with snooze/wake-check flow and produce inconsistent next rings.
- **Fix idea:** Restore only when exception lifecycle is fully complete (no pending snooze/wake-check state).
- **Status:** Not implemented.

### EC-005 — Wake-check complexity on top of exception mode
- **Scenario:** Wake-up checks introduce additional alarms/state transitions overlapping with exception refs.
- **Risk:** State explosion and invalid transitions.
- **Fix idea:** Separate domain state machine from AlarmKit runtime refs; keep deterministic transition rules.
- **Status:** Not implemented.

---

## Implementation policy for this doc
- This document tracks ideas only.
- No behavior changes should be inferred as shipped until explicitly implemented, tested, and released.
