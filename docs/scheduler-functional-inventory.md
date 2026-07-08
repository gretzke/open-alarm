# Scheduler functional inventory

**Purpose:** Complete catalog of scheduler behavior as implemented today (2026-07-08), compiled from a full read of `AlarmStore.swift`, `AlarmStateMachine.swift`, `BridgeDateCalculator.swift`, `AlarmConfigurationBuilder.swift`, `AlarmDefinition.swift`, `AlarmModels.swift`, all intents, `ForceCloseAlarmManager`, and `OpenAlarmNotificationDelegate`. This is the requirements baseline for the state-machine consolidation refactor: every item here must either be preserved or explicitly dropped with a decision.

Requirement IDs (`R-x.y`) are for referencing from the refactor plan.

---

## 1. Alarm model & invariants

- **R-1.1** Three alarm types: `regular`, `nap(NapConfig)`, `tryOut`. Naps and try-outs are always `deleteAfterUse = true` (enforced by `AlarmTypePolicy.normalizeOnWrite`).
- **R-1.2** Trigger is either `.time(hour, minute)` (wall-clock, optionally recurring) or `.fixed(Date)` (naps, try-outs, snoozed instances).
- **R-1.3** Recurrence is `.none` or `.weekly([AlarmWeekday])`; weekdays always stored sorted by raw value. Non-empty repeat days forces `deleteAfterUse = false` (draft logic); setting `deleteAfterUse` clears repeat days.
- **R-1.4** Persisted runtime state on each alarm: `isEnabled`, `snoozeCount`, `lifecycleState` (scheduled / alerting / awaitingDisarmChallenge / awaitingWakeCheck / completed), `nextTriggerOverrideDate`, `activeOverride`.
- **R-1.5** Alarm names are trimmed on init and decode; empty name resolves to a localized default title at scheduling time; naps always use the localized nap label.
- **R-1.6** Alarm list is always sorted by hour, then minute, then UUID string (stable display order).
- **R-1.7** At most one nap exists at a time (creating a new nap deletes the existing one). At most one try-out exists at a time (same pattern).
- **R-1.8** `AlarmDefinition.schedule` maps to AlarmKit: `.relative` with `.never` or `.weekly(localeWeekdays)`; `AlarmScheduleResolver` prefers `fixedTriggerDate` for nap/tryOut, wall-clock schedule otherwise.

## 2. CRUD lifecycle

- **R-2.1** Create (regular / nap / try-out) requires AlarmKit authorization; requests it if not determined; throws `permissionDenied` otherwise. Alarm is persisted first, then scheduled via `.enabled` event through the state machine.
- **R-2.2** Update replaces the alarm from a draft (preserving `id` and `createdAt`), **clears any active override**, cancels the old override's bridge alarms, persists, then routes `.updated` (cancel-all + reschedule if enabled, cancel-all if disabled).
- **R-2.3** Delete cleans up, in order: pending-disarm entry, presented disarm UI, wake-check session + its notification, presented wake-check UI, then cancels all AlarmKit IDs known to the current phase (canonical or bridges) and removes the alarm. Deleting a nap also stops the nap Live Activity.
- **R-2.4** Enable/disable toggle:
  - Enabling while a skip-next override is active means "un-skip": clear override, cancel bridges, restore canonical schedule.
  - Disabling with `skipNext == true` on a repeating alarm activates the skip-next override instead of a plain disable.
  - Plain disable clears any override and cancels everything; plain enable resets `snoozeCount`, sets `lifecycleState = .scheduled`, schedules.
- **R-2.5** Every mutation updates `updatedAt`, re-sorts, and persists the full alarm array.

## 3. Scheduling mechanics (AlarmKit interaction)

