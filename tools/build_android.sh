#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
export PUB_CACHE="${PUB_CACHE:-$project_root/.tooling/pub-cache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$project_root/.tooling/gradle}"
export FLUTTER_SUPPRESS_ANALYTICS=true
if [[ -x "$project_root/.tooling/zulu/Contents/Home/bin/java" ]]; then
  export JAVA_HOME="$project_root/.tooling/zulu/Contents/Home"
fi
if [[ -d "$project_root/.tooling/android-sdk/platforms" ]]; then
  export ANDROID_HOME="$project_root/.tooling/android-sdk"
fi
if [[ -x "$project_root/.tooling/flutter/bin/flutter" ]]; then
  flutter_bin="$project_root/.tooling/flutter/bin/flutter"
else
  flutter_bin="$(command -v flutter)"
fi
"$flutter_bin" pub get --enforce-lockfile
"$flutter_bin" build apk --release --no-pub "$@"
