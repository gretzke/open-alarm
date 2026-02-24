# Maestro setup (OpenAlarm)

This project now has Maestro flows for fast screenshot capture.

## Prerequisites (local)

- Maestro CLI installed (`~/.maestro/bin/maestro`)
- Java installed (`/opt/homebrew/opt/openjdk/bin/java`)

## Flows

- `maestro/open-create-sheet.yaml` — opens the New Alarm sheet (partial detent)
- `maestro/open-snooze-sheet.yaml` — opens the snooze half-sheet
- `maestro/onboarding-default-config.yaml` — opens onboarding default-config step

Both flows use debug launch arguments:

- `uitestSkipOnboarding`
- `uitestOpenCreateAlarm`
- `uitestOpenSnoozeDuration`

(These flags are `#if DEBUG` only.)

## Run

```bash
./scripts/maestro-shot.sh maestro/open-create-sheet.yaml
./scripts/maestro-shot.sh maestro/open-snooze-sheet.yaml
./scripts/maestro-shot.sh maestro/onboarding-default-config.yaml
```

Screenshots are written to `tmp/maestro/`.

## MCP (Maestro)

Maestro includes an MCP server:

```bash
maestro mcp
```

Example MCP config entry:

```json
{
  "mcpServers": {
    "maestro": {
      "command": "maestro",
      "args": ["mcp"]
    }
  }
}
```
