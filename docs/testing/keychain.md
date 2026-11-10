# Keychain tests

`KeychainStore` (ABSCore) keeps tokens, custom header values and the device ID in the
data-protection Keychain, never synchronised (ADR 0002). Three layers of tests cover it.

| Test | Runs in | Keychain |
| --- | --- | --- |
| `KeychainStoreTests` | `mise run test:kit` | None: checks the query and add attributes |
| `KeychainStoreRoundTripTests` | `mise run test:kit` (macOS) | The file-based login keychain (`usesDataProtectionKeychain: false`) |
| `DataProtectionKeychainTests` | The app test target | The data-protection Keychain, as the app uses it |

`AccountManager` and `ConnectionCredentials` use an in-memory fake (`InMemoryKeychain`).

## Why the data-protection test is usually skipped

The data-protection Keychain needs an `application-identifier` or `keychain-access-groups`
entitlement. Without one, every call returns `errSecMissingEntitlement` (-34018).

- `mise run test:app` signs the macOS host ad hoc with `Audiobookshelf-AdHoc.entitlements`
  (sandbox and network client only), because the keychain group needs a provisioning profile.
- `mise run test:ios` builds with `CODE_SIGNING_ALLOWED=NO`, so the simulator app has no
  entitlements.

`DataProtectionKeychainTests` probes once (adds and deletes an item). On -34018 the test is
reported as skipped with a pointer to this page; any other failure runs the test, which fails.

## Run it

Use one of these before releasing changes to `KeychainStore` or its attributes:

- **iOS simulator, signed to run locally** (no team or profile needed; the simulator honours
  the entitlements Xcode embeds):

  ```sh
  udid=$(xcrun simctl list devices available | grep -E '^ +iPhone Duo [(]' | tail -n 1 | grep -oE '[0-9A-F-]{36}')
  xcodebuild test -project Audiobookshelf.xcodeproj -scheme Audiobookshelf \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath .build/DerivedData \
    -only-testing:AudiobookshelfTests/DataProtectionKeychainTests \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  ```

- **Mac or device, signed with the team**: run the `Audiobookshelf` scheme's tests from Xcode
  with automatic signing for team 9JALHNGRBQ (or `xcodebuild test` with
  `-allowProvisioningUpdates`), so the host gets its Mac App Development or iOS profile and the
  `keychain-access-groups` entitlement.

The test passes when the item round-trips through `KeychainStore()` (nil access group) and is
stored with `kSecAttrAccessibleAfterFirstUnlock`, not synchronisable, in the app's default access
group (`<prefix>.org.davidjensenius.Audiobookshelf`). Its items (and the probe's) use services
starting with `org.davidjensenius.Audiobookshelf.tests` and random accounts, and are deleted.
