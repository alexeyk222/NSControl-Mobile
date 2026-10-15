#!/usr/bin/env bash
# Reproducible source checks; physical acceptance remains a separate procedure.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
android_build=false
ios_build=false
for argument in "$@"; do
  case "$argument" in
    --android) android_build=true ;;
    --ios) ios_build=true ;;
    --help|-h)
      printf '%s\n' 'Usage: tools/verify.sh [--android] [--ios]' \
        'Default: locked dependencies, formatting, analysis, Flutter tests and Python tooling tests.' \
        '--android: also build release APK; --ios: build unsigned release iOS app (macOS/Xcode required).'
      exit 0 ;;
    *) printf 'Unknown option: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
if [[ -n "${NSCONTROL_FLUTTER:-}" ]]; then
  flutter_bin="$NSCONTROL_FLUTTER"
elif [[ -x "$project_root/.tooling/flutter/bin/flutter" ]]; then
  flutter_bin="$project_root/.tooling/flutter/bin/flutter"
else
  flutter_bin="$(command -v flutter || true)"
fi
if [[ -z "$flutter_bin" || ! -x "$flutter_bin" ]]; then
  printf '%s\n' 'Flutter unavailable. Install the version in README or set NSCONTROL_FLUTTER to its executable.' >&2
  exit 2
fi
dart_bin="$(dirname "$flutter_bin")/dart"
if [[ ! -x "$dart_bin" ]]; then
  printf '%s\n' 'Dart executable missing beside the selected Flutter executable.' >&2
  exit 2
fi
export PUB_CACHE="${PUB_CACHE:-$project_root/.tooling/pub-cache}"
export FLUTTER_SUPPRESS_ANALYTICS=true
"$flutter_bin" --version
"$flutter_bin" pub get --enforce-lockfile
"$dart_bin" format --output=none --set-exit-if-changed lib test
"$flutter_bin" analyze --no-pub
"$flutter_bin" test --no-pub --reporter expanded
python3 -m unittest discover -s test_tools -v
if [[ "$android_build" == true ]]; then
  "$flutter_bin" build apk --release --no-pub
fi
if [[ "$ios_build" == true ]]; then
  if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'iOS release build requires macOS and Xcode.' >&2
    exit 2
  fi
  "$flutter_bin" build ios --release --no-codesign --no-pub
fi
printf '%s\n' 'Requested source checks completed. Device installation and physical acceptance are not implied.'
