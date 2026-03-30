#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_script in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$test_script" ] || continue
    echo "Running $(basename "$test_script")..."
    "$test_script"
done
