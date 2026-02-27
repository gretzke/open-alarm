#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
targets = [
    root / "OpenAlarm/OnboardingFlowView.swift",
    root / "OpenAlarm/SharedAlarmSettingsEditor.swift",
    root / "OpenAlarm/AlarmEditorView.swift",
    root / "OpenAlarm/MainTabView.swift",
]

patterns = [
    re.compile(
        r"Button\b[\s\S]{0,600}?\.oaGlass(?:Prominent)?ButtonChrome\([^)]*\)[\s\S]{0,300}?\.buttonStyle\(\.plain\)",
        re.MULTILINE,
    ),
    re.compile(
        r"Button\b[\s\S]{0,600}?\.buttonStyle\(\.plain\)[\s\S]{0,300}?\.oaGlass(?:Prominent)?ButtonChrome\([^)]*\)",
        re.MULTILINE,
    ),
]

violations = []
for path in targets:
    text = path.read_text(encoding="utf-8")
    for pattern in patterns:
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            violations.append((path.relative_to(root), line))

if violations:
    print("❌ Legacy ad-hoc glass button pattern detected. Use native GlassProminentButtonStyle/GlassButtonStyle.")
    for rel, line in violations:
        print(f" - {rel}:{line}")
    raise SystemExit(1)

print("✅ No legacy ad-hoc glass button pattern found in migrated screens.")
PY
