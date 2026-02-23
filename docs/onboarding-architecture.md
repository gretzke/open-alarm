# OpenAlarm Onboarding Architecture (v1)

## Goals

- Split onboarding into two independent flows:
  - **One-time flow** (first install only)
  - **Reusable flow** (checks run on every app open)
- Keep both flows extensible for adding screens later.
- Prioritize one-time screens before reusable checks.

## Persistence

- Key: `ONBOARDING_COMPLETE`
- Storage: `UserDefaults.standard`
- Set to `true` after one-time flow completion.

## Current screen model

### One-time screens

Ordered list (extensible):

1. `welcome`

### Reusable checks

Priority-ordered (lower number = higher priority):

- `alarm_permission` (priority `0`)
  - `authorized` → no screen
  - `notDetermined` → pre-permission explainer screen
  - `denied` → settings recovery screen

## Runtime behavior

On each app open / foreground:

1. Evaluate one-time path:
   - If `ONBOARDING_COMPLETE == false`, enqueue one-time screens first.
2. Evaluate reusable checks by priority and enqueue unmet screens.
3. Present the first screen in the resulting queue.

This means:
- First install: `welcome` always appears first.
- After completing one-time onboarding, app immediately transitions into reusable checks.
- On future launches, reusable checks run every time.
- If user revokes alarm permission later, reusable permission screen appears again automatically.

## Extensibility hooks

- Add one-time screens by appending to `oneTimeSteps` in `OnboardingEngine`.
- Add reusable checks by appending `ReusableOnboardingRule` entries with:
  - stable `id`
  - numeric `priority`
  - `buildStep(context)` mapping

## Alarm permission implementation

Uses AlarmKit (`iOS 26+`):

- `AlarmManager.shared.authorizationState`
- `AlarmManager.shared.requestAuthorization()`

States handled:
- `.notDetermined`
- `.denied`
- `.authorized`

## UX currently implemented

- One-time welcome with large icon and trust list:
  - no subscriptions
  - no ads
  - no tracking
  - open source forever
- Permission pre-prompt screen (`notDetermined`) with explicit next action.
- Permission denied recovery screen (`denied`) with deep-link to app settings.
