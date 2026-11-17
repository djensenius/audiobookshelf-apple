#!/usr/bin/env bash
# Archive the app in Release and upload it to App Store Connect for TestFlight from this
# Mac: xcodebuild archive, then xcodebuild -exportArchive with the upload destination. No
# Fastlane. This is how a build reaches TestFlight until the Xcode Cloud workflows exist
# (issue #20). See docs/release.md › Uploading from a Mac.
#
#   scripts/testflight-upload.sh                  # iOS, then macOS
#   scripts/testflight-upload.sh macos            # one platform
#   scripts/testflight-upload.sh --export-only    # sign and export locally; upload nothing
#
# Signing is automatic for team 9JALHNGRBQ, with -allowProvisioningUpdates. xcodebuild signs
# in to Apple with an App Store Connect API key: ABS_ASC_KEY_PATH, ABS_ASC_KEY_ID and
# ABS_ASC_ISSUER_ID, or else the key_filepath, key_id and issuer_id in
# ~/.appstoreconnect/api_key.json (ABS_ASC_API_KEY_JSON names another file). Without a key
# it uses the account signed in to Xcode. App Store Connect picks the build number
# (manageAppVersionAndBuildNumber), and the version is MARKETING_VERSION.
#
# The checkout must be clean, so the build is exactly its commit. Archives and exports go
# to .build/testflight/<time>-<commit>, or ABS_TESTFLIGHT_DIR/<time>-<commit>. DerivedData
# is deleted when the script exits.
set -euo pipefail
# App Store Connect rejects a macOS package with files only their owner can read
# (ITMS-90255), so don't inherit a restrictive umask.
umask 022

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
team="9JALHNGRBQ"

usage() {
  echo "usage: scripts/testflight-upload.sh [--export-only] [ios|macos]..." >&2
  exit 64
}

destination="upload"
platforms=""
for arg in "$@"; do
  case "$arg" in
    --export-only) destination="export" ;;
    ios | macos)
      case " $platforms " in
        *" $arg "*) ;;
        *) platforms="$platforms $arg" ;;
      esac
      ;;
    *) usage ;;
  esac
done
platforms="${platforms:- ios macos}"

if [[ -n "$(git -C "$root" status --porcelain --untracked-files=all)" ]]; then
  echo "error: $root has uncommitted or untracked files. Commit or stash them, so the build is exactly a commit:" >&2
  git -C "$root" status --short --untracked-files=all >&2
  exit 65
fi
commit="$(git -C "$root" rev-parse --short HEAD)"

key_path="${ABS_ASC_KEY_PATH:-}"
key_id="${ABS_ASC_KEY_ID:-}"
issuer="${ABS_ASC_ISSUER_ID:-}"
if [[ -z "$key_path$key_id$issuer" ]]; then
  key_json="${ABS_ASC_API_KEY_JSON:-$HOME/.appstoreconnect/api_key.json}"
  if [[ -f "$key_json" ]]; then
    if ! key_path="$(plutil -extract key_filepath raw -o - "$key_json")" ||
      ! key_id="$(plutil -extract key_id raw -o - "$key_json")" ||
      ! issuer="$(plutil -extract issuer_id raw -o - "$key_json")"; then
      echo "error: $key_json needs the strings key_filepath, key_id and issuer_id" >&2
      exit 66
    fi
  fi
fi
auth=()
if [[ -n "$key_path$key_id$issuer" ]]; then
  if [[ -z "$key_path" || -z "$key_id" || -z "$issuer" ]]; then
    echo "error: an App Store Connect API key needs a path, a key ID and an issuer ID" >&2
    exit 64
  fi
  key_path="${key_path/#\~/$HOME}"
  if [[ ! -f "$key_path" ]]; then
    echo "error: App Store Connect API key $key_path not found" >&2
    exit 66
  fi
  auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
  echo "Signing in to Apple with App Store Connect API key $key_id"
else
  echo "No App Store Connect API key; xcodebuild uses the account signed in to Xcode"
fi

out="${ABS_TESTFLIGHT_DIR:-$root/.build/testflight}/$(date +%Y%m%d-%H%M%S)-$commit"
mkdir -p "$out"
trap 'rm -rf "$out/DerivedData"' EXIT

cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>$destination</string>
  <key>teamID</key>
  <string>$team</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <true/>
</dict>
</plist>
EOF

for platform in $platforms; do
  case "$platform" in
    ios) name="iOS" ;;
    macos) name="macOS" ;;
  esac
  echo "=== Archiving $name at $commit"
  xcodebuild archive \
    -project "$root/Audiobookshelf.xcodeproj" \
    -scheme Audiobookshelf \
    -configuration Release \
    -destination "generic/platform=$name" \
    -archivePath "$out/$platform.xcarchive" \
    -derivedDataPath "$out/DerivedData" \
    -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"}
  if [[ "$destination" == "upload" ]]; then
    echo "=== Uploading $name to App Store Connect"
  else
    echo "=== Exporting $name to $out/$platform"
  fi
  xcodebuild -exportArchive \
    -archivePath "$out/$platform.xcarchive" \
    -exportPath "$out/$platform" \
    -exportOptionsPlist "$out/ExportOptions.plist" \
    -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"}
done

if [[ "$destination" == "upload" ]]; then
  echo "Uploaded$platforms at $commit. App Store Connect numbers each build; record the TestFlight build number once it has processed."
else
  echo "Exported$platforms at $commit to $out"
fi
echo "Archives (with dSYMs): $out"
