# Open Alarm (iOS skeleton)

Minimal iOS app skeleton for the Open Alarm project.

## Design spec

- See `docs/design-spec.md` for the locked visual language and UI decisions.
- See `docs/onboarding-architecture.md` for onboarding flow architecture.

## Current scope

- SwiftUI app with a single screen
- Shows localized **Hello, World!** text
- Supports:
  - English (`en`) — development/fallback language
  - German (`de`)

## Language behavior

- The app follows the device/app preferred language automatically.
- If the selected language is unsupported, iOS falls back to English.
- Users can switch the app language in:
  - **Settings → OpenAlarm → Preferred Language**

## Project structure

```text
OpenAlarm/
  ContentView.swift
  L10n.swift
  OpenAlarmApp.swift
  Resources/
    en.lproj/Localizable.strings
    de.lproj/Localizable.strings
scripts/
  check_no_literals.sh
  check_i18n.sh
```

## i18n guardrails

- **No direct UI literals**: use `L10n.*` keys in SwiftUI instead of hardcoded strings.
- `scripts/check_no_literals.sh` fails if someone adds things like `Text("Hello")`.
- `scripts/check_i18n.sh` fails if `en/de/...` key sets drift.
- GitHub Action runs both checks on push/PR.

Run locally:

```bash
make check
```

Optional local hard-stop before every commit:

```bash
git config core.hooksPath .githooks
```

## Generate Xcode project

This repo uses `xcodegen`.

```bash
xcodegen generate
# or
make generate
```

Then open `OpenAlarm.xcodeproj` in Xcode.

## Add a new language

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
4. attach the build to your internal beta group.

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

Optional overrides:

- `ASC_KEY_PATH` (default: `~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8`)
- `BUNDLE_ID` (default: `com.gretzke.openalarm`)
- `SCHEME` (default: `OpenAlarm`)
- `PROJECT` (default: `OpenAlarm.xcodeproj`)
- `ARCHIVE_PATH` (default: `build/OpenAlarm.xcarchive`)
- `POLL_SECONDS` (default: `20`)
- `POLL_TIMEOUT_SECONDS` (default: `1800`)
