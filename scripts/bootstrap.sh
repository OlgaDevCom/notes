#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Flutter's native scaffold for the selected platforms, from a throwaway
# `flutter create`. Only missing files are added: the committed native
# projects, and anything changed in them since, always win. This supplies the
# binary parts AppGen does not render (launcher icons, the iOS asset catalog,
# the Gradle wrapper) and a whole platform folder if one was deleted.
created_ios=false
[[ -d ios ]] || created_ios=true
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
scaffold="$work/notes"
flutter create --no-pub --org com.example --project-name notes --platforms=android,ios "$scaffold" >/dev/null
for platform in android ios; do
  while IFS= read -r -d '' source; do
    path="${source#"$scaffold/"}"
    case "$path" in
      */local.properties|*.iml|*/Generated.xcconfig|*/flutter_export_environment.sh|*/GeneratedPluginRegistrant.*|*/ephemeral/*) continue ;;
    esac
    [[ -e "$path" ]] && continue
    mkdir -p "$(dirname "$path")"
    cp -p "$source" "$path"
    echo "bootstrap: added $path from flutter create"
  done < <(find "$scaffold/$platform" -type f -print0)
done



flutter pub get

# Flutter's SDK defaults are replaced once. A concrete value means someone has
# already configured that platform, so repeat runs leave it alone.
if [[ -f android/app/build.gradle.kts ]] && grep -q 'minSdk = flutter.minSdkVersion' android/app/build.gradle.kts; then
  sed -i.bak 's/minSdk = flutter.minSdkVersion/minSdk = 24/' android/app/build.gradle.kts
  rm -f android/app/build.gradle.kts.bak
elif [[ -f android/app/build.gradle ]] && grep -q 'minSdkVersion flutter.minSdkVersion' android/app/build.gradle; then
  sed -i.bak 's/minSdkVersion flutter.minSdkVersion/minSdkVersion 24/' android/app/build.gradle
  rm -f android/app/build.gradle.bak
fi
if [[ "$created_ios" == true && -f ios/Runner.xcodeproj/project.pbxproj ]]; then
  sed -E -i.bak 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g' ios/Runner.xcodeproj/project.pbxproj
  rm -f ios/Runner.xcodeproj/project.pbxproj.bak
fi

flutter gen-l10n
flutter pub run build_runner build
