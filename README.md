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
- A bedside nap countdown with a dawn glow during the final five minutes
- Landscape layouts and fold-aware full-screen content on iPhone Duo
- Per-alarm settings layered over global alarm and nap defaults
- iCloud restoration for global alarm and nap defaults after reinstalling
- English and German localization

Alarm audio, individual alarms, and scheduling state stay on the device. Global
alarm settings are copied to the user's private iCloud key-value store when
iCloud is available so they can be restored after reinstalling. The app contains
no advertising, analytics, tracking SDK, or account system. Camera
classification runs on-device; shake challenges use device motion, while step
challenges use Core Motion's system-generated pedometer data. See the
[privacy policy](https://tryopenalarm.com/privacy) for the permission-level
explanation.

## Project status

OpenAlarm is usable beta software, not a finished safety product. The current
behavior contract and known defects live in
[`docs/scheduler-functional-inventory.md`](docs/scheduler-functional-inventory.md).
In particular, cross-process writes from the app and its intents still need a
versioned merge strategy.

## Requirements

- macOS with Xcode 27.1 or newer (the app still runs on iOS 26)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44.1 or newer
- An iOS 26 simulator or device
- Swift 6.2 or newer for the native logic tests

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

Run the logic tests on the Mac without a simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test
```

The native package compiles the app's production sources for scheduling,
`AlarmStore`, intent lifecycle rules, cloud backup reconciliation, onboarding,
task registry metadata, bedside session state, fold geometry, and nap dawn
progress. Tests inject device services and scheduling failures at the same
boundaries used by the iOS app. The existing XCTest and Swift Testing assertions
run together. `make test` limits SwiftPM to four build jobs.

The ringtone packaging test needs the actual SDK-built app. It is skipped when
no app path is supplied. Build the app without a simulator, then inspect that
artifact from the native test runner:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project OpenAlarm.xcodeproj -scheme OpenAlarm \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios -jobs 4 CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  make test-app-resources \
  APP_BUNDLE_PATH="$PWD/build/ios/Build/Products/Debug-iphoneos/OpenAlarm.app"
```

This checks every catalog excerpt and full track in the built application bundle.
CI runs it after the SDK build. These unit tests run without a booted simulator.

Use the shared heavy-build claim before starting SwiftPM or Xcode jobs on a
shared development Mac. Native test success covers the portable logic. It does
not establish AlarmKit delivery, permission dialogs, Live Activity rendering,
or UIKit idle-timer integration. SDK compile checks verify the iOS adapters
without booting a simulator.

Run repository guardrails:

```bash
make check
```

The guardrails reject direct SwiftUI string literals, mismatched English and
German localization keys, and regressions in the shared glass-button styles.
GitHub Actions also runs the native suite and a no-signing device-SDK build.

## Architecture

- `AlarmStore` is the `@MainActor` application orchestrator for alarm CRUD,
  permissions, naps, wake checks, and disarm challenges.
- `AlarmStateMachine` models lifecycle transitions as pure state and effects.
- `BridgeDateCalculator` performs DST-safe recurring-date and override math.
- Models and persistence are Foundation-only and are shared with App Intents
  through an app-group `UserDefaults` suite.
- Global alarm settings are mirrored to iCloud key-value storage and imported
  only when an installation has no local alarm data.
- Stop, snooze, and nap controls use `LiveActivityIntent` so the app process can
  reconcile shared state after an interaction.
- The native Swift package shares production logic with the app. iOS adapters
  provide AlarmKit scheduling, device services, and task views.

Useful design references:

- [`docs/scheduler-functional-inventory.md`](docs/scheduler-functional-inventory.md)
- [`docs/design-spec.md`](docs/design-spec.md)
- [`docs/onboarding-architecture.md`](docs/onboarding-architecture.md)
- [`docs/alarm-exception-edge-cases.md`](docs/alarm-exception-edge-cases.md)
- [`docs/iphone-duo.md`](docs/iphone-duo.md)

## Repository layout

```text
OpenAlarm/                       iOS application
OpenAlarmLiveActivities/         Widget and Live Activity extension
OpenAlarmSchedulingCoreTests/    Native Swift package tests
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
