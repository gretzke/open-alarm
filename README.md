# Open Alarm

An iOS alarm app built on SwiftUI and **AlarmKit** (iOS 26) that makes sure you
actually get up: alarms can require disarm challenges, re-check that you're
awake a few minutes after you stop them, and resist being silenced or
force-closed.

## Features

- **Alarms** — one-shot (optionally self-deleting) or repeating on weekly
  weekdays, with per-alarm labels.
- **Snooze** — configurable duration and maximum count; the snooze button
  disappears when the budget is used up.
- **Skip / change next occurrence** — one-off exceptions for repeating alarms.
  Implemented as a rolling window of 5 one-shot "bridge" alarms so a single
  failed restore can't lose future occurrences; the canonical schedule is
  restored automatically once the exception has passed.
- **Disarm challenges** — math problems (or a dummy task) required to silence
  an alarm. During a challenge the app plays a looping alarm sound, pins the
  system volume so it can't be turned down, and keeps a rolling backstop alarm
  scheduled so force-closing the app just makes the alarm ring again.
- **Wake-up check** — after disarming, the app can ask "are you awake?" a few
  minutes later; no confirmation means the full alarm fires again.
- **Naps** — quick countdown alarms with pause/resume/extend and a Live
  Activity (Lock Screen + Dynamic Island) with controls.
- **Settings cascade** — global defaults, separate nap defaults, and per-alarm
  custom settings.
- Localized in English and German.

## Architecture

| Piece | Where | Notes |
| --- | --- | --- |
| `AlarmStore` | `OpenAlarm/AlarmStore.swift` | `@MainActor` orchestrator: CRUD, permissions, nap lifecycle, wake-check sessions, disarm pipeline |
| `AlarmStateMachine` | `OpenAlarm/Scheduling/` | Pure `(phase, event) → (phase, effects)` transitions for every app-side lifecycle change |
| `BridgeDateCalculator` | `OpenAlarm/Scheduling/` | DST-safe occurrence math for override bridge alarms |
| Models & persistence | `OpenAlarm/Models/` | Foundation-only model layer, backward-compatible Codable, app-group `UserDefaults` store |
| Intents | `OpenAlarm/Intents/` | `StopIntent`/`SnoozeIntent`/nap intents run in extension processes and write to the shared store; the app reloads and reconciles |
| Live Activities | `OpenAlarmLiveActivities/` | Widget extension for nap countdown + ringing alarm |

The Foundation-only core (state machine, date math, models, persistence) is
also compiled as an SPM package (`Package.swift`) so it can be tested headless
with `swift test` — no simulator required. The full behavior catalog lives in
[`docs/scheduler-functional-inventory.md`](docs/scheduler-functional-inventory.md).

More docs: [`docs/design-spec.md`](docs/design-spec.md) (locked visual
language), [`docs/onboarding-architecture.md`](docs/onboarding-architecture.md),
[`docs/alarm-exception-edge-cases.md`](docs/alarm-exception-edge-cases.md).

## Building

This repo uses [xcodegen](https://github.com/yonaskolb/XcodeGen); the Xcode
project is generated from `project.yml`:

```bash
make generate           # regenerate OpenAlarm.xcodeproj after adding files
```

Build for the simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project OpenAlarm.xcodeproj -scheme OpenAlarm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Testing

```bash
swift test              # scheduling core: state machine, date math, models, persistence
make check              # guardrails: no UI literals, i18n parity, glass-button migration
```

CI (GitHub Actions) runs the guardrails on Ubuntu plus `swift test` and a
device-SDK compile on macOS.

## i18n guardrails

- **No direct UI literals**: use `L10n.*` keys in SwiftUI instead of hardcoded strings.
- `scripts/check_no_literals.sh` fails if someone adds things like `Text("Hello")`.
- `scripts/check_i18n.sh` fails if `en/de/...` key sets drift.

Optional local hard-stop before every commit:

```bash
git config core.hooksPath .githooks
```

### Add a new language

1. Create a new localization folder:
   - `OpenAlarm/Resources/<lang>.lproj/Localizable.strings`
2. Add translated keys.
3. Add `<lang>` to `LOCALIZATIONS` in `project.yml`.
4. Re-run project generation and checks:

```bash
make generate
make check
```

## Deterministic TestFlight upload + attach

Use the automation script below to perform a deterministic TestFlight flow:

1. bump `CURRENT_PROJECT_VERSION` and commit it,
2. archive + upload using Xcode,
3. poll App Store Connect until the uploaded build is ready,
4. attach the build to your beta group,
5. when `TESTFLIGHT_DISTRIBUTION=external`, submit the attached build to Beta App Review.

Sensitive values and account/private IDs are read from environment variables at runtime only.
Do not hardcode them in scripts or commit them to the repository.

Required environment variables:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `APP_ID`
- `BETA_GROUP_ID`
- `TEAM_ID`

```bash
ASC_KEY_ID="<ASC_KEY_ID>" \
ASC_ISSUER_ID="<ASC_ISSUER_ID_UUID>" \
APP_ID="<ASC_APP_ID>" \
BETA_GROUP_ID="<ASC_INTERNAL_BETA_GROUP_ID>" \
TEAM_ID="<APPLE_DEVELOPER_TEAM_ID>" \
./scripts/upload_and_attach_testflight.sh
```

Convenience option (recommended for local runs): keep these vars in a local untracked file such as `.env.testflight.local`, then `source` it before running the script (see `scripts/README.md`).

Optional overrides:

- `ASC_KEY_PATH` (default: `~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8`)
- `BUNDLE_ID` (default: `com.gretzke.openalarm`)
- `SCHEME` (default: `OpenAlarm`)
- `PROJECT` (default: `OpenAlarm.xcodeproj`)
- `ARCHIVE_PATH` (default: `build/OpenAlarm.xcarchive`)
- `POLL_SECONDS` (default: `20`)
- `POLL_TIMEOUT_SECONDS` (default: `1800`)
- `TESTFLIGHT_DISTRIBUTION` (default: `internal`; set `external` to omit the internal-only upload flag and submit Beta App Review after the build is attached)

External publishing intentionally does not call the optional beta build notification endpoint; use the default TestFlight notification behavior configured in App Store Connect.
