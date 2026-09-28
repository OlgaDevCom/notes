#!/usr/bin/env bash
# Captures store screenshots on one booted simulator or emulator, once per locale.
#
#   bash scripts/screen-gen-capture.sh <device> <flutter-device-id>
#
#   <device>             the Screen Gen device id: iphone-6.9, ipad-13, android-phone, android-tablet
#   <flutter-device-id>  what `flutter drive -d` takes: a simulator UDID or emulator-5554
#
# Reads LOCALES (the `locales` workflow input, comma-separated store codes) from
# the environment and writes screen-gen/<locale>/<device>/<NN>_<name>.png — the
# layout Appflow collects.
#
# Every attempt is also written to screen-gen-logs/<device>/<locale>.log, which
# the workflow uploads as its own artifact, and the tail of a failed attempt is
# printed outside the collapsed group: the reason is in this step's log, not
# only in the artifact.
#
# A locale that fails is retried once and then skipped, so the other locales
# still reach the artifact; the script exits 1 at the end if any locale failed.
# When the first locale produces nothing at all the run stops there — this is
# usually a setup problem, and the remaining locales would repeat it.
#
#   SCREEN_GEN_ATTEMPTS=2     attempts per locale
#   SCREEN_GEN_KEEP_GOING=1   try every locale even when the first produces nothing
set -uo pipefail

DEVICE="${1:?usage: screen-gen-capture.sh <device> <flutter-device-id>}"
TARGET="${2:?usage: screen-gen-capture.sh <device> <flutter-device-id>}"
: "${LOCALES:?LOCALES is not set; pass the locales input through env}"

DRIVER='test_driver/screen_gen.dart'
SUITE='integration_test/screen_gen_test.dart'
ATTEMPTS="${SCREEN_GEN_ATTEMPTS:-2}"
LOG_DIR="screen-gen-logs/$DEVICE"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

refuse() { echo "::error::$1"; exit 1; }
pngs_in() { find "$1" -type f -name '*.png' 2> /dev/null | wc -l | tr -d '[:space:]'; }
shots_said() { if (( $1 == 1 )); then echo '1 screenshot'; else echo "$1 screenshots"; fi; }

if [[ ! "$ATTEMPTS" =~ ^([1-9]|10)$ ]]; then
  refuse "SCREEN_GEN_ATTEMPTS must be an integer from 1 to 10 (got '$ATTEMPTS')."
fi

if [[ ! "$DEVICE" =~ ^[a-z0-9.-]{1,40}$ ]]; then
  refuse "Refusing device id '$DEVICE'."
fi

# Everything that has to be true before a twenty-minute build starts.
command -v flutter > /dev/null 2>&1 || refuse "flutter is not on PATH: the job needs subosito/flutter-action before this step."
[[ -f pubspec.yaml ]] || refuse "No pubspec.yaml in $(pwd): run this script from the root of the Flutter app."
[[ -f "$DRIVER" ]] || refuse "$DRIVER is missing. Commit the Screen Gen driver from the docs page."
[[ -f "$SUITE" ]] || refuse "$SUITE is missing. Commit the Screen Gen test from the docs page."
grep -q 'integration_test' pubspec.yaml || refuse "pubspec.yaml has no integration_test dependency. Add it under dev_dependencies and commit the lock file."
if grep -q 'package:your_app/' "$SUITE"; then
  refuse "$SUITE still imports package:your_app/main.dart. Point it at this app's main.dart and at its own widget keys."
fi

mkdir -p "$LOG_DIR"

# A clean Android status bar: 9:41, full battery, no notifications.
if [[ "$TARGET" == emulator-* ]]; then
  adb -s "$TARGET" shell settings put global sysui_demo_allowed 1
  demo() { adb -s "$TARGET" shell am broadcast -a com.android.systemui.demo -e command "$@" > /dev/null; }
  demo enter
  demo clock -e hhmm 0941
  demo battery -e level 100 -e plugged false
  demo network -e wifi show -e level 4
  demo notifications -e visible false
fi

# Plain strings, not arrays: the default bash on the macOS runner is 3.2, where
# an empty array under `set -u` is an unbound variable.
failed=''
silent=''
captured=0
first=1

IFS=',' read -ra requested <<< "$LOCALES"
{ echo "### Screen Gen · $DEVICE"; echo; echo '| Locale | Screenshots | Result |'; echo '| --- | --- | --- |'; } >> "$SUMMARY"

