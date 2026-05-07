# scripts/

## TestFlight publish workflow

Use `upload_and_attach_testflight.sh` for deterministic TestFlight publishing and beta-group attach.

```bash
ASC_KEY_ID="<ASC_KEY_ID>" \
ASC_ISSUER_ID="<ASC_ISSUER_ID_UUID>" \
APP_ID="<ASC_APP_ID>" \
BETA_GROUP_ID="<ASC_INTERNAL_BETA_GROUP_ID>" \
TEAM_ID="<APPLE_DEVELOPER_TEAM_ID>" \
./scripts/upload_and_attach_testflight.sh
```

The script publishes to internal TestFlight by default. To publish to an external TestFlight group, use an external group ID and set `TESTFLIGHT_DISTRIBUTION=external`; the script uploads an external-eligible build, attaches it to the group, and submits it to Beta App Review. It intentionally does not call the optional beta build notification endpoint, so App Store Connect's default TestFlight notification behavior remains in control.

### Required env vars

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `APP_ID`
- `BETA_GROUP_ID`
- `TEAM_ID`

`upload_and_attach_testflight.sh` reads key path from `ASC_KEY_PATH` (optional; defaults to `~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8`).
If you already use `ASC_KEY_FILE` in local tooling, set `ASC_KEY_PATH="$ASC_KEY_FILE"` before running the script.

### Local env file convenience (recommended)

To avoid retyping credentials every run, keep them in a local untracked env file and source it before publishing.

```bash
# .env.testflight.local (create locally; do not commit)
ASC_KEY_ID="<ASC_KEY_ID>"
ASC_ISSUER_ID="<ASC_ISSUER_ID_UUID>"
APP_ID="<ASC_APP_ID>"
BETA_GROUP_ID="<ASC_INTERNAL_BETA_GROUP_ID>"
TEAM_ID="<APPLE_DEVELOPER_TEAM_ID>"
# Optional: set to external and use an external group ID to submit Beta App Review.
# TESTFLIGHT_DISTRIBUTION="external"
# Optional if your key file is not at the default location:
# ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

set -a
source ./.env.testflight.local
set +a
./scripts/upload_and_attach_testflight.sh
```

### Security note

Never hardcode secrets or private IDs in scripts. Keep sensitive values in environment variables only.
