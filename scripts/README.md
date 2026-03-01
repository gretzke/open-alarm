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

### Required env vars

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `APP_ID`
- `BETA_GROUP_ID`
- `TEAM_ID`

### Security note

Never hardcode secrets or private IDs in scripts. Keep sensitive values in environment variables only.