for raw in "${requested[@]}"; do
  locale="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [[ -z "$locale" ]] && continue
  if [[ ! "$locale" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$ ]]; then
    echo "::error::Refusing locale '$locale'."
    failed="$failed $locale"
    echo "| \`$locale\` | 0 | refused |" >> "$SUMMARY"
    continue
  fi

  out="screen-gen/$locale/$DEVICE"
  log="$LOG_DIR/$locale.log"
  : > "$log" || refuse "Cannot write capture log '$log'."
  shots=0
  status=1
  attempt=1
  while (( attempt <= ATTEMPTS )); do
    # A failed run may have delivered only a subset of the screenshots. Do not
    # let those stale files make a later retry look successful.
    rm -rf "$out" || refuse "Cannot clear capture output '$out'."
    mkdir -p "$out" || refuse "Cannot create capture output '$out'."
    echo "::group::$DEVICE · $locale (attempt $attempt of $ATTEMPTS)"
    echo "=== $DEVICE · $locale · attempt $attempt ===" >> "$log"
    SCREEN_GEN_OUT="$out" flutter drive \
      --driver="$DRIVER" \
      --target="$SUITE" \
      -d "$TARGET" \
      --dart-define=SCREEN_GEN_LOCALE="$locale" \
      --dart-define=SCREEN_GEN_DEMO=true 2>&1 | tee -a "$log"
    status="${PIPESTATUS[0]}"
    echo "::endgroup::"

    shots="$(pngs_in "$out")"
    if (( status == 0 && shots > 0 )); then break; fi

    if (( status != 0 )); then
      echo "::warning::$locale on $DEVICE: flutter drive exited $status (attempt $attempt of $ATTEMPTS)."
    else
      echo "::warning::$locale on $DEVICE: the test passed but wrote no screenshot (attempt $attempt of $ATTEMPTS)."
    fi
    echo "Last 40 lines of $log:"
    tail -n 40 "$log" | sed 's/^/  /'
    attempt=$(( attempt + 1 ))
  done

  if (( shots > 0 && status == 0 )); then
    captured=$(( captured + shots ))
    echo "$locale on $DEVICE: $(shots_said "$shots")."
    echo "| \`$locale\` | $shots | ok |" >> "$SUMMARY"
    # Names outside the contract are dropped when Appflow collects the artifact.
    for file in "$out"/*.png; do
      [[ -f "$file" ]] || continue
      name="$(basename "$file")"
      if [[ ! "$name" =~ ^(0[1-9]|10)_[a-z0-9_-]{1,40}\.png$ ]]; then
        echo "::warning::Appflow will ignore $locale/$DEVICE/$name. Name every shot <NN>_<name>.png, NN from 01 to 10, lower case."
      fi
    done
  elif (( shots > 0 )); then
    captured=$(( captured + shots ))
    failed="$failed $locale"
    echo "| \`$locale\` | $shots | partial failure |" >> "$SUMMARY"
    echo "::error::$locale produced $shots screenshot(s), but flutter drive exited $status. Partial files are retained for debugging; the locale is still failed."
  elif (( status == 0 )); then
    silent="$silent $locale"
    echo "| \`$locale\` | 0 | no screenshot taken |" >> "$SUMMARY"
  else
    failed="$failed $locale"
    echo "| \`$locale\` | 0 | capture failed |" >> "$SUMMARY"
  fi

  if (( shots == 0 && first == 1 && ${#requested[@]} > 1 )) && [[ "${SCREEN_GEN_KEEP_GOING:-}" != '1' ]]; then
    echo "::error::$locale produced no screenshots in $ATTEMPTS attempts, so the remaining locales are skipped. This is usually a setup problem; fix the reason above and capture again, or set SCREEN_GEN_KEEP_GOING=1 to try every locale anyway."
    break
  fi
  first=0
done

if [[ -n "$failed" ]]; then
  echo "::error::Capture failed on $DEVICE for:$failed. The reason is in the tail above and in full in the capture-logs-$DEVICE artifact."
fi
if [[ -n "$silent" ]]; then
  echo "::error::The test ran but took no screenshots on $DEVICE for:$silent. Check that it calls binding.takeScreenshot('01_…') and that $DRIVER is the driver the job passes."
fi
if (( captured == 0 )); then
  # The errors above already say why; this only has to stop the job.
  [[ -n "$failed$silent" ]] || echo "::error::LOCALES ('$LOCALES') holds no locale to capture."
  echo "Nothing to upload for $DEVICE."
  exit 1
fi

echo "$(shots_said "$captured") on $DEVICE."
[[ -z "$failed$silent" ]] || exit 1
