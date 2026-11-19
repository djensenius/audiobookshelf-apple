# Releases (Fastlane and TestFlight)

TestFlight builds are started manually on a Mac with Fastlane. The `beta` lane delegates
archive, signing and upload to the existing `scripts/testflight-upload.sh`; Xcode Cloud
does not build or upload this app. GitHub Actions continues to lint, build and test (see
`.github/workflows/`). The App Store listing, privacy answers, privacy manifests, export
compliance and review notes are in [app-store.md](app-store.md).

| Path | Purpose |
| --- | --- |
| `Gemfile` / `Gemfile.lock` | Pin Fastlane for repeatable release commands |
| `fastlane/Fastfile` | Manual TestFlight `beta` lane |
| `mise.toml` (`mise run release:testflight`) | Fastlane entry point ([Fastlane TestFlight lane](#fastlane-testflight-lane)) |
| `scripts/testflight-upload.sh` | Archives and uploads from a Mac |
| `CHANGELOG.md` | Release notes; use the relevant section for TestFlight's "What to Test" |
| `Audiobookshelf.xcodeproj/xcshareddata/xcschemes/Audiobookshelf.xcscheme` | Shared scheme; its Archive action uses Release |

`ci_scripts/` contains the former Xcode Cloud hooks. They are retained for reference but
are not part of the current release path.

## Referring to builds

Identify a release by its **TestFlight build number**, for example `0.1.0 (42)`. The
version is `MARKETING_VERSION`; App Store Connect manages the build number during export.
iOS and macOS uploads may receive different build numbers. Use the actual number shown
in TestFlight in issues, PRs and bug reports.

## Build numbers

The upload script asks App Store Connect to manage the build number
(`manageAppVersionAndBuildNumber`), so the project needs no build-number step:

- `CURRENT_PROJECT_VERSION` stays `1` in `project.xcproj`. Only local builds use it.
- Scripts don't edit the build number. **Never run `agvtool`**: it can't read
  `project.xcproj`, and it leaves an empty `project.pbxproj` that breaks the project
  (see [the research notes](research/xcode-project-and-ci.md)).
- To release a new version, run `mise run release:version <x.y.z>` ([Versioning](#versioning)).
- App Store Connect manages uploaded build numbers. Don't manually increment
  `CURRENT_PROJECT_VERSION`.

## Versioning

`MARKETING_VERSION` is the version TestFlight and the App Store show (`1.0.0` in
`1.0.0 (42)`). Every target carries it (the app, the widget extension and the test
target), and they must match, or App Store Connect rejects the upload. Set it with:

```sh
mise run release:version 1.0.0
```

The task runs `scripts/set-version.sh 1.0.0`, then `mise run xcproj:check`. The script:

- accepts only `MAJOR.MINOR.PATCH` without leading zeros or suffixes (`1.0.0`, not `v1.0`,
  `1.0.0-beta` or `01.0.0`): `CFBundleShortVersionString` allows three integers only. It
  exits 64 and changes nothing otherwise;
- reads `project.xcproj` as JSON, sets every `MARKETING_VERSION` key, conditional ones
  such as `MARKETING_VERSION[config=Debug]` included, and rewrites the file with the
  pinned `xcprojformatter`, so nothing else changes;
- changes nothing when the version is already set, and leaves the project untouched on
  any error;
- never touches `CURRENT_PROJECT_VERSION` (see [Build numbers](#build-numbers)) and never
  runs `agvtool`.

`mise run test:release` (part of `mise run test:tools`) checks all of this on a copy of
the project.

## Releasing a version

A release goes from a `v<x.y.z>` tag to external TestFlight testers. Submitting that build
to the App Store is a separate, manual step in App Store Connect.

1. On a branch from `main`, move the `## [Unreleased]` entries in `CHANGELOG.md` into a
   new `## [x.y.z] - YYYY-MM-DD` section, leave `## [Unreleased]` empty above it, and add
   the version's link at the bottom.
2. Run `mise run release:version x.y.z`. Commit both changes, open a PR and merge it.
3. Tag the merge commit and push the tag:

   ```sh
   git fetch origin
   git tag -a vx.y.z -m "x.y.z" origin/main
   git push origin vx.y.z
   ```

   The tag must match `MARKETING_VERSION`; the manual Fastlane workflow does not start
   automatically from a tag. Verify they match before uploading.

   Then run `mise run release:testflight` from a clean checkout of that tagged commit.
   The upload script requires the commit to be on `origin/main`.
4. After processing, distribute the builds to internal testers in App Store Connect.
   For external testers, submit them to Beta App Review.
5. Record the **TestFlight build number**, for example "1.0.0 (57)", in the release issue
   and wherever the release is discussed. Use the same build when you submit to the App
   Store.
6. After an App Store release, the next build needs a higher version: run
   `mise run release:version` with the next version on `main` before more user-facing
   changes land.

## What to Test notes

The Fastlane upload does not set "What to Test" notes. After Apple processes the build,
copy the appropriate `CHANGELOG.md` section into TestFlight's build details. The legacy
`ci_post_xcodebuild.sh` generates notes for Xcode Cloud only.

## Fastlane TestFlight lane

Install the pinned dependencies once, then use the mise task:

```sh
bundle install
mise run release:testflight                 # iOS, then macOS
mise run release:testflight macos           # one platform
mise run release:testflight --export-only   # sign and export into .build/testflight; upload nothing
```

The equivalent direct Fastlane command is `bundle exec fastlane beta target:ios` (omit
`target` to build both platforms). The lane is manual; it does not upload on pushes,
create App Store Connect records or distribute builds to tester groups.

Before the first upload:

- The account holder has agreed to the latest Apple Developer Program License Agreement
  (developer.apple.com › Account) and to any agreements App Store Connect › Business
  lists. Until then App Store Connect requests fail with
  `FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`, and the archive fails before it
  compiles with "PLA Update available … must agree to the latest Program License
  Agreement", followed by profile errors about the App Groups capability.
- The App Store Connect app record for `org.davidjensenius.Audiobookshelf` exists with the
  iOS and macOS platforms ([maintainer setup](#maintainer-setup)).
- Xcode can sign in to Apple. Either use a team App Store Connect API key with the Admin
  role (creating cloud-managed distribution certificates needs it), or the account signed
  in to Xcode. The key is described by `~/.appstoreconnect/api_key.json` (`key_filepath`,
  `key_id` and `issuer_id`), by another such file named in `ABS_ASC_API_KEY_JSON`, or by
  `ABS_ASC_KEY_PATH`, `ABS_ASC_KEY_ID` and `ABS_ASC_ISSUER_ID`. Never commit or print the key.

The script:

- refuses a checkout with uncommitted or untracked files, or whose commit isn't on
  `origin/main` (it fetches first), so every build is a commit everyone can find. Set
  `ABS_TESTFLIGHT_ALLOW_ANY_COMMIT=1` to upload another commit on purpose;
- uses `/Applications/Xcode.app` unless `DEVELOPER_DIR` names another Xcode, prints its
  version, and builds packages at their committed `Package.resolved` versions;
- signs automatically for team `9JALHNGRBQ` with `-allowProvisioningUpdates`, so Xcode
  registers the App IDs and creates the distribution certificates and profiles it needs,
  with the entitlements from [ADR 0002](adr/0002-identity-and-no-migration.md);
- archives every platform before it uploads any, so a platform that fails to build or
  sign uploads nothing. If an upload fails after another platform's succeeded, it says
  which went up: rerun with only the rest, or that platform gets a second build;
- uploads App Store-eligible builds (not internal-only) with their symbols. The archive's
  build number is `CURRENT_PROJECT_VERSION`; Xcode raises it above the platform's earlier
  uploads when it's taken (`manageAppVersionAndBuildNumber`);
- keeps the archives, with their dSYMs, in `.build/testflight/<time>-<commit>` (or under
  `ABS_TESTFLIGHT_DIR`), and deletes its DerivedData when it exits. Remove old folders
  when you no longer need them.

After the upload:

1. Wait for App Store Connect to process the builds; Apple emails when each is ready.
   Export compliance needs no answer ([why](app-store.md#export-compliance)).
2. Add the "What to Test" notes from the matching `CHANGELOG.md` section.
3. Add the builds to the internal group, unless it gets new builds automatically. For
   external testers, add them to the external group, which submits them to Beta App Review.
4. Record the TestFlight build numbers ([Referring to builds](#referring-to-builds)).

## The legacy app's URL scheme

The app (bundle ID `org.davidjensenius.Audiobookshelf`) registers the `audiobookshelf://`
URL scheme for deep links ([ADR 0004](adr/0004-navigation.md)). The legacy app
(`com.audiobookshelf.app`) registers the same scheme, and there is no second one.

- With both installed, iOS doesn't define which app receives an `audiobookshelf://` link,
  so a link can open the legacy app instead. Sign-in isn't affected, because the sign-in
  session receives its own callback ([OIDC testing](testing/oidc.md)).
- Ask testers to remove the legacy app, and check deep links on a device that doesn't
  have it.

## Maintainer setup

These steps require the maintainer's Apple account and signing access:

Before you start, finish the
[ADR 0002 checklist](adr/0002-identity-and-no-migration.md#maintainer-checklist):

- [ ] The explicit App ID `org.davidjensenius.Audiobookshelf` (team `9JALHNGRBQ`) is
      registered for iOS and macOS with the App Groups capability.
- [ ] The App Group `group.org.davidjensenius.Audiobookshelf` is registered and
      assigned to both the app and widget App IDs.
- [ ] The App Store Connect app record exists with the iOS and macOS platforms.

- [ ] In App Store Connect › TestFlight, create an internal group and add yourself.
- [ ] Install the pinned Fastlane gem with `bundle install`.
- [ ] Configure the App Store Connect API key locally using the documented environment
      variables or `~/.appstoreconnect/api_key.json`; never commit or print its contents.
- [ ] Signing: the targets use automatic signing for team `9JALHNGRBQ`. Xcode creates
      distribution certificates and profiles with `-allowProvisioningUpdates`. The
      profiles must contain the entitlements from ADR 0002: App Group and keychain access
      group on both platforms, plus App Sandbox and network client on macOS. The embedded
      widget extension gets its own profiles with the same App Group and keychain group
      (plus App Sandbox on macOS).
- [ ] Export compliance: no prompt is expected, because
      `ITSAppUsesNonExemptEncryption = NO` is set for the app and the widget extension
      ([why](app-store.md#export-compliance)).
- [ ] From a clean checkout of a commit on `origin/main`, run
      `mise run release:testflight`. Check:
  - both archives succeed;
  - the TestFlight build appears after Apple's processing;
  - add it to the internal group and record each platform's build number.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `bundle exec fastlane` cannot find a gem | Run `bundle install` at the repository root. |
| Script output shows it ran as `zsh <file>`, or "permission denied" | The executable bit got lost. Check `git ls-files -s scripts/testflight-upload.sh` shows `100755`; restore it with `git update-index --chmod=+x scripts/testflight-upload.sh`. |
| Signing fails with an App Group or keychain-group entitlement error | The App ID is missing the App Groups capability, or the group isn't assigned to it. Fix it in the developer portal (ADR 0002 checklist), then rebuild. |
| "What to Test" is empty or old | Fastlane does not upload those notes. Paste the matching `CHANGELOG.md` section into TestFlight's build details. |
| Upload rejected because the version is closed or already released | App Store Connect doesn't take new builds for a version that is already on the App Store. Run `mise run release:version` with the next version and merge it. |
| Package resolution fails | The only remote package is ZIPFoundation (pinned in `AudiobookshelfKit`). Its pin is committed in both `Packages/AudiobookshelfKit/Package.resolved` and `Audiobookshelf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; update both when a remote package changes. |

## References

- [Fastlane documentation](https://docs.fastlane.tools/)
- [ADR 0002: App identity](adr/0002-identity-and-no-migration.md) and
  [research: Xcode project and CI](research/xcode-project-and-ci.md)
