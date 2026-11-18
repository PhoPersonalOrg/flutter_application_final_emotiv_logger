#!/usr/bin/env bash
# Build and launch in --release so iOS can be opened from the home screen
# without a debugger. Dropbox keys come from a local .env (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Missing .env — copy .env.example to .env and set DROPBOX_APP_KEY:" >&2
  echo "  cp .env.example .env" >&2
  exit 1
fi

exec fvm flutter run --release --dart-define-from-file=.env "$@"
