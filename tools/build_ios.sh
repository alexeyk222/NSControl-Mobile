#!/usr/bin/env bash
# Builds a signed release NSControl for a USB-connected iPhone and installs it
# with libimobiledevice. Works with an Xcode older than the phone's iOS: app
# installation does not need the Developer Disk Image, only debugging does.
#
#   bash tools/build_ios.sh               # build + install
#   bash tools/build_ios.sh --build-only  # build only
#
# Env: NSCONTROL_XCODE (path to Xcode.app), NSCONTROL_TEAM (Apple team ID;
# auto-detected from the keychain when omitted), NSCONTROL_NO_HEALTHKIT=1
# (sign without the HealthKit entitlement, e.g. if the team cannot use it).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
install=true
[[ "${1:-}" == "--build-only" ]] && install=false

xcode="${NSCONTROL_XCODE:-}"
if [[ -z "$xcode" ]]; then
  xcode="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -d "$xcode/Contents/Developer" ]] || { echo "Xcode not found; set NSCONTROL_XCODE" >&2; exit 2; }
# DEVELOPER_DIR avoids a system-wide `sudo xcode-select`.
export DEVELOPER_DIR="$xcode/Contents/Developer"
export LANG=en_US.UTF-8
export PUB_CACHE="${PUB_CACHE:-$root/.tooling/pub-cache}"
flutter="${NSCONTROL_FLUTTER:-$root/.tooling/flutter/bin/flutter}"
xcodebuild -version

team="${NSCONTROL_TEAM:-}"
if [[ -z "$team" ]]; then
  # "Apple Development: Name (XXXXXXXXXX)" — the certificate's OU is the team.
  cert="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | \
    awk '/BEGIN/{c=""} {c=c $0 "\n"} /END/{print c; exit}')"
  if [[ -n "$cert" ]]; then
    team="$(printf '%s' "$cert" | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
  fi
fi
if [[ -z "$team" ]]; then
  echo "No Apple Development certificate. Open Xcode → Settings → Accounts, add your Apple ID," >&2
  echo "then Manage Certificates → + → Apple Development. Or set NSCONTROL_TEAM." >&2
  exit 3
fi
echo "Signing team: $team"

"$flutter" pub get --enforce-lockfile
"$flutter" build ios --release --no-codesign
entitlements="Runner/Runner.entitlements"
if [[ "${NSCONTROL_NO_HEALTHKIT:-}" == 1 ]]; then
  entitlements="Runner/RunnerNoHealth.entitlements"
fi
# Re-run the archive step with automatic signing; Flutter's own build only
# validates the project when signing is disabled.
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios/derived \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CODE_SIGN_ENTITLEMENTS="$entitlements" \
  build | grep -E "error:|warning: .*(sign|provision)|BUILD (SUCCEEDED|FAILED)|Signing Identity|Provisioning Profile" || true
app="build/ios/derived/Build/Products/Release-iphoneos/Runner.app"
[[ -d "$app" ]] || { echo "Signed build failed" >&2; exit 1; }
codesign -dv "$app" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Apple Development" || true
echo "App: $app"
$install || exit 0

command -v ideviceinstaller >/dev/null || { echo "brew install ideviceinstaller" >&2; exit 2; }
udid="$(idevice_id -l | head -1)"
[[ -n "$udid" ]] || { echo "iPhone not found by USB. Unlock it and tap Trust." >&2; exit 4; }
echo "Device: $(ideviceinfo -u "$udid" -k ProductType) iOS $(ideviceinfo -u "$udid" -k ProductVersion)"
ideviceinstaller -u "$udid" install "$app"
cat <<'EOF'
Installed. On first launch iOS may require:
  • Settings → Privacy & Security → Developer Mode → On (reboot), and
  • Settings → General → VPN & Device Management → trust the developer.
EOF
