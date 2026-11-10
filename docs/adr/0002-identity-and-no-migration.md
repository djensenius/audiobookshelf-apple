# 0002. App identity and no data migration

- Status: Accepted
- Date: 2026-11-09
- Issue: [#18](https://github.com/djensenius/audiobookshelf-apple/issues/18) (P0-03)

## Context

The native app replaces the Nuxt/Capacitor app this repository was forked from. The
upstream project ([advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app))
owns the bundle ID `com.audiobookshelf.app` (and `com.audiobookshelf.app.dev`) under its
own team, and still ships it. This fork can't sign with that ID, so it can't be an update
of the legacy app on anyone's device.

Later features need shared storage and secrets: SwiftData, `AppSettings`, the image cache
and widgets use an App Group container; tokens and custom header values go in the
Keychain. Those capabilities must be registered against a fixed App ID and team.

Audiobookshelf is self-hosted. Users reach their server over HTTPS on a public host, over
plain HTTP on a LAN address or `.local` name, and often over plain HTTP on a public host
or VPN address (Tailscale, WireGuard, a port forward without TLS). The legacy app allows
all of these with `NSAllowsArbitraryLoads` (`ios/App/App/Info.plist`).

## Decision drivers

1. Users can connect to every server the legacy app can connect to.
2. Identity and capabilities are fixed before persistence, widgets and extensions depend
   on them; changing them later strands data and keychain items.
3. The server is the source of truth for progress, bookmarks and library state.
4. CI and contributors can build and test without the maintainer's signing identity.
5. App Review can accept the networking exceptions.

## Options considered

### Identity

#### Option 1: Reuse `com.audiobookshelf.app`

- Pros:
  - Would install as an update of the legacy app.
- Cons:
  - Not possible: the ID belongs to another team.

#### Option 2: New bundle ID under the maintainer's team (chosen)

- Pros:
  - Fully under this project's control; one ID for iOS and macOS (universal purchase).
- Cons:
  - Installs as a separate app; nothing carries over from the legacy app.

### Legacy data

#### Option 1: Migrate legacy data

- Pros:
  - Users would keep server list, settings and downloads.
- Cons:
  - Impossible across bundle IDs and teams: the new app can't read the legacy app's
    container, Capacitor storage or keychain items, and the two apps share no App Group.
  - Even if possible, porting the Capacitor and Realm (`ios/App/App/plugins/AbsDatabase.swift`)
    storage formats is a large one-off cost.

#### Option 2: No migration (chosen)

- Pros:
  - No legacy storage code; the schema starts clean (ADR 0003).
- Cons:
  - Users sign in again and re-download offline items.

### Plain HTTP (ATS)

#### Option 1: HTTPS only, plus `NSAllowsLocalNetworking`

- Pros:
  - Strongest default; no App Review justification needed.
- Cons:
  - Breaks plain-HTTP servers on public hosts and VPN addresses (Tailscale `100.x`
    addresses are not "local" to ATS), which the legacy app supports.

#### Option 2: Per-domain `NSExceptionDomains`

- Cons:
  - Server hosts are user-entered and unknown at build time; not workable.

#### Option 3: `NSAllowsArbitraryLoads` (chosen)

- Pros:
  - Parity with the legacy app; covers `URLSession`, AVFoundation streaming and
    `WKWebView` (EPUB reader).
- Cons:
  - Plain-HTTP traffic is possible to any host, so the app must warn about it, and App
    Review asks for a justification.

## Decision

**Identity.**

| Item | Value |
| --- | --- |
| Bundle ID (app, iOS and macOS) | `org.davidjensenius.Audiobookshelf` |
| Bundle ID (app tests) | `org.davidjensenius.AudiobookshelfTests` |
| Team | `9JALHNGRBQ`, automatic signing for Debug and Release (Xcode Cloud manages distribution signing) |
| App Group | `group.org.davidjensenius.Audiobookshelf` (iOS and macOS) |
| Keychain access group | `$(AppIdentifierPrefix)org.davidjensenius.Audiobookshelf` |
| App category | Books (`public.app-category.books`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` (only OS-provided TLS) |

Entitlements:

- `Audiobookshelf/Audiobookshelf-iOS.entitlements` (`iphoneos`, `iphonesimulator`): App
  Group and keychain access group. CarPlay goes here once Apple grants it.
- `Audiobookshelf/Audiobookshelf.entitlements` (`macosx`): App Sandbox, network client,
  App Group and keychain access group.
- `Audiobookshelf/Audiobookshelf-AdHoc.entitlements`: App Sandbox and network client only.
  Used only by `mise run test:app`, which signs the macOS test host ad hoc with no team.
  App Group and keychain access group entitlements need a provisioning profile; an ad hoc
  signed app that claims them is killed at launch, so the ad hoc host doesn't claim them.

iOS background audio (`UIBackgroundModes` = `audio`) stays in the `Info.plist` fragment.

**No data migration.** The app does not read, import or detect anything from the legacy
app. The server holds progress, bookmarks and library state, so signing in restores them.
Offline downloads must be downloaded again, and local-only settings set again. Release
notes and the App Store description say so.

**Networking policy.**

- `NSAppTransportSecurity` sets only `NSAllowsArbitraryLoads = YES` (in the `Info.plist`
  fragment, applies to iOS and macOS). `NSAllowsLocalNetworking` is deliberately **not**
  set: when it is present, iOS and macOS ignore `NSAllowsArbitraryLoads` and fall back to
  HTTPS-only for non-local hosts. Arbitrary loads already cover local hosts.
- The app shows an "insecure connection" warning when a user adds an `http://` server on a
  non-local host (server connect UI,
  [#40](https://github.com/djensenius/audiobookshelf-apple/issues/40)).
- `NSLocalNetworkUsageDescription` (build setting `INFOPLIST_KEY_NSLocalNetworkUsageDescription`)
  explains why the app talks to LAN servers and `.local` names. `NSBonjourServices` is not
  set: the app doesn't browse for services.
- Local network permission denied: the system prompts on the first connection to a local
  host, so the app doesn't connect to local hosts before the user asks it to. When a
  request to a local host (private, link-local or unique-local address, or a `.local`
  name) fails with a connectivity error, the app checks a Network framework path to that
  host; an unsatisfied path with reason `localNetworkDenied` means the permission is off.
  The app then explains this and links to Settings (iOS) or System Settings › Privacy &
  Security › Local Network (macOS), and retries when the app becomes active again.
  Detection belongs to the network monitor in
  [#39](https://github.com/djensenius/audiobookshelf-apple/issues/39) (P1-16); the
  message and Settings link to the server connect UI in
  [#40](https://github.com/djensenius/audiobookshelf-apple/issues/40).

**App Review note** (App Store Connect › App Review Information): "Audiobookshelf connects
to the user's own self-hosted Audiobookshelf server, whose address the user enters. Many
users run the server at home or over a VPN without TLS, so the app allows plain-HTTP
connections (NSAllowsArbitraryLoads) and warns the user when a connection is not
encrypted." Add a reachable demo server URL and account to the same section.

## Consequences

- Code that uses the App Group (`UserDefaults(suiteName:)`, `FileManager.containerURL(
  forSecurityApplicationGroupIdentifier:)`) must handle the container being unavailable
  (the ad hoc test host has no App Group entitlement) by falling back to the app's own
  container, not by crashing.
- Keychain code sets `kSecAttrAccessGroup` to the shared group and, on macOS,
  `kSecUseDataProtectionKeychain = true`, so the same group works on both platforms and in
  later extensions. Keychain-dependent tests belong in package tests with an injected
  store, not in the ad hoc signed app host.
- Widgets and other extensions (later issues) add the same App Group and keychain group
  to their own entitlements files.
- Changing the bundle ID, team, App Group or keychain group later loses user data and
  sign-ins; it needs a new ADR.
- `test:app` must keep overriding `CODE_SIGN_ENTITLEMENTS` while it signs ad hoc. CI
  builds (`build:ios`, `build:macos`, `test:ios`) don't sign (`CODE_SIGNING_ALLOWED=NO`),
  so they don't need the team.

## Validation

- CI: `mise run xcproj:check`, `build:ios`, `build:macos` (unsigned) and `test:app` (ad
  hoc signed with the ad hoc entitlements).
- `xcodebuild -showBuildSettings` resolves `CODE_SIGN_ENTITLEMENTS` to the iOS file for
  `iphoneos`, the macOS file for `macosx`, and the ad hoc file under the `test:app`
  overrides; `DEVELOPMENT_TEAM` resolves to `9JALHNGRBQ`.
- Signed Debug runs on an iPhone and a Mac are performed by the maintainer in
  [#18](https://github.com/djensenius/audiobookshelf-apple/issues/18) (checklist below).
- The local-network-denied flow is validated on device in
  [#39](https://github.com/djensenius/audiobookshelf-apple/issues/39) and
  [#40](https://github.com/djensenius/audiobookshelf-apple/issues/40).

### Maintainer checklist

- [ ] In the Apple Developer portal (team `9JALHNGRBQ`), register the explicit App ID
      `org.davidjensenius.Audiobookshelf` for iOS and macOS with the App Groups capability
      (or let Xcode's automatic signing register it, then check it in the portal).
- [ ] Register the App Group `group.org.davidjensenius.Audiobookshelf` and assign it to
      the App ID.
- [ ] Create the App Store Connect record for `org.davidjensenius.Audiobookshelf` with iOS
      and macOS platforms, primary category Books, and the App Review note above.
- [ ] Run a signed Debug build on an iPhone and on a Mac; confirm both launch and that the
      provisioning profiles contain the App Group and keychain access group.

## References

- Legacy: `ios/App/App.xcodeproj/project.pbxproj` (team `7UFJ7D8V6A`,
  `com.audiobookshelf.app`), `ios/App/App/Info.plist` (`NSAllowsArbitraryLoads`),
  `capacitor.config.json` (`appId`)
- [ADR 0001](0001-architecture.md) (Keychain and settings live in `ABSCore`)
- Apple: [NSAppTransportSecurity](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity),
  [NSAllowsArbitraryLoads](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads),
  [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription),
  [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy),
  [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups),
  [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