- **R-3.1** All scheduling goes through `AlarmManager.schedule(id:configuration:)` with the alarm's own UUID as the AlarmKit ID (bridges use their own UUIDs).
- **R-3.2** Schedule failures retry exactly once after a `stop` + `cancel` of the same ID; second failure is logged and swallowed.
- **R-3.3** Cancellation is always the `stop(id:)` then `cancel(id:)` pair.
- **R-3.4** Canonical scheduling is skipped (with a warning) if the alarm still has an active override — bridge alarms own the schedule during an override.
- **R-3.5** Alarm configurations (via `AlarmConfigurationBuilder`):
  - Stop button always present; snooze button only when resolved settings allow another snooze (`canSnoozeAgain(currentCount:)`); snooze uses `.custom` behavior wired to `SnoozeIntent`.
  - When snooze is enabled, `countdownDuration.postAlert` is set to the snooze interval — required for AlarmKit `.fixed` schedules to transition countdown → alerting after `stop()`.
  - Snooze duration 0 is a 5-second testing sentinel.
  - `forceDisableSnooze` parameter exists for callers to strip snooze.
  - Metadata carries `source` (parent alarm UUID) and `isShadowTrial` (= isTryOut); tint is the brand cyan.
  - Bridge configs use the **parent's** resolved settings and title but the **bridge's** UUID in Stop/Snooze intents; bridge snooze visibility is computed with `currentCount: 0`.
  - Wake-check backup and force-close configs: fixed date, stop-only, no snooze.

## 4. Firing pipeline (stop → disarm → outcome)

- **R-4.1** Alarm fires → user taps Stop → `StopIntent` (extension process): writes the fired ID into the shared pending-disarm set **first** (crash-safe minimal write), stops the AlarmKit alarm, stops any active force-close alarm, posts `disarmChallengeRequested`, opens the app.
- **R-4.2** App (on notification or foreground) processes pending disarm IDs **one at a time**: resolves the parent alarm (the pending ID may be a bridge UUID), marks `lifecycleState = .awaitingDisarmChallenge`, resets `snoozeCount`, presents the disarm challenge UI with the alarm's resolved tasks. Unknown/stale pending IDs are dropped. An already-presented challenge is never replaced (avoids sound-manager races).
- **R-4.3** Challenge completion (`.challengeCompleted` through the state machine) branches, in priority order:
  1. Wake-up check enabled → phase `.awaitingWakeCheck`, cancel the fired AlarmKit ID, start a wake-check session.
  2. Fired ID was a bridge of an active override → return to `.overrideActive` with the remaining bridge IDs (and refresh live bridge IDs from AlarmKit runtime).
  3. Repeating alarm → re-arm canonical schedule; reset `snoozeCount`; `lifecycleState = .scheduled`.
  4. `deleteAfterUse` (incl. naps, try-outs) → cancel + delete the alarm.
  5. One-shot kept alarm → `.completed`; alarm disabled (`isEnabled = false`, `lifecycleState = .completed`).
- **R-4.4** Completion also removes every plausible pending-disarm key: the alarm ID, the resolved AlarmKit ID, and all bridge IDs of the alarm's override. Then the next pending disarm (if any) is processed.
- **R-4.5** Stop events while already awaiting a disarm challenge or wake check are absorbed without state change (force-close alarm re-fires, backup alarm fires).

## 5. Snooze

- **R-5.1** Snooze runs entirely in `SnoozeIntent` (extension process): resolve parent by direct ID or bridge ID; unknown ID → just stop the AlarmKit alarm.
- **R-5.2** Snooze allowance: `snoozeEnabled` and (`maxSnoozes == nil` → unlimited, else `snoozeCount < maxSnoozes`). Disallowed → stop the alarm (no snooze).
- **R-5.3** A granted snooze increments `snoozeCount`, persists, and reschedules the **same AlarmKit ID** at `now + snoozeDuration` as a `.fixed` schedule (stop → cancel → schedule). For naps it also updates `fixedTriggerDate` and clears any pause state, then syncs the Live Activity.
- **R-5.4** Snoozing a repeating alarm temporarily replaces its recurring schedule with a fixed one; the recurring schedule is restored by the post-disarm re-arm (R-4.3.3).
- **R-5.5** Snooze count resets on: enable, disarm-challenge start, every post-disarm outcome, wake-check confirm, override activation/restore.
- **R-5.6** Snooze duration 0 = 5-second testing sentinel (applies in intent and config builder).
- **R-5.7** On cold start, an AlarmKit alarm in `.countdown`/`.paused` state (or `.scheduled` with `snoozeCount > 0`) is reconstructed as phase `.snoozed`.

