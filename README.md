# OpenAlarm

OpenAlarm is an open-source alarm clock for iPhone, built with SwiftUI and
AlarmKit. It is designed for mornings when dismissing a notification is too
easy: an alarm can require a challenge, limit snoozes, and check a few minutes
later that you are still awake.

The app targets iOS 26 and is currently in active development. Until the known
reliability work in the scheduler inventory is complete, do not use it as your
only safety-critical alarm.

Website: [tryopenalarm.com](https://tryopenalarm.com)

## What it does

- One-shot and weekly repeating alarms
- Configurable snooze duration and snooze budget
- One-time skip and change-next-time overrides for repeating alarms
- A rolling five-alarm bridge window to make overrides resilient
- Math, memory, shake, step-counting, and object-scanning disarm challenges
- A wake-up check that can re-trigger an alarm when it is not confirmed
- Nap timers with pause, resume, extend, and Live Activity controls
- Per-alarm settings layered over global alarm and nap defaults
- English and German localization

Alarm audio, challenge state, and scheduling data stay on the device. The app
contains no advertising, analytics, tracking SDK, account system, or network
client. Camera classification runs on-device; shake challenges use device
motion, while step challenges use Core Motion's system-generated pedometer
data. See the [privacy policy](https://tryopenalarm.com/privacy) for the
permission-level explanation.

## Project status

OpenAlarm is usable beta software, not a finished safety product. The current
behavior contract and known defects live in
[`docs/scheduler-functional-inventory.md`](docs/scheduler-functional-inventory.md).
In particular, cross-process writes from the app and its intents still need a
versioned merge strategy.

## Requirements

- macOS with Xcode and the iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44.1 or newer
- An iOS 26 simulator or device
- Swift 6 for the headless scheduling-core tests

Install XcodeGen with Homebrew if needed:

```bash
brew install xcodegen
```

## Build the app

The checked-in Xcode project is generated from [`project.yml`](project.yml).
Regenerate it after adding, removing, or moving project files:

```bash
make generate
```

Build for a simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project OpenAlarm.xcodeproj -scheme OpenAlarm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### Signing a fork

The committed identifiers belong to the upstream app. To run a fork on a
physical device, change all of the following to values owned by your Apple
Developer account, then run `make generate`:

- `DEVELOPMENT_TEAM` and the three bundle identifiers in `project.yml`
- the app-group identifier in both `.entitlements` files
- `appGroupSuiteName` in `OpenAlarm/Shared/OpenAlarmSharedDefaults.swift`

Simulator builds and CI disable signing and do not need an Apple Developer
account.

## Tests and guardrails

Run the Foundation-only scheduling suite without a simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Run the app-level resource and task-registry tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project OpenAlarm.xcodeproj -scheme OpenAlarm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run repository guardrails:

```bash
make check
```

The guardrails reject direct SwiftUI string literals, mismatched English and
German localization keys, and regressions in the shared glass-button styles.
GitHub Actions also runs the core suite and a no-signing device-SDK build.

## Architecture

- `AlarmStore` is the `@MainActor` application orchestrator for alarm CRUD,
  permissions, naps, wake checks, and disarm challenges.
- `AlarmStateMachine` models lifecycle transitions as pure state and effects.
- `BridgeDateCalculator` performs DST-safe recurring-date and override math.
- Models and persistence are Foundation-only and are shared with App Intents
  through an app-group `UserDefaults` suite.
- Stop, snooze, and nap controls use `LiveActivityIntent` so the app process can
  reconcile shared state after an interaction.
- The scheduling core is also exposed as a local Swift package for fast,
  simulator-free tests.

Useful design references:

- [`docs/scheduler-functional-inventory.md`](docs/scheduler-functional-inventory.md)
- [`docs/design-spec.md`](docs/design-spec.md)
- [`docs/onboarding-architecture.md`](docs/onboarding-architecture.md)
- [`docs/alarm-exception-edge-cases.md`](docs/alarm-exception-edge-cases.md)

## Repository layout

```text
OpenAlarm/                       iOS application
OpenAlarmLiveActivities/         Widget and Live Activity extension
OpenAlarmSchedulingCoreTests/    Swift package tests
OpenAlarmTests/                  App-level XCTest suite
docs/                            Architecture and behavior documentation
maestro/                         UI automation flows
scripts/                         Guardrails and release automation
website/                         Astro website for tryopenalarm.com
project.yml                      XcodeGen source of truth
```

## Website

The website is a static Astro project deployed with Cloudflare Workers:

```bash
cd website
npm ci
npm run build
```

## TestFlight automation

[`scripts/upload_and_attach_testflight.sh`](scripts/upload_and_attach_testflight.sh)
archives, uploads, polls App Store Connect, attaches a build to a beta group,
and can submit an external build for Beta App Review. Credentials and private
IDs are read from an ignored environment file or the process environment.
See [`scripts/README.md`](scripts/README.md) for required variables and usage.

## Contributing

Bug reports and focused pull requests are welcome. Please open an issue before
large architectural changes, keep user-visible strings localized in English
and German, and run the relevant tests plus `make check` before submitting.

## License

OpenAlarm source code and project-owned assets are available under the
[MIT License](LICENSE).

Bundled third-party audio is not relicensed under MIT. Each recording retains
the license shown in
[`OpenAlarm/Resources/Ringtones/SOURCES.md`](OpenAlarm/Resources/Ringtones/SOURCES.md),
which is also included in the built app and represented in its Credits screen.
