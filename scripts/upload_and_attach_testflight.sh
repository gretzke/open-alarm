#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

log() {
  printf '➡️  %s\n' "$*"
}

ok() {
  printf '✅ %s\n' "$*"
}

warn() {
  printf '⚠️  %s\n' "$*" >&2
}

die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

mask_value() {
  local value="${1:-}"
  local len=${#value}

  if (( len == 0 )); then
    printf '<empty>'
    return
  fi

  if (( len <= 4 )); then
    printf '****'
    return
  fi

  printf '%s***%s' "${value:0:2}" "${value: -2}"
}

require_var() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    die "Missing required environment variable: ${var_name}"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

expand_path() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf '%s' "$HOME"
    return
  fi
  if [[ "$path" == "~/"* ]]; then
    printf '%s/%s' "$HOME" "${path#~/}"
    return
  fi
  printf '%s' "$path"
}

to_abs_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s' "$path"
  else
    printf '%s/%s' "$ROOT_DIR" "$path"
  fi
}

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
APP_ID="${APP_ID:-}"
BETA_GROUP_ID="${BETA_GROUP_ID:-}"
TEAM_ID="${TEAM_ID:-}"

require_var ASC_KEY_ID
require_var ASC_ISSUER_ID
require_var APP_ID
require_var BETA_GROUP_ID
require_var TEAM_ID

BUNDLE_ID="${BUNDLE_ID:-com.gretzke.openalarm}"
SCHEME="${SCHEME:-OpenAlarm}"
PROJECT="${PROJECT:-OpenAlarm.xcodeproj}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/OpenAlarm.xcarchive}"
POLL_SECONDS="${POLL_SECONDS:-20}"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-1800}"

ASC_KEY_PATH_DEFAULT="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ASC_KEY_PATH="${ASC_KEY_PATH:-$ASC_KEY_PATH_DEFAULT}"
ASC_KEY_PATH="$(expand_path "$ASC_KEY_PATH")"

export ASC_KEY_ID
export ASC_ISSUER_ID
export ASC_KEY_PATH

