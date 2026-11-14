#!/usr/bin/env bash
# App Store screenshots (docs/testing/screenshots.md): runs ScreenshotTests per device and locale
# and writes build/screenshots/<locale>/<device>/<screen>.png, checking each image's pixel size.
#
#   scripts/screenshots.sh [--device <id>]... [--locale <tag>]...
#
#   --device  iphone-6.9, ipad-13, duo-outer, duo-inner or mac; repeatable. The default is
#             iphone-6.9, ipad-13 and duo-outer; duo-inner and mac are reported as skipped.
#   --locale  BCP 47 tag passed to the app as -AppleLanguages/-AppleLocale; repeatable
#             (default en-US).
#
# Each simulator device gets its own simulator, abs-shots-<device>-<pid>, with a clean status bar
# (simctl status_bar), deleted on exit. duo-inner needs the Duo unfolded by hand (no command line
# or XCUITest API folds it), so it asks for that and needs a terminal. mac needs Automation Mode
# (docs/testing/ui-tests.md) and a 16:10 main display.
# Runs on macOS /bin/bash 3.2.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# <id> <simulator device type or "-"> <width> <height>. App Store Connect's sizes.
MATRIX="iphone-6.9 com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max 1320 2868
ipad-13 com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB 2064 2752
duo-outer com.apple.CoreSimulator.SimDeviceType.iPhone-Duo 1398 2034
duo-inner com.apple.CoreSimulator.SimDeviceType.iPhone-Duo 2007 2853
mac - 2880 1800"
DEFAULT_DEVICES="iphone-6.9 ipad-13 duo-outer"
# The attachments ScreenshotTests makes, as appstore-<screen>.
# TODO(#109): add player, downloads and settings once ScreenshotTests captures them.
SCREENS="home library item"

OUT=build/screenshots
WORK=.build/screenshots
DERIVED=.build/DerivedData
PROJECT=(-project Audiobookshelf.xcodeproj -scheme Audiobookshelf -derivedDataPath "$DERIVED")
ONLY=(-only-testing:AudiobookshelfUITests/ScreenshotTests -parallel-testing-enabled NO)
MAC_SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  ABS_MACOS_ENTITLEMENTS=Audiobookshelf/Audiobookshelf-AdHoc.entitlements
  ABS_WIDGETS_MACOS_ENTITLEMENTS=AudiobookshelfWidgets/AudiobookshelfWidgets-AdHoc.entitlements)

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

