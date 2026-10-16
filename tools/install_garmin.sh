#!/usr/bin/env bash
# Builds the Connect IQ app and copies it to a USB-connected watch over MTP.
# Requires: Connect IQ SDK + device profile (SDK Manager), a local developer
# key outside the repo, and libmtp (brew install libmtp).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device="${1:-fenix7xpro}"
key="${NSCONTROL_GARMIN_KEY:-$HOME/.nscontrol/developer_key.der}"
sdk="${CIQ_SDK:-$(cat "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg" 2>/dev/null || true)}"
[[ -x "$sdk/bin/monkeyc" ]] || { echo "Connect IQ SDK not found; set CIQ_SDK" >&2; exit 2; }
if [[ ! -f "$key" ]]; then
  echo "Creating local developer key at $key (never commit it)"
  mkdir -p "$(dirname "$key")"
  openssl genrsa -out "${key%.der}.pem" 4096 2>/dev/null
  openssl pkcs8 -topk8 -inform PEM -outform DER -in "${key%.der}.pem" -out "$key" -nocrypt
  chmod 600 "$key" "${key%.der}.pem"
fi
if [[ -z "${JAVA_HOME:-}" && -d "$root/.tooling/zulu/Contents/Home" ]]; then
  export JAVA_HOME="$root/.tooling/zulu/Contents/Home"; export PATH="$JAVA_HOME/bin:$PATH"
fi
mkdir -p "$root/build/garmin"
prg="$root/build/garmin/NSControl-$device.prg"
"$sdk/bin/monkeyc" -f "$root/garmin/monkey.jungle" -d "$device" -y "$key" -o "$prg" 2>&1 | grep -v 'container' || true
[[ -f "$prg" ]] || { echo "Build failed" >&2; exit 1; }
[[ "${2:-}" == "--build-only" ]] && { echo "$prg"; exit 0; }
brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
pusher="$root/build/garmin/mtp_push"
cc -O2 -I"$brew_prefix/include" -L"$brew_prefix/lib" -lmtp -o "$pusher" "$root/tools/garmin/mtp_push.c"
LANG=en_US.UTF-8 "$pusher" "$prg" NSCTRL.PRG 2>&1 | grep -v -E 'association|UNKNOWN in libmtp|report this VID'
