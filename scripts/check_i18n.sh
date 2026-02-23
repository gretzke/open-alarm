#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$ROOT_DIR/OpenAlarm/Resources"
BASE_FILE="$RES_DIR/en.lproj/Localizable.strings"

if [[ ! -f "$BASE_FILE" ]]; then
  echo "❌ Missing base localization file: $BASE_FILE"
  exit 1
fi

python3 - "$RES_DIR" <<'PY'
import sys
import re
from pathlib import Path

res_dir = Path(sys.argv[1])

pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def parse(path: Path):
    keys = {}
    for i, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("//") or line.startswith("/*"):
            continue
        m = pattern.match(line)
        if not m:
            print(f"❌ Invalid .strings syntax: {path}:{i}: {raw}")
            sys.exit(1)
        key, value = m.group(1), m.group(2)
        keys[key] = value
    return keys

base_path = res_dir / "en.lproj" / "Localizable.strings"
base = parse(base_path)

if not base:
    print("❌ Base localization has no keys.")
    sys.exit(1)

status_ok = True

langs = sorted(p for p in res_dir.glob("*.lproj") if p.is_dir())
for lang_dir in langs:
    current = lang_dir / "Localizable.strings"
    if not current.exists():
        print(f"❌ Missing file: {current}")
        status_ok = False
        continue

    parsed = parse(current)
    missing = sorted(set(base.keys()) - set(parsed.keys()))
    extra = sorted(set(parsed.keys()) - set(base.keys()))

    if missing:
        print(f"❌ {current} missing keys: {', '.join(missing)}")
        status_ok = False
    if extra:
        print(f"❌ {current} extra keys (not in en): {', '.join(extra)}")
        status_ok = False

if not status_ok:
    sys.exit(1)

print("✅ i18n key parity check passed")
PY
