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
  OpenAlarmApp.swift
  Resources/
    en.lproj/Localizable.strings
    de.lproj/Localizable.strings
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
4. Re-run:

```bash
xcodegen generate
```