devices=""
locales=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "error: --device needs a value" >&2; exit 2; }
      if ! printf '%s\n' "$MATRIX" | awk -v id="$2" '$1 == id { found = 1 } END { exit !found }'; then
        echo "error: unknown device '$2'; use one of: $(printf '%s\n' "$MATRIX" | awk '{ printf "%s ", $1 }')" >&2
        exit 2
      fi
      devices="$devices $2"
      shift 2
      ;;
    --locale)
      [[ $# -ge 2 && "$2" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$ ]] || { echo "error: --locale needs a tag such as en-US" >&2; exit 2; }
      locales="$locales $2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done
explicit=1
if [[ -z "$devices" ]]; then
  devices="$DEFAULT_DEVICES"
  explicit=0
fi
locales="${locales:- en-US}"
locales="${locales# }"

created=()
cleanup() {
  local status=$? udid
  for udid in ${created[@]+"${created[@]}"}; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  done
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

field() { # field <device> <column>
  printf '%s\n' "$MATRIX" | awk -v id="$1" -v col="$2" '$1 == id { print $col }'
}

# Exports the result bundle's appstore-<screen> attachments to $OUT/<locale>/<device>/<screen>.png
# and checks every expected screen is there at <width>x<height> pixels. A mac image of another
# 16:10 size is scaled to fit first.
extract() { # extract <xcresult> <locale> <device> <width> <height>
  local bundle=$1 locale=$2 device=$3 width=$4 height=$5
  local export="$WORK/$locale-$device-attachments" dest="$OUT/$locale/$device" failed=0 screen file w h
  rm -rf "$export" "$dest"
  mkdir -p "$export" "$dest" || return 1
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$export" >/dev/null || return 1
  python3 - "$export" "$dest" <<'PY' || return 1
import json, re, shutil, sys
export, dest = sys.argv[1], sys.argv[2]
with open(f"{export}/manifest.json") as manifest:
    tests = json.load(manifest)
for test in tests:
    for attachment in test.get("attachments", []):
        match = re.match(r"appstore-([a-z0-9-]+)", attachment.get("suggestedHumanReadableName", ""))
        if match:
            shutil.copyfile(f"{export}/{attachment['exportedFileName']}", f"{dest}/{match.group(1)}.png")
PY
  for screen in $SCREENS; do
    file="$dest/$screen.png"
    if [[ ! -f "$file" ]]; then
      echo "error: $locale/$device: no $screen screenshot in $bundle" >&2
      failed=1
      continue
    fi
    w=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')
    h=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')
    if [[ "$device" == mac && "$w" != "$width" && $((w * height)) -eq $((h * width)) ]]; then
      sips --resampleHeightWidth "$height" "$width" "$file" >/dev/null
      w=$width
      h=$height
    fi
    if [[ "$w" != "$width" || "$h" != "$height" ]]; then
      echo "error: $file is ${w}x${h}, expected ${width}x${height}" >&2
      failed=1
    else
      echo "ok: $file ${w}x${h}"
    fi
  done
  return "$failed"
}

built_ios=0
build_ios() {
  [[ $built_ios -eq 1 ]] && return 0
  xcodebuild build-for-testing "${PROJECT[@]}" -destination 'generic/platform=iOS Simulator' \
    -jobs 2 CODE_SIGNING_ALLOWED=NO -quiet || return 1
  built_ios=1
}

run_simulator() { # run_simulator <device> <device type> <width> <height>
  local device=$1 type=$2 width=$3 height=$4 udid locale bundle
  # Called as an if condition, where set -e doesn't apply, so every step checks its own status.
  build_ios || return 1
  udid=$(xcrun simctl create "abs-shots-$device-$$" "$type") || return 1
  created+=("$udid")
  xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName '' --batteryState discharging --batteryLevel 100 || return 1
  if [[ "$device" == duo-inner ]]; then
    if [[ ! -t 0 ]]; then
      echo "error: duo-inner: unfold the simulator by hand (DeviceHub's hinge slider); run this in a terminal" >&2
      return 1
    fi
    open -a DeviceHub >/dev/null 2>&1 || true
    read -r -p "Unfold abs-shots-$device-$$ fully in DeviceHub (hinge slider), then press Return: "
  fi
  for locale in $locales; do
    bundle="$WORK/$locale-$device.xcresult"
    rm -rf "$bundle"
    TEST_RUNNER_ABS_SCREENSHOTS=1 TEST_RUNNER_ABS_SCREENSHOT_LOCALE="$locale" \
      xcodebuild test-without-building "${PROJECT[@]}" -destination "platform=iOS Simulator,id=$udid" \
      "${ONLY[@]}" -resultBundlePath "$bundle" -quiet || return 1
    extract "$bundle" "$locale" "$device" "$width" "$height" || return 1
  done
}

run_mac() { # run_mac <width> <height>
  local width=$1 height=$2 locale bundle
  if automationmodetool 2>&1 | grep -q "Automation Mode is disabled"; then
    echo "error: mac: Automation Mode is disabled, so XCUITest can't drive the app (#46); enable it with" \
      "'sudo automationmodetool enable-automationmode-without-authentication'" >&2
    return 1
  fi
  for locale in $locales; do
    bundle="$WORK/$locale-mac.xcresult"
    rm -rf "$bundle"
    TEST_RUNNER_ABS_SCREENSHOTS=1 TEST_RUNNER_ABS_SCREENSHOT_LOCALE="$locale" \
      xcodebuild test "${PROJECT[@]}" -destination 'platform=macOS' "${ONLY[@]}" -jobs 2 "${MAC_SIGNING[@]}" \
      -resultBundlePath "$bundle" -quiet || return 1
    extract "$bundle" "$locale" mac "$width" "$height" || return 1
  done
}

mkdir -p "$WORK" "$OUT"
failures=0
summary=""
for device in $devices; do
  type=$(field "$device" 2)
  width=$(field "$device" 3)
  height=$(field "$device" 4)
  echo "== $device (${width}x${height})"
  if [[ "$device" == mac ]]; then
    if run_mac "$width" "$height"; then result=ok; else result=FAILED; fi
  elif run_simulator "$device" "$type" "$width" "$height"; then
    result=ok
  else
    result=FAILED
  fi
  [[ "$result" == ok ]] || failures=$((failures + 1))
  summary="$summary$device: $result"$'\n'
done
if [[ $explicit -eq 0 ]]; then
  summary="${summary}duo-inner: skipped (unfold by hand; run with --device duo-inner)"$'\n'
  summary="${summary}mac: skipped (needs Automation Mode, #46; run with --device mac)"$'\n'
fi

echo "== Summary ($locales -> $OUT)"
printf '%s' "$summary"
[[ $failures -eq 0 ]]
