#!/usr/bin/env bash
set -euo pipefail

FLOW_FILE="${1:-maestro/open-create-sheet.yaml}"
OUT_DIR="${2:-tmp/maestro}"
DEVICE_ID="${3:-}"

export PATH="$HOME/.maestro/bin:/opt/homebrew/opt/openjdk/bin:$PATH"

mkdir -p "$OUT_DIR"

ARGS=(test "$FLOW_FILE" --test-output-dir "$OUT_DIR")
if [[ -n "$DEVICE_ID" ]]; then
  ARGS+=(--udid "$DEVICE_ID")
fi

maestro "${ARGS[@]}"

echo "✅ Maestro run complete. Artifacts in: $OUT_DIR"
