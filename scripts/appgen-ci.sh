#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

phase="${1:-}"
if [[ -z "$phase" ]]; then
  echo "Usage: bash scripts/appgen-ci.sh <stable-check-id>" >&2
  exit 2
fi

if ! jq -e --arg phase "$phase" '.checks | index($phase) != null' .appgen/ci-profile.json >/dev/null; then
  echo "Check '$phase' is not enabled by .appgen/ci-profile.json."
  exit 0
fi

case "$phase" in
  bootstrap) bash scripts/bootstrap.sh ;;
  format) find . \( -path ./.dart_tool -o -path ./build -o -path './*/.symlinks' \) -prune -o -name '*.dart' ! -name '*.g.dart' ! -path './lib/l10n/app_localizations*.dart' -print0 | xargs -0 dart format --output=none --set-exit-if-changed ;;
  analyze) flutter analyze ;;
  test) flutter test ;;
  build_android_debug) flutter build apk --debug ;;
  build_android_release)
    set -euo pipefail
    keytool -genkeypair -noprompt -keystore android/app/verify-upload.jks -storetype JKS -storepass appgen-verify-store -keypass appgen-verify-key -alias appgen-verify -dname "CN=AppGen Release Verification" -keyalg RSA -keysize 2048 -validity 2
    printf 'storeFile=verify-upload.jks\nstorePasswordBase64=%s\nkeyAliasBase64=%s\nkeyPasswordBase64=%s\n' \
      "$(printf '%s' 'appgen-verify-store' | base64 -w 0)" \
      "$(printf '%s' 'appgen-verify' | base64 -w 0)" \
      "$(printf '%s' 'appgen-verify-key' | base64 -w 0)" \
      > android/key.properties
    flutter build appbundle --release
    bundle=$(find build/app/outputs/bundle/release -maxdepth 1 -name '*.aab' -print -quit)
    test -n "$bundle" && test -s "$bundle"
    jarsigner -verify "$bundle"
    ;;
  build_ios_simulator) flutter build ios --simulator --no-codesign ;;
  screen_gen_android|screen_gen_ios) echo "Screen Gen capture is run by its platform-specific workflow." ;;
  *) echo "Unknown AppGen check '$phase'." >&2; exit 2 ;;
esac
