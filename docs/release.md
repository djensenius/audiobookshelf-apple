# Releases (Xcode Cloud and TestFlight)

Xcode Cloud builds every push to `main` and sends iOS and macOS builds to internal
TestFlight testers. There is no Fastlane, and nothing uploads from a developer Mac.
GitHub Actions only lints, builds and tests (see `.github/workflows/`).

The Xcode Cloud workflow lives in App Store Connect, not in this repository. The
repository provides:

| Path | Purpose |
| --- | --- |
| `ci_scripts/ci_post_clone.sh` | Prints the Xcode version. Holds the opt-in `.xcproj` fallback (below). Installs nothing. |
| `ci_scripts/ci_post_xcodebuild.sh` | Writes `TestFlight/WhatToTest.en-US.txt` after archive actions |
| `Audiobookshelf.xcodeproj/xcshareddata/xcschemes/Audiobookshelf.xcscheme` | Shared scheme; its Archive action uses Release |

## Referring to builds

A release is identified by its **TestFlight build number**, for example "TestFlight
build 42". That number is the Xcode Cloud build number (`CI_BUILD_NUMBER`). TestFlight
shows it as `0.1.0 (42)`, where `0.1.0` is `MARKETING_VERSION`. One Xcode Cloud build
archives both platforms, so the iOS and macOS builds from the same commit share the
number. Use it in issues, PRs and bug reports.

## Build numbers

Xcode Cloud assigns each build an integer build number. It starts at 1 and goes up by
one with every build of the product. When Xcode Cloud distributes a build to TestFlight
or the App Store, it uses that number as the build number (`CFBundleVersion`). Apple
documents this in
[Setting the next build number for Xcode Cloud builds](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds).

So the project needs no build-number step:

- `CURRENT_PROJECT_VERSION` stays `1` in `project.xcproj`. Only local builds use it.
- Scripts don't edit the build number. **Never run `agvtool`**: it can't read
  `project.xcproj`, and it leaves an empty `project.pbxproj` that breaks the project
  (see [the research notes](research/xcode-project-and-ci.md)).
- To release a new version, change `MARKETING_VERSION` in `project.xcproj` and run
  `mise run xcproj:format`.
- Mac App Store builds need a build number that always goes up, even across versions.
  The Xcode Cloud counter does that, as long as nobody uploads a build by hand. If a
  manual upload ever happens, set a higher next number in App Store Connect › your app ›
  Xcode Cloud › Settings › Build Number (Admin or App Manager role).

