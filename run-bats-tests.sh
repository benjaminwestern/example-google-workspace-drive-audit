#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  printf 'bats is not installed. Install bats-core first.\n' >&2
  exit 1
fi

exec bats "${SCRIPT_DIR}/tests"
