#!/usr/bin/env bash
# Compatibility entry point for a temporary test. Activation is now explicit.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/linux-le-setup.py" "$@" --temporary
