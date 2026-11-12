# App Store submission

What the App Store Connect record needs, and what the repository already declares. The
record itself, screenshots and the archive privacy report are manual steps for the
maintainer ([Manual steps](#manual-steps)). Releases go through Xcode Cloud
([release.md](release.md)).

## Listing

Placeholders in angle brackets are for the maintainer to fill in. The limits are App
Store Connect's.

| Field | Value |
| --- | --- |
| Name (30 characters) | Audiobookshelf |
| Subtitle (30 characters) | Your self-hosted audiobooks |
| Primary category | Books (matches `LSApplicationCategoryType` `public.app-category.books` in `project.xcproj`) |
| Secondary category | Entertainment (optional) |
| Keywords (100 bytes, comma-separated) | audiobook,podcast,self-hosted,server,library,offline,player,listen,narrator,series |
| Support URL | `<support URL, for example the GitHub repository's issues page>` |
| Privacy policy URL | `<privacy policy URL>` (required, even when no data is collected) |
| Marketing URL | `<optional>` |
| Copyright | `<year and holder>` |
| Age rating | Answer "None" or "No" to every content question: the app ships no content of its own. That gives the lowest rating (4+). The maintainer confirms this in the questionnaire. |

### Description

> Audiobookshelf plays the audiobooks and podcasts on your own Audiobookshelf server.
> It's a native app for iPhone, iPad and Mac.
>
> - Browse your libraries, series, authors, collections and playlists.
> - Pick up where you left off: your progress syncs with your server.
> - Sleep timer, playback speed, chapters and a listening queue.
> - Sign in with a username and password or your server's single sign-on (OpenID
>   Connect).
>
> You need an Audiobookshelf server (https://www.audiobookshelf.org). The app connects
> only to the servers you add. It has no account of its own, no analytics and no ads.

Check the feature list against the build being submitted, and drop anything that isn't
in it yet. These claims are left out until their features ship, so add each one only
when the submitted build has it:

| Claim | Add to | Ships with |
| --- | --- | --- |
| "with CarPlay" (after "iPhone, iPad and Mac") | Description, review notes | The CarPlay audio entitlement (#77) and the CarPlay scene (#79) |
| "and widgets" | Description, review notes | Continue-listening widgets (#89) |
| "- Download books and episodes to listen without a connection." and "listening offline is kept and sent when you're back online" | Description, review notes | Downloads wiring and UI (#194, #75) |

## App privacy (nutrition label)

In App Store Connect › App Privacy, answer **"No, we do not collect data from this
app"**. Apple counts data as collected only when it leaves the device in a way the
developer or a third party can access. This app:

- sends account, library and listening data only to the Audiobookshelf server the user
  adds and runs (or chooses), which the developer doesn't operate or see;
- has no analytics, advertising, crash-reporting or other third-party SDKs (the only
  package is the local `AudiobookshelfKit`);
- doesn't track (`NSPrivacyTracking` is false and there are no tracking domains);
- lets the user export logs with the system share sheet. The user picks where the file
  goes; nothing is uploaded automatically.

The privacy policy must say the same. Revisit the label if a feature ever sends data
anywhere other than the user's server.

## Privacy manifests

Each shipping bundle has a `PrivacyInfo.xcprivacy` in its synchronized folder, so Xcode
copies it into the bundle without a project entry:

- `Audiobookshelf/PrivacyInfo.xcprivacy` covers the app and the statically linked
  `AudiobookshelfKit` package.
- `AudiobookshelfWidgets/PrivacyInfo.xcprivacy` covers the widget extension. Its code
  (`AudiobookshelfWidgets/`, `AudiobookshelfShared/`) uses SwiftUI, WidgetKit and App
  Intents only and links no package, so it declares no required-reason APIs.

The app's required-reason APIs
([Apple's list](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)):

| Category | Reason | Where |
| --- | --- | --- |
| User defaults | `CA92.1` (the app's own data) | Settings, last-played record and queue (`ABSCore/Settings/AppSettings.swift`, `ABSPlayback/Coordinator/PlaybackCoordinatorDependencies.swift`, `ABSPlayback/Queue/PlaybackQueueStore.swift`); `.standard` is the fallback when the App Group isn't available |
| User defaults | `1C8F.1` (the App Group) | `AppSettings.sharedDefaults()` opens the `group.org.davidjensenius.Audiobookshelf` suite |
| File timestamp | `C617.1` (files in the app's own or App Group container) | Cover cache ageing (`ABSCore/Images/CoverFileStore.swift`), image size check with `stat` (`ABSCore/Images/ImageDecoder.swift`), store recovery `lstat` (`ABSData/DataStack.swift`), download bookkeeping (`ABSDownloads/DownloadEngine.swift`, `ABSDownloads/DownloadLocations.swift`, `ABSDownloads/Manager/DownloadJanitor.swift`) |
| Disk space | `E174.1` (check space before writing) | `volumeAvailableCapacityForImportantUsage` before a download (`ABSDownloads/Manager/StorageCapacity.swift`) |

Paths are under `Packages/AudiobookshelfKit/Sources/`. No code reads system boot time
(`systemUptime`, `mach_absolute_time`) or active keyboards; `ContinuousClock` and
`SuspendingClock` aren't on Apple's list. Update the manifest, and this table, when
code starts using another API on the list.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO` for the app and the widget extension
(`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` in `project.xcproj`). The setting has no
SDK condition, so it covers the iOS and macOS builds. App Store Connect then doesn't ask
the export compliance questions for each build.

`NO` is correct because the app only uses encryption built into the operating system:

- HTTPS and secure WebSockets through `URLSession`;
- the Keychain for tokens and the device identifier;
- AES-GCM through CryptoKit (`AES.GCM.seal` and `AES.GCM.open` in
  `ABSDownloads/ResumeDataVault.swift`) to protect download resume data on the device,
  with a key kept in the Keychain;
- SHA-256 (CryptoKit) to name cached files, which is hashing, not encryption.

All of these are the operating system's own cryptography. The app implements no
encryption algorithm itself and bundles no cryptographic library. If that changes, the
key and the answer have to be reviewed.

## Review notes

The reviewer can't use the app without a server. Paste this into App Review
Information › Notes, filled in:

> Audiobookshelf is a client for Audiobookshelf, a free, open-source media server that
> people run themselves (https://www.audiobookshelf.org). The app has no content or
> account system of its own: everything comes from the user's server.
>
> We've set up a demo server for review:
>
> - Server address: `<demo server URL>`
> - Username and password: in the Sign-In Information fields.
>
> On the first screen, enter the server address, then sign in. The demo library has
> public-domain audiobooks and a podcast to browse and play.

Put the username and password in App Review Information › Sign-In Information, not in
the notes and never in this repository.

## Demo server

App Review needs a working server for every submission. The maintainer runs it; no
credentials go into the repository, issues or pull requests.

- Host a current Audiobookshelf server on a public HTTPS address with a valid
  certificate (App Transport Security applies to review builds too).
- Load only public-domain or freely licensed content, for example LibriVox audiobooks
  and a podcast feed that allows it.
- Create a non-admin user for review, with access to the demo library only. Keep the
  password in App Store Connect and the maintainer's password manager.
- Keep the server up while a build is in review, and check the sign-in before each
  submission.
- Leave OpenID Connect off on the demo server, or make sure the review user can sign in
  with a password.

## Manual steps

These need the maintainer's Apple account or a signed build:

- [ ] Create the App Store Connect record (iOS and macOS), and fill in the listing,
      age rating, App Privacy answers and review information above.
- [ ] Generate the privacy report from a signed archive (Xcode Organizer › the archive
      › Generate Privacy Report), and check it matches [App privacy](#app-privacy-nutrition-label).
- [ ] Take screenshots for each required device size.
- [ ] Publish the privacy policy and support pages, and fill in their URLs.
- [ ] Set up the demo server and the review account.
