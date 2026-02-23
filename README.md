# Open Alarm (iOS skeleton)

Minimal iOS app skeleton for the Open Alarm project.

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
