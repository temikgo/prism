#!/usr/bin/env bash
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/client-godot"
GODOT="${GODOT:-$PROJECT/.godot-bin/Godot_v4.3-stable_linux.x86_64}"
"$GODOT" --headless --import --path "$PROJECT"
exec "$GODOT" --path "$PROJECT" "$@"