## 6. Override system (skip next / modify next)

- **R-6.1** Overrides exist only for repeating alarms. Two kinds: `.skipNext`, `.modifyNext`.
- **R-6.2** Activating an override cancels the canonical AlarmKit schedule and materializes **5 one-shot bridge alarms** with fresh UUIDs (rolling window per EC-002, so one failed restore doesn't lose future occurrences):
  - Skip-next: compute 6 upcoming occurrences; bridges are occurrences 2–6; `restoreAnchorDate` = the skipped first occurrence; alarm shows as disabled (`isEnabled = false`) — the `isSkippingNext` state.
  - Modify-next: compute 5 occurrences; bridges are [modified first occurrence] + occurrences 2–5; `restoreAnchorDate = max(canonical first, modified date)` (prevents restoring before the same-day canonical slot); `nextTriggerOverrideDate` = the modified date (drives display).
- **R-6.3** Occurrence math (`BridgeDateCalculator`): wall-clock weekday/hour/minute via `calendar.nextDate(matching:.nextTime)` (DST-safe), searching strictly after `referenceDate + 1s`, merging per-weekday streams in fire-date order.
- **R-6.4** Activating a new override first cancels any existing override's bridges. Editing the alarm clears the override entirely. Disabling clears it. Re-enabling during skip-next un-skips (R-2.4).
- **R-6.5** Bridge firing runs the normal firing pipeline; after disarm (and wake-check, if enabled) the alarm returns to `.overrideActive` with the consumed bridge removed and live bridge IDs re-verified against AlarmKit runtime.
- **R-6.6** Restore: on every AlarmKit update (`reconcileOverrides`), any alarm whose `restoreAnchorDate` has passed AND whose phase is not mid-lifecycle (not alerting/snoozed/awaiting-disarm/awaiting-wake-check) gets: bridges canceled, override cleared, `isEnabled = true` restored if skip-next, `lifecycleState = .scheduled`, snooze reset, canonical schedule re-registered.
- **R-6.7** Settings changes on an alarm with an active override (`forceRescheduleAlarm`): cancel old bridges, recompute bridge dates (for modify-next, the modified time is re-derived from `nextTriggerOverrideDate`), issue **new** bridge UUIDs, keep the original `restoreAnchorDate`, reschedule all bridges.
- **R-6.8** Cold-start phase reconstruction for overridden alarms: bridge in `.alerting` → alerting; bridge `.paused` → snoozed; otherwise `.overrideActive` filtered to bridges that still exist in AlarmKit runtime. The canonical ID is expected NOT to be registered while an override is active.

## 7. Wake-up check

- **R-7.1** Trigger: completing a disarm challenge when resolved settings have `wakeUpCheckEnabled` (also reachable after bridge and backup-alarm firings — each restart increments the session `cycle`).
- **R-7.2** Session (`WakeCheckSession`, persisted): `checkAt = now + checkDelay`, `deadlineAt = checkAt + responseTimeout`, cycle counter, notification ID `wakecheck.<alarmID>.<cycle>`. Starting a new session cancels the previous cycle's notification, clears grace tracking and pending-confirm-UI state for the alarm.
- **R-7.3** Timing policy: check delay clamped to 1–60 min; response timeout min 1 min; `0` is a 5-second testing sentinel for both. Values are clamped at construction, decode, and use.
- **R-7.4** At session start: a local notification (with "I'm awake" action, category registered at launch) is scheduled for `checkAt` **only if notification permission is authorized**; a **backup AlarmKit alarm is always scheduled at `deadlineAt` reusing the alarm's own UUID** — if the user never confirms, the full alarm fires again (which re-runs stop → disarm → new wake-check cycle).
- **R-7.5** Confirmation surfaces:
  - Notification tap or "I'm awake" action → delegate persists the alarm ID into a pending-confirm-UI set and posts an in-process notification.
  - Foreground presentation of the wake-check notification is suppressed (app shows its own UI instead).
  - In-app: pending IDs are shown one at a time, but only once `checkAt` has passed — if early, a `Task.sleep` reschedules the presentation at `checkAt`.
  - On app open, any session past `checkAt` but before `deadlineAt` presents the confirmation UI even without a notification tap.
  - Stale pending-confirm IDs (no session) are dropped.
- **R-7.6** Grace period: if the app is opened from a notification tap with less than 60s remaining (but more than 0), the deadline extends once to `now + 60s`, the backup alarm is rescheduled, and the alarm ID is marked in a persisted grace set so force-quit cannot re-extend. Grace tracking clears on confirm and on new session.
- **R-7.7** Confirm (`.wakeCheckConfirmed`): cancel notification + backup alarm, remove session and pending-confirm ID, dismiss UI, then branch: active override → `.overrideActive` (bridges untouched); repeating → re-arm canonical; deleteAfterUse/nap/tryOut → delete; kept one-shot → `.completed` + disabled. Snooze reset and `lifecycleState` updated in all kept branches.
- **R-7.8** Global kill switch (`disableWakeUpCheckFeatureGlobally`): disables wake-check in global defaults, nap defaults, and every per-alarm custom settings; cancels all sessions, their notifications, and backup alarms; clears pending-confirm state. (Used when notification permission is denied.)
- **R-7.9** Wake-check requires notification permission: `featureRequirements` marks it; a launch-time prompt is shown if permission is denied while any alarm has wake-check enabled.
- **R-7.10** Session hygiene: sessions for deleted alarms are removed (and their notifications canceled) when sessions are loaded from persistence.

## 8. Disarm challenges & force-close protection

- **R-8.1** Challenge tasks come from resolved shared settings (`tasks: [AlarmTask]` — dummy or math with difficulty/count). The scheduler contract: the disarm UI is presented after every stop, and lifecycle only advances via `completeDisarmChallenge`.
- **R-8.2** While a challenge is active, `ForceCloseAlarmManager` maintains a rolling one-shot AlarmKit alarm ~20s out, rescheduled every 10s (new UUID each time, previous canceled only after the new one is registered — no gap). Force-closing the app therefore causes the alarm to re-fire. The current force-close ID is persisted in the shared defaults so `StopIntent` (extension process) can silence it.
- **R-8.3** On challenge UI appear, an orphaned persisted force-close alarm from a previous crash/force-quit is canceled.
- **R-8.4** During a challenge, `TaskSoundManager` plays a looping alarm sound (bundled `alarm_sound.caf`/`.mp3`, falling back to the system alarm sound) through an active `.playback` audio session, so the alarm keeps sounding **even when the app is minimized or the screen is locked**.
- **R-8.5** System volume is forced to the alarm level for the duration of the challenge: a hidden off-screen `MPVolumeView` slider sets the volume, a KVO observer on `outputVolume` reverts user changes, and a 0.2s polling timer catches held-down hardware volume buttons that KVO misses. The user cannot silence the challenge by turning the volume down. The level is configurable per settings cascade via `AlarmVolumeSettings.targetPercent` (default 20%, clamped 0–100; added upstream 2026-05). (Intentional anti-circumvention behavior — accepted App Store review risk; uses `MPVolumeView`'s internal slider.)
- **R-8.6** Playback self-heals: it resumes on `didBecomeActive` (return from background), after audio interruptions end, after route changes (0.1s delay), and after media-services resets; `play()` success is verified 0.5s later with up to 3 retries because playback can silently fail before the session is routed.
- **R-8.7** Stopping the challenge sound tears everything down (player, KVO, polling timer, notification observers, hidden volume view) and deactivates the audio session notifying other apps. The system volume is intentionally **not** restored to its pre-challenge value (it stays at the alarm level).

## 9. Naps

- **R-9.1** Create: duration in minutes → `.fixed(now + duration)`; duration 0 = 5-second testing sentinel; replaces any existing nap; settings resolve against nap defaults (see R-11).
- **R-9.2** Pause: capture `remainingSeconds` into `pausedRemainingSeconds`, cancel the AlarmKit alarm (`.disabled` event). Resume: new target `now + remaining`, clear pause, reschedule (`.enabled` event).
- **R-9.3** Extend (+minutes): adds to `durationMinutes`; if paused, extends `pausedRemainingSeconds` only (no reschedule); if running, pushes `fixedTriggerDate` and reschedules (`.updated`).
- **R-9.4** All nap mutations sync the nap countdown Live Activity; delete stops it.
- **R-9.5** Same operations are available from the Live Activity via intents (extension process): `NapExtendIntent`, `NapPauseIntent`, `NapResumeIntent`, `NapDeleteIntent` — each loads persistence, mutates, saves, stops/cancels/schedules AlarmKit directly, and syncs/stops the Live Activity. Missing nap → the Live Activity is stopped.
- **R-9.6** Deep link: `openalarm://nap/extend?minutes=N[&id=UUID]` extends the active nap (ID match optional but enforced when present).
- **R-9.7** Nap snooze (via SnoozeIntent) moves `fixedTriggerDate` and clears pause state (R-5.3).

## 10. Try-out alarms

- **R-10.1** `scheduleTryOut(sharedSettings:after:)`: one-shot `.fixed(now + seconds)` alarm with a snapshot of the provided settings as custom settings, `deleteAfterUse`, replacing any existing try-out. Metadata flags it `isShadowTrial`. Runs the full firing pipeline (including tasks/wake-check per its settings) and deletes itself at the end.

## 11. Settings cascade

- **R-11.1** Resolution order per alarm: `.custom(settings)` wins; `.useDefault` resolves to nap defaults for naps (if set) else global defaults; nap defaults `nil` means "use global".
- **R-11.2** Changing global defaults force-reschedules every enabled `.useDefault` alarm **except** naps that have their own nap defaults. Changing nap defaults force-reschedules enabled `.useDefault` naps. (Settings are pointers; changes propagate immediately, including regenerated bridge alarms per R-6.7.)
- **R-11.3** `SharedAlarmSettings` fields: snoozeEnabled, snoozeDurationMinutes, maxSnoozes (nil = unlimited), wakeUpCheckEnabled, wakeUpCheckDelayMinutes, wakeUpCheckResponseTimeoutMinutes, tasks, volume (`AlarmVolumeSettings`, added upstream 2026-05 — drives the challenge volume pin and the AlarmKit sound selection in `AlarmConfigurationBuilder.alarmKitSound(for:)`). Wake-check minutes and volume percent are clamped on every construction/decode path.
- **R-11.4** Default nap duration (default 35 min, 0 allowed as testing sentinel) and testing-mode flag and Live-Activity toggle are separate persisted settings.

## 12. Cross-process architecture

- **R-12.1** All state lives in the app-group `UserDefaults` suite (`group.com.gretzke.openalarm`, `.standard` fallback); one-time migration copies known keys from standard defaults (only where absent in the suite).
- **R-12.2** Contract: **intents write the truth; the app reloads.** `applyRemoteAlarms` (fired by the `alarmUpdates` stream) does a pure reload of alarms + wake-check sessions from persistence — no cleanup or deletion — then rebuilds phases, reconciles overrides, and processes pending queues.
- **R-12.3** Pending work queues in shared defaults bridge extension → app: pending-disarm IDs, pending wake-check-confirm-UI IDs, grace-applied IDs, force-close alarm ID. In-process `NotificationCenter` posts (`disarmChallengeRequested`, `wakeUpCheckConfirmationRequested`) wake the store when it's alive.
- **R-12.4** `remoteStates` (AlarmKit `Alarm.State` per ID) is maintained for UI display from the update stream / on foreground.

## 13. Cold start & reconciliation

- **R-13.1** On init: migrate store if needed, load settings + alarms + wake-check sessions, rebuild runtime phases, subscribe to `alarmUpdates`, register notification category, disable the Live-Activity toggle if system-level authorization is off.
- **R-13.2** `handleAppOpened` (foreground): refresh permissions and Live-Activity authorization, reload alarms, refresh remote state, reload sessions, rebuild phases, process pending wake-check confirmations, show due wake-check UI, process pending disarm challenges, sync nap Live Activity.
- **R-13.3** `rebuildRuntimePhases` reconstructs in-memory phases with this precedence: persisted `lifecycleState` (.awaitingDisarmChallenge / .awaitingWakeCheck) → override bridge runtime states → canonical AlarmKit runtime state (alerting / scheduled / countdown / paused, with `snoozeCount > 0` mapping scheduled → snoozed) → `.idle`. AlarmKit read failure clears all phases.
- **R-13.4** Permission gates: creating/updating/enabling requires AlarmKit authorization (request-if-needed); wake-check needs notification permission (R-7.9).

## 14. Persistence & migration compatibility

- **R-14.1** Alarms persist as one JSON blob under `OPENALARM_USER_ALARMS_V1`; all other keys are `_V1`-suffixed singletons.
- **R-14.2** Decode is fully backward-compatible: flat `hour`/`minute`/`repeatDays`/`fixedTriggerDate` reconstruct trigger/recurrence; flat `alarmType` string + `durationMinutes`/`pausedRemainingSeconds` reconstruct `NapConfig`; legacy `wakeUpCheck*` fields fold into custom settings; legacy `skipNextUntilDate` clears to enabled; every field has a default via `decodeIfPresent`.
- **R-14.3** Encode writes the same flat schema (forward compatibility with older builds).

## 15. Testing-mode sentinels (all must survive refactor)

- **R-15.1** Nap duration 0 → 5 seconds.
- **R-15.2** Snooze duration 0 → 5 seconds.
- **R-15.3** Wake-check delay 0 and response timeout 0 → 5 seconds each.
- **R-15.4** Try-out alarms fire `after: seconds` (arbitrary short intervals).

---

## Known defects & dead paths (status as of 2026-07-09)

- **D-1** — **Fixed (2026-07-09).** Force-unwrap replaced with a `.nextTime`-policy fallback; DST gap/fall-back tests added.
- **D-2** — **Fixed (2026-07-09).** Corrupt alarm blobs are quarantined under `OPENALARM_USER_ALARMS_CORRUPT_V1`; encode failures no longer delete the previous good data.
- **D-3** — **Deferred.** Cross-process read-modify-write races on the single alarms blob need a versioning/merge design (per-alarm keys or a write counter); a half-measure risks worse bugs. "Intents write truth, app reloads" mitigates the app→intent direction only.
- **D-4** — **Fixed (2026-07-09).** Override activate/restore and disarm presentation now route through the machine (`.overrideActivated`, `.overrideRestored(bridgeAlarmIDs:)`, `.disarmRequested`); dead events (`.stopped`, `.snoozed`, `.alarmKitStateChanged`, `.wakeCheckStarted`) deleted. Alerting/snoozed remain reconstruction-only phases (stop/snooze fire in extension processes) — documented in the machine header.
- **D-5** — **Fixed (2026-07-09).** Machine emits `.persist` effects for post-lifecycle bookkeeping (persist ordered before schedule so re-arm configs see the reset snooze count); `.scheduleAlarmKit` payload slimmed to `alarmID`.
- **D-6** — **Accepted + documented (2026-07-09).** UUID reuse is deliberate; comment added at the schedule site.
- **D-7** — **Fixed (2026-07-09).** `SchedulingConstants` centralizes bridge window size, testing sentinel, grace minimum.
- **D-8** — **Fixed (2026-07-09).** `OpenAlarmSharedDefaults.Key` holds the cross-process keys.
- **D-9** — **Deferred.** EC-001 fallback recovery notification is a new feature; design open questions remain (delay, copy, opt-out).
- **D-10** — **Fixed (2026-07-09).** SPM target compiles the real model files; the stub is deleted.
- **D-11** — **Accepted + documented (2026-07-09).** Setter no-op documented; characterization test pins it.
- **D-12** — **Fixed (2026-07-09).** Pending wake-check-UI task is cancelled and replaced instead of stacking sleeps.
- **D-13** — **Fixed (2026-07-09).** `(.completed, .enabled)` transition added; re-enabling a completed kept one-shot schedules again.
