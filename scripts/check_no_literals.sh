#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/OpenAlarm"

# Guardrail: no user-facing string literals directly in common SwiftUI initializers/modifiers.
# Use L10n.* keys instead.
PATTERNS=(
  '\bText\s*\(\s*"'
  '\bButton\s*\(\s*"'
  '\bLabel\s*\(\s*"'
  '\bToggle\s*\(\s*"'
  '\bTextField\s*\(\s*"'
  '\bSecureField\s*\(\s*"'
  '\.navigationTitle\s*\(\s*"'
)

found=0

while IFS= read -r -d '' file; do
  for regex in "${PATTERNS[@]}"; do
    if grep -nE "$regex" "$file" >/dev/null; then
      if [[ $found -eq 0 ]]; then
        echo "❌ Found direct UI string literals. Use L10n keys instead:"
      fi
      grep -nE "$regex" "$file"
      found=1
    fi
  done
done < <(find "$SRC_DIR" -type f -name '*.swift' -print0)

if [[ $found -eq 1 ]]; then
  exit 1
fi

echo "✅ no direct UI string literals found"