Check this on the first build: TestFlight must show the Xcode Cloud build number, not
`(1)`. If it shows `(1)`, see [Troubleshooting](#troubleshooting).

## What to Test notes

After an archive action for TestFlight, `ci_post_xcodebuild.sh` writes
`TestFlight/WhatToTest.en-US.txt` at the repository root, next to the project. Xcode
Cloud reads that file when it uploads the build and puts its text in TestFlight's "What
to Test" field
([Including notes for testers](https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app)).

The notes contain:

- a `Build <CI_BUILD_NUMBER> (<short commit>)` line;
- the last 20 non-merge commits. Tags aren't used, because the repository still has
  old upstream tags (`v0.9.x-beta`). Each commit is its subject line plus its body, without
  blank lines and without `Co-authored-by`, `Copilot-Session` and `Signed-off-by`
  trailers;
- at most 4,000 bytes (TestFlight's limit is 4,000 characters). The text is cut at a
  line break.

The notes are optional, so the script never fails the build. It prints
`Skipping What to Test notes: <reason>`, writes nothing and exits 0 when:

- `CI_APP_STORE_SIGNED_APP_PATH` isn't a directory. Apple's example uses this check:
  the App Store-signed export only exists after a successful archive whose deployment
  preparation targets TestFlight or the App Store;
- `xcodebuild` failed (`CI_XCODEBUILD_EXIT_CODE` isn't 0);
- `CI_PRIMARY_REPOSITORY_PATH` is empty or unset, or the script can't `cd` into it;
- `git log` fails, or the notes can't be written. It writes `WhatToTest.en-US.txt.tmp`
  first and moves it into place, and removes the temp file on failure.

If the clone is shallow, it runs `git fetch --deepen=100`. Prompts are off
(`GIT_TERMINAL_PROMPT=0`, SSH `BatchMode=yes`), and the connection gives up after a
20-second SSH connect timeout or 30 seconds below 1,000 bytes/s over HTTP. If the fetch
fails, it prints a warning and uses whatever history is there. `TestFlight/` is in
`.gitignore`; don't commit it.

Try the script locally (it writes into the given checkout):

```sh
CI_APP_STORE_SIGNED_APP_PATH=/tmp CI_PRIMARY_REPOSITORY_PATH="$PWD" CI_BUILD_NUMBER=0 \
  ci_scripts/ci_post_xcodebuild.sh && cat TestFlight/WhatToTest.en-US.txt && rm -r TestFlight
```

## The legacy app's URL scheme

The app (bundle ID `org.davidjensenius.Audiobookshelf`) registers the `audiobookshelf://`
URL scheme for deep links ([ADR 0004](adr/0004-navigation.md)). The legacy app
(`com.audiobookshelf.app`) registers the same scheme, and there is no second one.

- With both installed, iOS doesn't define which app receives an `audiobookshelf://` link,
  so a link can open the legacy app instead. Sign-in isn't affected, because the sign-in
  session receives its own callback ([OIDC testing](testing/oidc.md)).
- Ask testers to remove the legacy app, and check deep links on a device that doesn't
  have it.

## `.xcproj` fallback

Apple doesn't say whether Xcode Cloud accepts the JSON project format
(`project.xcproj`). If a build fails because Xcode Cloud can't read the project, turn
on the fallback:

1. In the workflow, open Environment › Environment Variables and add
   `ABS_CONVERT_PROJECT` = `1`.
2. Start a build. `ci_post_clone.sh` then runs
   `xcodebuild -convert-project 'Xcode 16.0' -project Audiobookshelf.xcodeproj` in the
   Xcode Cloud checkout. That replaces `project.xcproj` with a classic `project.pbxproj`
   (objectVersion 110) before Xcode Cloud runs `xcodebuild`. The script fails if
   `project.xcproj` is still there afterwards, or if `project.pbxproj` is missing or
   empty.
3. Never commit a converted project. The repository keeps `project.xcproj`, and Xcode
   rejects a project that has both files.

Checked locally with Xcode 27.2 (build 27B52):

- `xcodebuild -help` lists `-convert-project FORMAT`.
- An unknown format makes it print the accepted ones: `Xcode 2.4` … `Xcode 16.0`,
  `Xcode 16.3`, `Xcode 26.3`, `Xcode 27.0` and `Xcode Project` (JSON).
- `ABS_CONVERT_PROJECT=1 ci_scripts/ci_post_clone.sh` on a scratch copy produced
  `project.pbxproj` and `project.xcworkspace` and removed `project.xcproj`.
  `xcodebuild -list` on the result shows both targets and the `Audiobookshelf` scheme.

Limit: the fallback only helps if the failure happens during the build, after the
clone. If Xcode or App Store Connect can't read the project while you create the
workflow (for example, no scheme to pick), a script can't fix that. Record the error in
issue #20.

## Maintainer setup checklist

These steps need the maintainer's Apple account; no agent can do them.

Before you start, finish the
[ADR 0002 checklist](adr/0002-identity-and-no-migration.md#maintainer-checklist):

- [ ] The explicit App ID `org.davidjensenius.Audiobookshelf` (team `9JALHNGRBQ`) is
      registered for iOS and macOS with the App Groups capability.
- [ ] The App Group `group.org.davidjensenius.Audiobookshelf` is registered and
      assigned to that App ID.
- [ ] The App Store Connect app record exists with the iOS and macOS platforms.

Then create the workflow (Xcode › Integrate › Create Workflow, or App Store Connect ›
the app › Xcode Cloud):

- [ ] Connect Xcode Cloud to the GitHub repository `djensenius/audiobookshelf-apple`.
      Pick the product for `Audiobookshelf.xcodeproj`, app `Audiobookshelf`.
- [ ] Name the workflow `TestFlight (main)`. Restrict editing to Admins if you want.
- [ ] Environment: Xcode **27.2** and the latest stable macOS, not a beta (Apple has
      had beta-environment problems before). Leave "Clean" off. Add no environment
      variables unless you need the `.xcproj` fallback.
- [ ] Start condition: Branch Changes on `main` only. Turn on auto-cancel of
      superseded builds.
- [ ] Action: Archive, platform **iOS**, scheme `Audiobookshelf`, deployment
      preparation **TestFlight (Internal Testing Only)**.
- [ ] Action: Archive, platform **macOS**, scheme `Audiobookshelf`, deployment
      preparation **TestFlight (Internal Testing Only)**.
      The setting is named "Deployment Preparation" in the archive action; if your Xcode
      labels the options differently, pick the internal-testing-only TestFlight option.
- [ ] In App Store Connect › TestFlight, create an internal group (for example
      `Internal`) and add yourself.
- [ ] Post-action: TestFlight Internal Testing, once for the iOS archive and once for
      the macOS archive, both to that internal group.
- [ ] Signing: no setup. The targets use automatic signing with team `9JALHNGRBQ`, and
      Xcode Cloud uses its cloud-managed distribution certificates and creates the
      profiles. The profiles must contain the entitlements from ADR 0002: App Group
      and keychain access group on both platforms, plus App Sandbox and network client
      on macOS. The embedded widget extension (`org.davidjensenius.Audiobookshelf.Widgets`)
      gets its own profiles with the same App Group and keychain group (plus App Sandbox
      on macOS). Don't upload certificates or profiles.
- [ ] Export compliance: no prompt is expected, because
      `ITSAppUsesNonExemptEncryption = NO` is set.
- [ ] Start a build on `main`. Check:
  - both archives succeed;
  - the build log shows `Xcode 27.2` from `ci_post_clone.sh`;
  - TestFlight shows `0.1.0 (N)` with N equal to the Xcode Cloud build number;
  - "What to Test" contains the commit notes.
- [ ] Post the iOS and macOS TestFlight build numbers in the PR for issue #20. If you
      needed the `.xcproj` fallback, say so there too.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Xcode 27.2 isn't in the Environment picker | Xcode Cloud doesn't offer it yet. Wait, or pick the newest Xcode 27.x that can open `project.xcproj` (the format opens in earlier Xcode 27 releases). |
| Build fails because the project can't be read or parsed | Turn on the `.xcproj` fallback (`ABS_CONVERT_PROJECT=1`). |
| Script output shows it ran as `zsh <file>`, or "permission denied" | The executable bit got lost. Check `git ls-files -s ci_scripts` shows `100755`; fix with `git update-index --chmod=+x ci_scripts/<script>.sh`. |
| Signing fails with an App Group or keychain-group entitlement error | The App ID is missing the App Groups capability, or the group isn't assigned to it. Fix it in the developer portal (ADR 0002 checklist), then rebuild. |
| macOS upload is rejected because the build number is too low | A build was uploaded outside Xcode Cloud. Raise Next Build Number in App Store Connect › Xcode Cloud › Settings › Build Number. |
| TestFlight shows build `(1)` for every build | Xcode Cloud didn't apply its build number. Don't use `agvtool`. Add a CI-only text edit of `"CURRENT_PROJECT_VERSION": "1"` in `project.xcproj` to `ci_post_clone.sh` (in the checkout only, never committed), and record it here. |
| "What to Test" is empty or old | Check the `ci_post_xcodebuild.sh` log for `Wrote …/WhatToTest.en-US.txt` or a `Skipping What to Test notes: …` line, which gives the reason. Notes are only written after a successful archive for TestFlight. |
| Package resolution fails | Xcode Cloud doesn't resolve packages automatically. Only the local `AudiobookshelfKit` package is used today. If a remote package is added, commit `Audiobookshelf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. |

## References

- [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts):
  the `ci_scripts` location, script names, the shebang and executable bit, and
  `zsh` when they're missing.
- [Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference):
  `CI_PRIMARY_REPOSITORY_PATH` (the clone, for example `/Volumes/workspace/repository`),
  `CI_WORKSPACE_PATH` (for example `/Volumes/workspace`), `CI_BUILD_NUMBER`,
  `CI_XCODEBUILD_ACTION`, `CI_XCODEBUILD_EXIT_CODE`, `CI_ARCHIVE_PATH` (archive actions
  only) and `CI_APP_STORE_SIGNED_APP_PATH` (the export signed for TestFlight and the App
  Store).
- [Setting the next build number for Xcode Cloud builds](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
- [Including notes for testers with a beta release of your app](https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app)
- [Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
- [ADR 0002: App identity](adr/0002-identity-and-no-migration.md) and
  [research: Xcode project and CI](research/xcode-project-and-ci.md)