[[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || die "POLL_SECONDS must be a positive integer"
[[ "$POLL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "POLL_TIMEOUT_SECONDS must be a positive integer"
(( POLL_SECONDS > 0 )) || die "POLL_SECONDS must be > 0"
(( POLL_TIMEOUT_SECONDS > 0 )) || die "POLL_TIMEOUT_SECONDS must be > 0"

require_cmd git
require_cmd python3
require_cmd openssl
require_cmd xcodebuild

[[ -d "$PROJECT" ]] || die "Xcode project not found at: $PROJECT"
PBXPROJ_PATH="$PROJECT/project.pbxproj"
[[ -f "$PBXPROJ_PATH" ]] || die "project.pbxproj not found at: $PBXPROJ_PATH"
[[ -r "$ASC_KEY_PATH" ]] || die "ASC key file is not readable: $ASC_KEY_PATH"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "Must run inside a git repository"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  die "Working tree is not clean. Commit or stash changes first."
fi

ABS_ARCHIVE_PATH="$(to_abs_path "$ARCHIVE_PATH")"
UPLOAD_OPTIONS_PATH="$ROOT_DIR/build/UploadOptions.plist"

log "Deterministic TestFlight upload+attach starting"
log "Scheme=$SCHEME TeamID=$(mask_value "$TEAM_ID") Bundle=$BUNDLE_ID AppID=$(mask_value "$APP_ID") GroupID=$(mask_value "$BETA_GROUP_ID")"

LATEST_ASC_BUILD="$(python3 - <<'PY'
import json
import os
import subprocess
import urllib.parse
import urllib.request

proc = subprocess.run([
    'xcrun', 'altool', '--generate-jwt',
    '--apiKey', os.environ['ASC_KEY_ID'],
    '--apiIssuer', os.environ['ASC_ISSUER_ID'],
    '--p8-file-path', os.environ['ASC_KEY_PATH'],
], capture_output=True, text=True)
out = (proc.stdout or '') + '\n' + (proc.stderr or '')
tok = next((l.strip() for l in out.splitlines() if l.strip().count('.') == 2 and ' ' not in l.strip()), None)
if not tok:
    print('0')
    raise SystemExit(0)
params = urllib.parse.urlencode({
    'filter[app]': os.environ['APP_ID'],
    'sort': '-uploadedDate',
    'limit': '1',
})
req = urllib.request.Request(
    f'https://api.appstoreconnect.apple.com/v1/builds?{params}',
    headers={'Authorization': f'Bearer {tok}', 'Accept': 'application/json'},
)
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.loads(r.read().decode())
    builds = data.get('data', [])
    print((builds[0].get('attributes', {}) or {}).get('version', '0') if builds else '0')
except Exception:
    print('0')
PY
)"
log "Latest ASC build detected: ${LATEST_ASC_BUILD}"

VERSION_INFO="$(python3 - "$PBXPROJ_PATH" "$LATEST_ASC_BUILD" <<'PY'
import re
import sys
from pathlib import Path

pbxproj_path = Path(sys.argv[1])
asc_build = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0
text = pbxproj_path.read_text(encoding="utf-8")

build_matches = re.findall(r"CURRENT_PROJECT_VERSION = ([0-9]+);", text)
if not build_matches:
    print("Missing CURRENT_PROJECT_VERSION in project.pbxproj", file=sys.stderr)
    raise SystemExit(1)

unique_builds = sorted(set(build_matches))
if len(unique_builds) != 1:
    print(
        f"Inconsistent CURRENT_PROJECT_VERSION values found: {', '.join(unique_builds)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

current_build = int(unique_builds[0])
base_build = max(current_build, asc_build)
next_build = base_build + 1
text = re.sub(
    r"CURRENT_PROJECT_VERSION = [0-9]+;",
    f"CURRENT_PROJECT_VERSION = {next_build};",
    text,
)

marketing_match = re.search(r"MARKETING_VERSION = ([^;]+);", text)
if not marketing_match:
    print("Missing MARKETING_VERSION in project.pbxproj", file=sys.stderr)
    raise SystemExit(1)

marketing_version = marketing_match.group(1).strip().strip('"')
pbxproj_path.write_text(text, encoding="utf-8")
print(f"{current_build}|{next_build}|{marketing_version}")
PY
)"

IFS='|' read -r CURRENT_BUILD NEXT_BUILD MARKETING_VERSION <<<"$VERSION_INFO"

log "Build number bump: ${CURRENT_BUILD} -> ${NEXT_BUILD}"
git add "$PBXPROJ_PATH"
git commit -m "chore: bump testflight build number to ${NEXT_BUILD}" >/dev/null
ok "Committed build number bump"

mkdir -p "$ROOT_DIR/build"
rm -rf "$ABS_ARCHIVE_PATH"

log "Archiving Release build (version=${MARKETING_VERSION}, build=${NEXT_BUILD})"
xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ABS_ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  clean archive
ok "Archive created at ${ABS_ARCHIVE_PATH}"

cat > "$UPLOAD_OPTIONS_PATH" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>upload</string>
	<key>method</key>
	<string>app-store-connect</string>
	<key>testFlightInternalTestingOnly</key>
	<true/>
</dict>
</plist>
PLIST

log "Uploading archive to App Store Connect"
xcodebuild -quiet \
  -exportArchive \
  -archivePath "$ABS_ARCHIVE_PATH" \
  -exportPath "$ROOT_DIR/build" \
  -exportOptionsPlist "$UPLOAD_OPTIONS_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
ok "Upload complete; polling App Store Connect"

python3 - "$APP_ID" "$BETA_GROUP_ID" "$MARKETING_VERSION" "$NEXT_BUILD" "$POLL_SECONDS" "$POLL_TIMEOUT_SECONDS" <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

app_id, beta_group_id, target_version, target_build, poll_seconds, timeout_seconds = sys.argv[1:]
poll_seconds = int(poll_seconds)
timeout_seconds = int(timeout_seconds)

asc_key_id = os.environ["ASC_KEY_ID"]
asc_issuer_id = os.environ["ASC_ISSUER_ID"]
asc_key_path = os.environ["ASC_KEY_PATH"]

sensitive_values = [v for v in [asc_key_id, asc_issuer_id, app_id, beta_group_id] if v]


def redact(text):
    output = text
    for value in sensitive_values:
        output = output.replace(value, "<redacted>")
    return output


def log(message):
    print(f"[asc] {redact(message)}", flush=True)


def fail(message, exit_code=1):
    print(f"❌ {redact(message)}", file=sys.stderr, flush=True)
    raise SystemExit(exit_code)


def make_jwt():
    # Prefer Apple's own token generation to avoid JOSE/DER signature edge cases.
    proc = subprocess.run(
        [
            "xcrun",
            "altool",
            "--generate-jwt",
            "--apiKey",
            asc_key_id,
            "--apiIssuer",
            asc_issuer_id,
            "--p8-file-path",
            asc_key_path,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    if proc.returncode != 0:
        fail(f"Failed to generate ASC JWT via altool: {output.strip()}")

    for line in output.splitlines():
        line = line.strip()
        if line.count(".") == 2 and " " not in line:
            return line

    fail("Failed to parse ASC JWT from altool output")


_token = ""
_token_exp = 0


def auth_token():
    global _token
    global _token_exp

    now = int(time.time())
    if _token and now < (_token_exp - 30):
        return _token

    _token = make_jwt()
    _token_exp = now + 1200
    return _token


def asc_request(method, path, payload=None):
    url = f"https://api.appstoreconnect.apple.com{path}"
    headers = {"Authorization": f"Bearer {auth_token()}", "Accept": "application/json"}
    body = None

    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            status = resp.status
    except urllib.error.HTTPError as err:
        status = err.code
        raw = err.read().decode("utf-8", errors="replace")
    except Exception as err:  # pragma: no cover - defensive
        fail(f"App Store Connect request failed for {method} {path}: {err}")

    if not raw.strip():
        return status, {}

    try:
        return status, json.loads(raw)
    except json.JSONDecodeError:
        return status, {"raw": raw}


def extract_errors(payload):
    errors = payload.get("errors") or []
    if not errors:
        return ""
    pieces = []
    for entry in errors:
        status = entry.get("status")
        code = entry.get("code")
        title = entry.get("title")
        detail = entry.get("detail")
        parts = [p for p in [status, code, title, detail] if p]
        if parts:
            pieces.append(" | ".join(parts))
    return " || ".join(pieces)


def find_build_id(deadline_epoch):
    log(f"Locating uploaded build for version={target_version} build={target_build}")

    def fetch_builds(include_version_filter):
        params = {
            "filter[app]": app_id,
            "sort": "-uploadedDate",
            "limit": "200",
            "include": "preReleaseVersion",
            "fields[builds]": "version,uploadedDate",
            "fields[preReleaseVersions]": "version",
        }
        if include_version_filter:
            params["filter[version]"] = target_build

        status, payload = asc_request("GET", f"/v1/builds?{urllib.parse.urlencode(params)}")
        if status >= 400:
            if include_version_filter and status == 400:
                log("filter[version] unsupported for /v1/builds; retrying without version filter")
                return None
            fail(
                f"Failed to list builds (HTTP {status}). {extract_errors(payload)}"
            )
        return payload

    while time.time() < deadline_epoch:
        payloads_to_check = []

        filtered_payload = fetch_builds(True)
        if filtered_payload is not None:
            payloads_to_check.append(filtered_payload)

        unfiltered_payload = fetch_builds(False)
        if unfiltered_payload is not None:
            payloads_to_check.append(unfiltered_payload)

        for current_payload in payloads_to_check:
            prerelease_map = {
                item.get("id"): str((item.get("attributes") or {}).get("version"))
                for item in current_payload.get("included", [])
                if item.get("type") == "preReleaseVersions"
            }

            for build in current_payload.get("data", []):
                attributes = build.get("attributes", {})
                build_number = attributes.get("buildNumber") or attributes.get("version")
                if str(build_number) != str(target_build):
                    continue

                relationships = build.get("relationships", {})
                prerelease_data = (
                    relationships.get("preReleaseVersion", {}).get("data", {})
                    if isinstance(relationships, dict)
                    else {}
                )
                prerelease_id = prerelease_data.get("id") if isinstance(prerelease_data, dict) else None
                marketing_version = prerelease_map.get(prerelease_id)
                if marketing_version and str(marketing_version) != str(target_version):
                    continue

                return build["id"]

        remaining = max(0, int(deadline_epoch - time.time()))
        log(
            f"Build not visible yet; retrying in {poll_seconds}s (timeout in {remaining}s)"
        )
        time.sleep(poll_seconds)

    fail("Timed out waiting for uploaded build to appear in App Store Connect")



def wait_until_ready(build_id, deadline_epoch):
    ready_states = {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}
    terminal_failure_states = {
        "FAILED",
        "INVALID",
        "PROCESSING_EXCEPTION",
        "EXPIRED",
    }

    last_state = None
    while time.time() < deadline_epoch:
        params = urllib.parse.urlencode({"filter[build]": build_id, "limit": "1"})
        status, payload = asc_request("GET", f"/v1/buildBetaDetails?{params}")
        if status >= 400:
            fail(
                f"Failed to check build beta detail (HTTP {status}). {extract_errors(payload)}"
            )

        rows = payload.get("data", [])
        state = "NOT_AVAILABLE"
        if rows:
            state = rows[0].get("attributes", {}).get("internalBuildState", "UNKNOWN")

        if state != last_state:
            log(f"internalBuildState={state}")
            last_state = state

        if state in ready_states:
            return state

        if state in terminal_failure_states:
            fail(f"Build reached terminal state: {state}")

        time.sleep(poll_seconds)

    fail("Timed out waiting for internalBuildState=READY_FOR_BETA_TESTING")


def attach_build(build_id):
    payload = {"data": [{"type": "builds", "id": build_id}]}
    status, response_payload = asc_request(
        "POST",
        f"/v1/betaGroups/{beta_group_id}/relationships/builds",
        payload,
    )

    if 200 <= status < 300:
        return "attached"

    details = extract_errors(response_payload)
    lowered = details.lower()
    if status in {409, 422} and (
        "already" in lowered or "exists" in lowered or "is associated" in lowered
    ):
        log("Build was already attached during attach request")
        return "already-attached"

    fail(f"Failed to attach build to beta group (HTTP {status}). {details}")


deadline = time.time() + timeout_seconds
build_id = find_build_id(deadline)
log(f"Found build id={build_id}")
state = wait_until_ready(build_id, deadline)
attach_result = attach_build(build_id)
print(
    f"✅ ASC ready state={state}; beta group relation={attach_result}; build id={build_id}",
    flush=True,
)
PY

ok "Deterministic TestFlight upload+attach succeeded for version ${MARKETING_VERSION} (build ${NEXT_BUILD})"
