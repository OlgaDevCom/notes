#!/usr/bin/env bash
# Builds a signed App Store IPA on a GitHub macOS runner.
#
#   bash scripts/archive.sh <version> <build>      → writes build/App.ipa
#
# Reads three repository secrets, passed in as env by ios-release.yml:
#   IOS_DIST_CERT_P12_BASE64         Apple Distribution certificate with its private key (.p12), base64
#   IOS_DIST_CERT_PASSWORD           the password the .p12 was exported with
#   IOS_PROVISIONING_PROFILE_BASE64  App Store provisioning profile (.mobileprovision), base64
#
# The team and bundle id come from the profile. The Xcode project keeps its own
# signing settings: only this checkout is switched to manual signing, and the
# file is restored when the script exits.
set -euo pipefail

VERSION="${1:?usage: archive.sh <version> <build>}"
BUILD="${2:?usage: archive.sh <version> <build>}"
for name in IOS_DIST_CERT_P12_BASE64 IOS_DIST_CERT_PASSWORD IOS_PROVISIONING_PROFILE_BASE64; do
  if [ -z "${!name:-}" ]; then
    echo "::error::Repository secret $name is not set."
    exit 1
  fi
done

cd "$(dirname "$0")/.."
if [ -f scripts/bootstrap.sh ]; then
  # AppGen starters need the configured native/Firebase preparation. Existing
  # Flutter repositories keep the historical archive path and prepare deps.
  bash scripts/bootstrap.sh
else
  flutter pub get
fi
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ios-signing.XXXXXX")"
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
XCCONFIG="ios/Flutter/Release.xcconfig"
cp "$XCCONFIG" "$WORK/Release.xcconfig"

cleanup() {
  cp "$WORK/Release.xcconfig" "$XCCONFIG" || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "::group::Provisioning profile"
printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$WORK/profile.mobileprovision"
security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$WORK/profile.plist"; }
PROFILE_UUID="$(plist UUID)"
TEAM_ID="$(plist TeamIdentifier:0)"
APP_ID="$(plist Entitlements:application-identifier)"
BUNDLE_ID="${APP_ID#"$TEAM_ID".}"
if [ "$BUNDLE_ID" = "*" ] || plist ProvisionedDevices >/dev/null 2>&1; then
  echo "::error::'$(plist Name)' is not an App Store profile for one app. Create one under Profiles → Distribution → App Store Connect."
  exit 1
fi
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "$dir"
  cp "$WORK/profile.mobileprovision" "$dir/$PROFILE_UUID.mobileprovision"
done
echo "$(plist Name): $BUNDLE_ID, team $TEAM_ID, expires $(plist ExpirationDate)"
echo "::endgroup::"

echo "::group::Distribution certificate"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$WORK/dist.p12"
security import "$WORK/dist.p12" -k "$KEYCHAIN" -P "$IOS_DIST_CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | grep -m1 -oE '"(Apple|iPhone) Distribution: [^"]+\('"$TEAM_ID"'\)"' | tr -d '"' || true)"
if [ -z "$IDENTITY" ]; then
  echo "::error::The .p12 holds no Distribution certificate with a private key for team $TEAM_ID."
  security find-identity -v -p codesigning "$KEYCHAIN"
  exit 1
fi
echo "$IDENTITY"
echo "::endgroup::"

cat >> "$XCCONFIG" <<EOF

// scripts/archive.sh: manual signing for this CI checkout only.
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = $TEAM_ID
CODE_SIGN_IDENTITY = $IDENTITY
PROVISIONING_PROFILE_SPECIFIER = $PROFILE_UUID
EOF

cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key><string>$PROFILE_UUID</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

echo "::group::flutter build ipa $VERSION ($BUILD)"
flutter --version
# A committed Podfile.lock means plugins are built with CocoaPods locally. Runners
# default to Swift Package Manager, which resolves them elsewhere and breaks build
# phases that expect ios/Pods (e.g. the Crashlytics symbol upload).
if [ -f ios/Podfile.lock ]; then
  flutter config --no-enable-swift-package-manager
fi
flutter pub get
# A FlutterFire build phase (Crashlytics symbol upload) calls the flutterfire CLI,
# which runners don't have. The phase already puts ~/.pub-cache/bin on its PATH.
if grep -q 'flutterfire ' ios/Runner.xcodeproj/project.pbxproj && ! command -v flutterfire >/dev/null; then
  dart pub global activate flutterfire_cli
fi
flutter build ipa --release \
  --build-name="$VERSION" \
  --build-number="$BUILD" \
  --export-options-plist="$WORK/ExportOptions.plist"
echo "::endgroup::"

shopt -s nullglob
ipas=(build/ios/ipa/*.ipa)
if [ "${#ipas[@]}" -ne 1 ]; then
  echo "::error::Expected one IPA in build/ios/ipa, found ${#ipas[@]}."
  exit 1
fi
cp "${ipas[0]}" build/App.ipa
echo "Wrote build/App.ipa ($(du -h build/App.ipa | cut -f1))"
