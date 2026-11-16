#!/usr/bin/env bash

# shellcheck disable=SC2034 # The main script reads this array and the classify output.
AREA_TITLES=(
  ""
  "Playback — port to ABSPlayback and the native player UI"
  "Downloads & offline — port to ABSDownloads and offline UI"
  "API & authentication — port to ABSAPI and ABSRealtime"
  "Feature UI & state — port to SwiftUI and ABSAppModel"
  "Local data & progress — port to ABSData and sync"
  "Settings & accounts — port to ABSAppModel settings"
  "Localization — re-import strings"
  "Android-only — usually not applicable"
  "Build & tooling — usually not applicable"
  "Other"
)

# shellcheck disable=SC2034 # classify sets this for the caller after sourcing.
classify() {
  case "$1" in
    ios/App/Shared/player/* | ios/App/App/plugins/AbsAudioPlayer.swift | \
      pages/player* | components/player/* | components/app/AudioPlayer.vue | \
      store/player* | plugins/AbsAudioPlayer.js)
      area=1
      ;;
    ios/App/App/plugins/AbsDownloader.swift | ios/App/Shared/models/download/* | \
      pages/download* | components/download* | store/download* | plugins/AbsDownloader.js)
      area=2
      ;;
    ios/App/Shared/util/ApiClient.swift | ios/App/Shared/models/server/* | \
      plugins/*ApiClient* | plugins/*Auth* | middleware/* | pages/connect* | components/connect*)
      area=3
      ;;
    ios/App/Shared/util/Database.swift | ios/App/Shared/models/local/*)
      area=5
      ;;
    pages/settings* | components/settings* | store/settings*)
      area=6
      ;;
    pages/* | components/* | layouts/* | store/* | plugins/* | mixins/* | utils/* | objects/* | \
      assets/* | static/* | ios/*)
      area=4
      ;;
    strings/*) area=7 ;;
    android/*) area=8 ;;
    .github/* | fastlane/* | package.json | package-lock.json | capacitor.config.json | ionic.config.json | \
      nuxt.config.js | tailwind.config.js)
      area=9
      ;;
    *) area=10 ;;
  esac
}
