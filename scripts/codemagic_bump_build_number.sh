#!/usr/bin/env bash
# Resolve the next iOS/Android build number for Codemagic and export
# NEW_BUILD_NUMBER for `flutter build ... --build-number=$NEW_BUILD_NUMBER`.
#
# Do NOT export FLUTTER_BUILD_NUMBER: Flutter reserves that name for Generated
# Xcode settings and exits with:
#   FLUTTER_BUILD_NUMBER is used by the framework and cannot be set in the environment.
#
# Prefer App Store Connect / TestFlight latest + 1 when APP_APPLE_ID and API
# credentials are available; otherwise use max(PROJECT_BUILD_NUMBER/BUILD_NUMBER,
# pubspec) + 1 so Codemagic never re-publishes the committed +N.
#
# Also rewrites pubspec.yaml's +build in the CI workspace so the IPA still
# picks up the new CFBundleVersion even if Flutter build args omit
# --build-number=$NEW_BUILD_NUMBER.
#
# Codemagic Flutter workflow editor (iOS+Deploy):
#   1. Environment variables → add APP_APPLE_ID (App Store Connect → App
#      Information → Apple ID). ASC API key vars are usually already set for
#      publishing. Do not define FLUTTER_BUILD_NUMBER as a workflow env var.
#   2. Build → Pre-build script:
#        chmod +x scripts/codemagic_bump_build_number.sh
#        ./scripts/codemagic_bump_build_number.sh
#   3. Flutter build arguments (recommended):
#        --build-number=$NEW_BUILD_NUMBER --dart-define=BUILD_TIME=$BUILD_TIME
#
# Optional env:
#   APP_APPLE_ID — App Store Connect numeric Apple ID for this app
#   BUILD_NUMBER_OFFSET — added to PROJECT_BUILD_NUMBER/BUILD_NUMBER (default 0)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

max_int() {
  local a="${1:-0}" b="${2:-0}"
  if (( a > b )); then echo "$a"; else echo "$b"; fi
}

pubspec_line="$(grep -E '^version:' pubspec.yaml | head -1 || true)"
pubspec_name="$(
  sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+.*/\1/p' <<<"$pubspec_line" | head -1
)"
pubspec_build="$(
  sed -nE 's/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+).*/\1/p' <<<"$pubspec_line" | head -1
)"
if [[ -z "$pubspec_name" ]]; then
  pubspec_name="0.0.0"
fi
if ! is_int "$pubspec_build"; then
  pubspec_build=0
fi

latest_from_asc=0
if [[ -n "${APP_APPLE_ID:-}" ]] && command -v app-store-connect >/dev/null 2>&1; then
  echo "Querying App Store Connect for latest build numbers (APP_APPLE_ID=$APP_APPLE_ID)..."
  # --all-versions: CFBundleVersion must rise across the whole app, not only
  # the current marketing version (hotfixes / older trains can carry higher N).
  tf_out="$(
    app-store-connect get-latest-testflight-build-number "$APP_APPLE_ID" \
      --platform IOS --all-versions 2>&1 || true
  )"
  as_out="$(
    app-store-connect get-latest-app-store-build-number "$APP_APPLE_ID" \
      --platform IOS --all-versions 2>&1 || true
  )"
  tf="$(tail -n 1 <<<"$tf_out" | tr -d '[:space:]')"
  as="$(tail -n 1 <<<"$as_out" | tr -d '[:space:]')"
  if is_int "$tf"; then
    latest_from_asc="$(max_int "$latest_from_asc" "$tf")"
  else
    echo "ASC TestFlight lookup did not return an int (raw: ${tf_out//$'\n'/ | })"
  fi
  if is_int "$as"; then
    latest_from_asc="$(max_int "$latest_from_asc" "$as")"
  else
    echo "ASC App Store lookup did not return an int (raw: ${as_out//$'\n'/ | })"
  fi
  echo "ASC/TestFlight latest build number: $latest_from_asc"
else
  echo "Skipping ASC lookup (set APP_APPLE_ID for store-safe auto-increment)."
fi

offset="${BUILD_NUMBER_OFFSET:-0}"
cm_fallback="${PROJECT_BUILD_NUMBER:-${BUILD_NUMBER:-0}}"
if ! is_int "$cm_fallback"; then
  cm_fallback=0
fi
if ! is_int "$offset"; then
  offset=0
fi
cm_next=$((cm_fallback + offset))

# Always strictly greater than every known floor:
#   - ASC/TestFlight/App Store latest (when known)
#   - committed pubspec +N (so missing APP_APPLE_ID still advances)
#   - Codemagic PROJECT_BUILD_NUMBER / BUILD_NUMBER (+ optional offset)
asc_next=$((latest_from_asc + 1))
pubspec_next=$((pubspec_build + 1))
next="$(max_int "$asc_next" "$pubspec_next")"
next="$(max_int "$next" "$cm_next")"
if (( next <= 0 )); then
  next=1
fi
if (( latest_from_asc > 0 && next <= latest_from_asc )); then
  next=$((latest_from_asc + 1))
fi

echo "Using build number: $next (pubspec=$pubspec_name+$pubspec_build → +$next; cm=$cm_next asc_latest=$latest_from_asc)"

# Patch pubspec in the CI workspace so Flutter's default version source matches.
# Use a temp file (not sed -i): Codemagic iOS builders are macOS (BSD sed).
if grep -qE '^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+' pubspec.yaml; then
  tmp="$(mktemp)"
  sed -E "s/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+/version: ${pubspec_name}+${next}/" pubspec.yaml >"$tmp"
  mv "$tmp" pubspec.yaml
  echo "Updated pubspec.yaml version to ${pubspec_name}+${next}"
else
  echo "WARNING: could not rewrite pubspec.yaml version line; rely on --build-number=\$NEW_BUILD_NUMBER" >&2
fi

BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -n "${CM_ENV:-}" ]]; then
  echo "NEW_BUILD_NUMBER=$next" >>"$CM_ENV"
  echo "BUILD_TIME=$BUILD_TIME" >>"$CM_ENV"
  echo "Wrote NEW_BUILD_NUMBER=$next and BUILD_TIME=$BUILD_TIME to \$CM_ENV"
fi

export NEW_BUILD_NUMBER="$next"
export BUILD_TIME
# Reserved by Flutter; never export them (even empty). Unset for this process only.
unset FLUTTER_BUILD_NUMBER FLUTTER_BUILD_NAME || true

# Do not run agvtool here: it rewrites Info.plist / pbxproj away from
# $(FLUTTER_BUILD_NUMBER), which Flutter relies on during `flutter build ipa`.
