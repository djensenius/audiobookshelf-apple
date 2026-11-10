# Xcode 27.2 JSON project format: verified skeleton and CI research for audiobookshelf-apple

## 1. Summary

- **Hand-written JSON works.** A hand-authored `project.xcproj` builds with Xcode 27.2 (27B52) for iOS Simulator and macOS, and the app unit tests pass on macOS and on iPhone Duo. `swift test` passes for the local package.
- **Conversion works.** `xcodebuild -convert-project "Xcode Project" -project X.xcodeproj` converts a `.pbxproj` to JSON in place.
- **`xcprojformatter`** builds in about 18 s and produces output identical to Xcode's canonical form. It has no `--verify` flag, so CI diffs its stdout against the file.
- **GitHub Actions has Xcode 27.2.** The `xcode-27` runner image (arm64 only, now GA) has `/Applications/Xcode_27.2.app` (27B52). The default Xcode on that image is 27.1, so you must select 27.2. The `macos-26` images stop at Xcode 26.6.
- **Xcode Cloud caveats.** I found no Apple statement on Xcode Cloud support for `.xcproj` or for Xcode 27.2. Its custom-script mechanism is documented and `mise` is installable there (see section 6). **`agvtool` breaks JSON projects** (section 3).
- **iPhone Duo** is `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`. Its dedicated iOS 27.2 runtime is installed locally.
- **`swift format`** ships with the toolchain (`swift format --version` printed `6.4.4`).

Use this prefix for every command below:

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

---

## 2. Item 1: JSON project format

### Sources

- Apple, "Updating your Xcode project configuration file format" (availability "Xcode: 27.2.0 –").
  - In 27.2 and later, the default project configuration file is `project.xcproj`. It is JSON5, so trailing commas and comments are allowed.
  - "The JSON file format `.xcproj` is compatible with Xcode 27 and later."
  - To revert, delete the `.xcproj` and restore the `.pbxproj` from source control.
- Xcode 27.2 release notes ("Project Format"): "Enable it in the File inspector. Projects using `.xcproj` also open in earlier versions of Xcode 27."
- `apple/xcode-project-format` at `0a7242a` (Oct 2 2026):
  - Swift tools 6.1.
  - The `XcodeProjectFormat` library and the `xcprojformatter` executable.
  - Docs in `Sources/Library/XcodeProjectFormat.docc/Docs/{file-format-goals,schema-overview,package-layout}.md`.
  - Schema in `Sources/Library/Schema/**`.
- The repo has no `.pbxproj`-to-JSON fixtures, only `TestInstances.swift`. The schema sources and `xcodebuild -convert-project` output were my reference.

### (a) Conversion

- `xcodebuild -help` lists `-convert-project FORMAT`.
- Valid FORMAT values (from the tool's error message): `Xcode 2.4, 3.0, 3.1, 3.2, 6.3, 8.0, 9.0, 9.3, 10.0, 11.0, 11.4, 12.0, 13.0, 14.0, 15.0, 15.3, 16.0, 16.3, 26.3, 27.0` and `Xcode Project`.
- `"Xcode Project"` produces JSON `project.xcproj`.

```
xcodebuild -convert-project "Xcode Project" -project App.xcodeproj    # pbxproj -> JSON
xcodebuild -convert-project "Xcode 16.0"    -project App.xcodeproj    # JSON -> pbxproj (objectVersion 110)
```

- Conversion is in place and deletes the old file.
- Converting the Capacitor repo's `App.xcodeproj` (a copy, not the original) took a 48 KB pbxproj to a 16.7 KB xcproj.
- Schemes stay as XML in `xcshareddata/xcschemes`.
- Round trip: hand-written JSON → "Xcode 16.0" → "Xcode Project" yields the canonical form. The only differences were whitespace and an auto-dropped `supported: ["en"]`.

### (b) Hand-written JSON

Verified working.

### Build and test results (final skeleton, fresh copy, `-derivedDataPath` in scratch)

| Command | Result |
|---|---|
| `xcodebuild -list -project Audiobookshelf.xcodeproj` | Parsed. Targets: Audiobookshelf, AudiobookshelfTests. Configs: Debug, Release. Schemes: Audiobookshelf, plus the auto-generated AudiobookshelfKit. |
| `xcodebuild build -project Audiobookshelf.xcodeproj -scheme Audiobookshelf -destination 'generic/platform=iOS Simulator' -derivedDataPath <dd> CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED (12 s) |
| Same with `-destination 'platform=macOS'` | BUILD SUCCEEDED |
| `xcodebuild test ... -destination 'platform=macOS'` | TEST SUCCEEDED; `ContentViewTests` 2/2 passed |
| `xcodebuild test ... -destination 'platform=iOS Simulator,id=497F0F11-822C-4E83-9BE7-188FF2E656FE'` (iPhone Duo) | TEST SUCCEEDED (about 100 s, ran in a cloned simulator) |
| `cd Packages/AudiobookshelfKit && swift test --scratch-path <tmp>` | 3 Swift Testing tests passed. Built binary minos is 27.0. |
| `cd Packages/AudiobookshelfKit && xcodebuild test -scheme AudiobookshelfKit -destination 'platform=macOS'` | Package tests passed (Swift Testing output) |

The only warning in all builds was a harmless `appintentsmetadataprocessor: no AppIntents.framework dependency`.

### Verified findings and caveats

1. **The file must be named exactly `project.xcproj`.** Renaming it to `foo.xcproj` gave: `The project … does not contain a project definition file`.
2. **Only one definition file may exist.** If both exist, xcodebuild fails with: `has multiple project definition files, and is invalid. Only one of project.xcproj or project.pbxproj should exist.`
3. **`agvtool` is broken with JSON projects.** `agvtool new-version -all 42` printed `sed: …/project.pbxproj: No such file or directory`, left `CURRENT_PROJECT_VERSION` unchanged, and created an empty `project.pbxproj`. That empty file then breaks the project by triggering caveat 2. Do not use `agvtool` in CI. Set the build number by editing `project.xcproj` as text (untested) or rely on Xcode Cloud's own build number (section 6).
4. **Shared scheme.**
   - With `xcshareddata` removed, `xcodebuild -list` still showed an implicit `Audiobookshelf` scheme, so local builds would still work.
   - I still recommend committing the shared scheme. Xcode Cloud needs a shared scheme, but I did not verify that against Apple docs.
   - Scheme XML references targets by `BlueprintIdentifier`, which equals the `"id"` in `project.xcproj`. My IDs are the fixed strings `AB0000000000000000000001` and `AB0000000000000000000002`.
5. **Package test target in the app scheme does not work.**
   - I added a `TestableReference` with `ReferencedContainer="container:Packages/AudiobookshelfKit"`.
   - The macOS test run silently skipped those tests.
   - `-only-testing:AudiobookshelfKitTests` failed with `isn't a member of the specified test plan or scheme`.
   - `xcodebuild test -scheme AudiobookshelfKit` from the project dir also failed: `Scheme AudiobookshelfKit is not currently configured for the test action`.
   - Run package tests via `swift test`, or via `xcodebuild test -scheme AudiobookshelfKit` run inside `Packages/AudiobookshelfKit` (verified). I reverted the scheme edit.
6. **`INFOPLIST_KEY_UIBackgroundModes` is not emitted** into the built Info.plist (verified absent).
   - Fix: use `GENERATE_INFOPLIST_FILE=YES` plus `INFOPLIST_FILE=Audiobookshelf/Info.plist`. The partial plist merges.
   - The built plist had `UIBackgroundModes=[audio]` and the CarPlay `UISceneConfigurations`.
   - When the fragment supplies `UIApplicationSceneManifest`, drop `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`.
   - Exclude the fragment from the synchronized folder via `membership-exceptions` (included in the skeleton). I did not test omitting the exception.
   - Properly emitted `INFOPLIST_KEY_*` keys: `CFBundleDisplayName`, `LSApplicationCategoryType`, `UILaunchScreen_Generation`, `UISupportedInterfaceOrientations[_iPad]`, `UIApplicationSupportsIndirectInputEvents`.
7. **Xcode drops entitlements exclusions.** Xcode drops `membership-exceptions` for `*.entitlements` inside synchronized folders on canonicalization. They are auto-ignored, so no exception is needed.
8. **Canonicalization and format quirks.**
   - Xcode and `xcprojformatter` rewrite your file to the same canonical form: multi-line, trailing commas, `supported` dropped when it equals the development language.
   - `package-product-members[].build-phase` must be the nested object `{ "build-phase": "frameworks" }`. A bare string gives a decode error with a JSON path.
   - Build-setting conditionals use `"KEY[config=Debug]"` and `"KEY[sdk=macosx*]"`. Values can be a string or an array of strings.
   - Xcode auto-creates an empty `project.xcworkspace/xcshareddata/swiftpm/configuration`. It is not needed in git.
9. **Swift language modes available** in this toolchain: 4, 4.2, 5, 6. Swift 6 mode (`SWIFT_VERSION = 6.0`) plus `SWIFT_STRICT_CONCURRENCY = complete` works. In Swift 6 mode, `StrictConcurrency` is redundant but accepted. I did not set `SWIFT_APPROACHABLE_CONCURRENCY` or `SWIFT_DEFAULT_ACTOR_ISOLATION`.
10. **Placeholders.** `com.example.Audiobookshelf` is a placeholder bundle ID. No signing team is set.
11. **`swift-tools-version: 6.4`** is verified with Xcode 27.2 (Swift 6.4.2). I did not test whether older Xcode 27.x toolchains accept it.

### Final skeleton file contents (all verified; layout below)

```
.swift-format
Audiobookshelf.xcodeproj/project.xcproj
Audiobookshelf.xcodeproj/xcshareddata/xcschemes/Audiobookshelf.xcscheme
Audiobookshelf/AudiobookshelfApp.swift
Audiobookshelf/ContentView.swift
Audiobookshelf/Audiobookshelf.entitlements
Audiobookshelf/Info.plist
AudiobookshelfTests/ContentViewTests.swift
Packages/AudiobookshelfKit/Package.swift
Packages/AudiobookshelfKit/Sources/AudiobookshelfKit/ServerAddress.swift
Packages/AudiobookshelfKit/Tests/AudiobookshelfKitTests/ServerAddressTests.swift
```

**`Audiobookshelf.xcodeproj/project.xcproj`** (canonical form, byte-identical to `xcprojformatter` output):

```json5
{
  "default-configuration": "Release",
  "configurations": [
    "Debug",
    "Release",
  ],
  "localizations": {
    "development": "en",
  },
  "packages": [
    {
      "kind": "local",
      "path": "Packages/AudiobookshelfKit",
    },
  ],
  "files": [
    {
      "kind": "folder",
      "path": "Audiobookshelf",
      "target-membership": [
        "Audiobookshelf",
      ],
      "membership-exceptions": [
        {
          "target": "Audiobookshelf",
          "exclusions": [
            "Info.plist",
          ],
        },
      ],
    },
    { "kind": "folder", "path": "AudiobookshelfTests", "target-membership": [ "AudiobookshelfTests" ] },
    {
      "kind": "group",
      "name": "Products",
      "children": [
        { "path": "<PRODUCTS>/Audiobookshelf.app", "id": "AB0000000000000000000011", "type": "wrapper.application", "index": false },
        { "path": "<PRODUCTS>/AudiobookshelfTests.xctest", "id": "AB0000000000000000000012", "type": "wrapper.cfbundle", "index": false },
      ],
    },
  ],
  "targets": [
    {
      "name": "Audiobookshelf",
      "id": "AB0000000000000000000001",
      "product": "Products/Audiobookshelf.app",
      "product-type": "application",
      "build-phases": [
        "compile-sources",
        "frameworks",
        "resources",
      ],
      "package-product-members": [
        {
          "package": "AudiobookshelfKit",
          "product-name": "AudiobookshelfKit",
          "build-phase": { "build-phase": "frameworks" },
        },
      ],
      "build-settings": {
        "CODE_SIGN_ENTITLEMENTS": "Audiobookshelf/Audiobookshelf.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "Audiobookshelf/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "Audiobookshelf",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.entertainment",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "LD_RUNPATH_SEARCH_PATHS": [
          "$(inherited)",
          "@executable_path/Frameworks",
        ],
        "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": [
          "$(inherited)",
          "@executable_path/../Frameworks",
        ],
        "MARKETING_VERSION": "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Audiobookshelf",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "auto",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "1,2",
      },
    }, {
      "name": "AudiobookshelfTests",
      "id": "AB0000000000000000000002",
      "product": "Products/AudiobookshelfTests.xctest",
      "product-type": "bundle.unit-test",
      "test-host-target": "Audiobookshelf",
      "dependencies": [
        "Audiobookshelf",
      ],
      "build-phases": [
        "compile-sources",
        "frameworks",
        "resources",
      ],
      "build-settings": {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.AudiobookshelfTests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "auto",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Audiobookshelf.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Audiobookshelf",
      },
    },
  ],
  "build-settings": {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT[config=Debug]": "dwarf",
    "DEBUG_INFORMATION_FORMAT[config=Release]": "dwarf-with-dsym",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_TESTABILITY[config=Debug]": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "27.0",
    "MACOSX_DEPLOYMENT_TARGET": "27.0",
    "ONLY_ACTIVE_ARCH[config=Debug]": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG",
    "SWIFT_COMPILATION_MODE[config=Release]": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL[config=Debug]": "-Onone",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
    "VALIDATE_PRODUCT[config=Release]": "YES",
  },
  "last-upgrade": "27.2",
}
```

**`Audiobookshelf.xcodeproj/xcshareddata/xcschemes/Audiobookshelf.xcscheme`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2720"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "AB0000000000000000000001"
               BuildableName = "Audiobookshelf.app"
               BlueprintName = "Audiobookshelf"
               ReferencedContainer = "container:Audiobookshelf.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "AB0000000000000000000002"
               BuildableName = "AudiobookshelfTests.xctest"
               BlueprintName = "AudiobookshelfTests"
               ReferencedContainer = "container:Audiobookshelf.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "AB0000000000000000000001"
            BuildableName = "Audiobookshelf.app"
            BlueprintName = "Audiobookshelf"
            ReferencedContainer = "container:Audiobookshelf.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "AB0000000000000000000001"
            BuildableName = "Audiobookshelf.app"
            BlueprintName = "Audiobookshelf"
            ReferencedContainer = "container:Audiobookshelf.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

**`Audiobookshelf/AudiobookshelfApp.swift`:**

```swift
import SwiftUI

@main
struct AudiobookshelfApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

**`Audiobookshelf/ContentView.swift`:**

```swift
import AudiobookshelfKit
import SwiftUI

struct ContentView: View {
    @State private var input = "abs.example.com"

    var normalized: String {
        ServerAddress(input)?.url.absoluteString ?? "invalid"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "headphones")
                .imageScale(.large)
            TextField("Server", text: $input)
            Text(normalized)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
```

**`Audiobookshelf/Audiobookshelf.entitlements`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
```

**`Audiobookshelf/Info.plist`** (partial fragment, merged by `GENERATE_INFOPLIST_FILE`). The `CarPlaySceneDelegate` class does not exist yet; it was only checked as a string in the built plist.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
	</array>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key>
		<true/>
		<key>UISceneConfigurations</key>
		<dict>
			<key>CPTemplateApplicationSceneSessionRoleApplication</key>
			<array>
				<dict>
					<key>UISceneClassName</key>
					<string>CPTemplateApplicationScene</string>
					<key>UISceneConfigurationName</key>
					<string>CarPlay</string>
					<key>UISceneDelegateClassName</key>
					<string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
				</dict>
			</array>
		</dict>
	</dict>
</dict>
</plist>
```

**`AudiobookshelfTests/ContentViewTests.swift`:**

```swift
import AudiobookshelfKit
import SwiftUI
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct ContentViewTests {
    @Test func normalizesDefaultInput() {
        let view = ContentView()
        #expect(view.normalized == "https://abs.example.com")
    }

    @Test func kitIsLinked() {
        #expect(ServerAddress("http://localhost:13378") != nil)
    }
}
```

**`Packages/AudiobookshelfKit/Package.swift`:**

```swift
// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "AudiobookshelfKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
    ],
    products: [
        .library(name: "AudiobookshelfKit", targets: ["AudiobookshelfKit"])
    ],
    targets: [
        .target(
            name: "AudiobookshelfKit",
            swiftSettings: [
                // Redundant in Swift 6 language mode, but explicit.
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "AudiobookshelfKitTests",
            dependencies: ["AudiobookshelfKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

**`Packages/AudiobookshelfKit/Sources/AudiobookshelfKit/ServerAddress.swift`:**

```swift
import Foundation

/// A normalised Audiobookshelf server address (scheme + host [+ port], no trailing slash).
public struct ServerAddress: Sendable, Hashable {
    public let url: URL

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else { return nil }
        if components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return nil }
        self.url = url
    }
}
```

**`Packages/AudiobookshelfKit/Tests/AudiobookshelfKitTests/ServerAddressTests.swift`:**

```swift
import Testing

@testable import AudiobookshelfKit

@Suite struct ServerAddressTests {
    @Test func addsHTTPSWhenSchemeMissing() throws {
        let address = try #require(ServerAddress("abs.example.com"))
        #expect(address.url.absoluteString == "https://abs.example.com")
    }

    @Test func stripsTrailingSlash() throws {
        let address = try #require(ServerAddress("http://10.0.0.2:13378/"))
        #expect(address.url.absoluteString == "http://10.0.0.2:13378")
    }

    @Test(arguments: ["", "   ", "ftp://example.com"])
    func rejectsInvalid(_ input: String) {
        #expect(ServerAddress(input) == nil)
    }
}
```

**`.swift-format`** (repo root; section 7):

```json
{
  "version": 1,
  "indentation": { "spaces": 4 },
  "lineLength": 120,
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeEachArgument": false,
  "multiElementCollectionTrailingCommas": true,
  "rules": {
    "AlwaysUseLowerCamelCase": true,
    "OrderedImports": true,
    "NeverForceUnwrap": false,
    "NeverUseForceTry": false,
    "NeverUseImplicitlyUnwrappedOptionals": false,
    "AllPublicDeclarationsHaveDocumentation": false,
    "UseLetInEveryBoundCaseVariable": false,
    "UseSynthesizedInitializer": false
  }
}
```

---

## 3. Item 2: `xcprojformatter` for CI

Built from `apple/xcode-project-format` (commit `0a7242a`):

```
git clone --depth 1 https://github.com/apple/xcode-project-format
cd xcode-project-format
swift build -c release --product xcprojformatter
# → .build/release/xcprojformatter, about 2 MB, build time about 18 s
```

The repo has no git tags (`git tag` printed nothing). I did not check GitHub Releases for prebuilt binaries.

Usage, from `--help` and `Sources/Tool/{Help,Arguments}.swift`:

```
xcprojformatter [[--input] path] [--output path]
xcprojformatter --update path        # in place
xcprojformatter                      # stdin → stdout
```

A path may be the `.xcodeproj` directory or the inner `project.xcproj`. Everything below was verified:

- **Output equals Xcode's canonical form.** The stdout of `xcprojformatter` on my hand-written file was byte-identical to the Xcode round-trip output.
- **Idempotent.** A second run on its own output produced no change.
- **Input forms.** Stdin and inner-path input produce the same result.
- **`--update`** rewrites the file canonically in place.
- **Invalid input fails.**
  - A file missing required keys printed `Missing required value for key “default-configuration” at “”`, then the help text, and exited with 255.
  - A malformed file printed `The data couldn’t be read because it isn’t in the correct format.` and exited with 255.
  - The tool is therefore a syntax and schema validator, not a semantic one. Upstream issue #22 asks for semantic validation.
- **No `--verify` flag.** Upstream issue #20 requests one, and it is still open.
- **Comments.** I did not test whether JSON5 comments survive formatting. Since the tool decodes and re-encodes, assume they are dropped.

CI check. Run the formatter and `diff` as separate steps, so a formatter failure
(exit 255 on invalid input) fails the check. In a plain pipeline the shell reports
only `diff`'s status, so an empty project file would pass (both inputs empty):

```sh
canonical="$(mktemp)"
xcprojformatter Audiobookshelf.xcodeproj >"$canonical" || exit 1
diff -u Audiobookshelf.xcodeproj/project.xcproj "$canonical"
# or auto-fix: xcprojformatter --update Audiobookshelf.xcodeproj
```

I did not verify installing `xcprojformatter` via mise (for example the `spm:` backend), and the repo has no tags to resolve. Practical options are to build it in about 18 s with a cached `.build`, or to pin a commit SHA in a helper script.

---

## 4. Item 3: GitHub Actions

Sources: `actions/runner-images` README (image table), `images/macos/xcode-27-arm64-Readme.md`, `images/macos/toolsets/toolset-xcode-27.json:1-24`, issue #14404, and the GitHub changelog "Xcode 27 runner image generally available" (Oct 15 2026).

- **Label.** `runs-on: xcode-27` (or `xcode-27-xlarge`). It is arm64 only and GA. The GA changelog says each image targets one major Xcode version.
- **Image used for this check.** README header: macOS 27.0.1 (26A434), image version 20261104.0337.1. Issue #14404 says the base OS became macOS 27 on 2026.09.16.
- **Installed Xcodes.** From the readme "Xcode" table (about lines 155-160, ±1):

  | Version | Build | Path |
  |---|---|---|
  | 27.2 | 27B52 | `/Applications/Xcode_27.2.app` (symlink `Xcode_27.2.0.app`) |
  | 27.1 (default) | 27A9275 | `/Applications/Xcode_27.1.app` (also `/Applications/Xcode.app`) |
  | 27.0 | 27A266a | `/Applications/Xcode_27.app` |

- **Toolset JSON.** `toolset-xcode-27.json:1-24` has `"default": "27.1"` with 27.2 (`27.2+27B52`), 27.1 and 27.0 listed, all with `"install_runtimes": "default"`.
- **SDKs and simulators.** SDKs for 27.0, 27.1 and 27.2 are installed. Simulators include iOS 27.0 and 27.2 (iPhone 17, 17e, 18 Pro, 18 Pro Max, Air, iPad, iPad Air, iPad mini, iPad Pro) and an iPhone Duo entry under both iOS 27.1 and iOS 27.2.
- **Other tools on the image.**
  - `Xcodes 2.1.0`, `Xcbeautify 3.2.1`, `Fastlane 2.241.2`, `SwiftFormat 0.64.5` (the nicklockwood tool), Homebrew 7.0.12, `gh`.
  - `mise` is NOT listed (0 matches).
- **`macos-26`, `macos-15` and `macos-latest`** (`macos-26`, image 20261102) carry Xcode 26.6 at most. They cannot build a 27.0 deployment target.

Selecting Xcode 27.2 (the readme and toolset support the paths; I could not run a GitHub-hosted job from here, so this exact YAML is unverified):

```yaml
jobs:
  build:
    runs-on: xcode-27
    env:
      DEVELOPER_DIR: /Applications/Xcode_27.2.app/Contents/Developer
    steps:
      - uses: actions/checkout@v7          # v7.0.1 is the latest release tag I saw
      - run: xcodebuild -version
      - run: swift format lint --strict --recursive --parallel .
      # or: sudo xcode-select -s /Applications/Xcode_27.2.app
```

`maxim-lobanov/setup-xcode@v1` (latest tag v1.7.0) is the alternative: `with: { xcode-version: '27.2' }`.

- Its README documents semver strings such as `26.3`, with the version in single quotes.
- It reads the images' `/Applications/Xcode_*.app` installs. I did not confirm it works on the non-`macos-*` label `xcode-27`, so prefer `DEVELOPER_DIR`.
- `jdx/mise-action@v5` (v5.2.7) exists if you want `mise install` in Actions.

Fallbacks if 27.2 is unavailable (for example a private-repo minutes concern or the preview label):
1. Run `swift build/test` and `swift format lint` only for `Packages/AudiobookshelfKit`. This needs a Swift 6.4 toolchain, which is part of Xcode 27.2. Unless the 27.1 toolchain also accepts tools-version 6.4 (not tested), lower the Package tools version.
2. Use a self-hosted Mac with Xcode 27.2.
3. Use Xcode Cloud for the app build and test, and keep GitHub Actions for lint and package tests.

---

## 5. Item 4: Xcode Cloud

Official docs read, from developer.apple.com/documentation/xcode: "Writing custom build scripts", "Environment variable reference", "Making dependencies available to Xcode Cloud", "Setting the next build number for Xcode Cloud builds", "Building Swift packages or apps that use them in continuous integration workflows", and "Xcode Cloud workflow reference".

**JSON `.xcproj` and Xcode 27.2: not confirmed.**
- I found no Apple statement either way.
- The Xcode Cloud release-notes page I fetched had no entry newer than Feb 10 2026. It may be a stale cache, so it neither confirms nor excludes Xcode 27.x.
- The only compatibility note is "Projects using `.xcproj` also open in earlier versions of Xcode 27."
- Check the Environment picker in the workflow editor (Xcode or App Store Connect). If Xcode 27.2 is absent, convert back to pbxproj with `xcodebuild -convert-project "Xcode 16.0"`.
- Verify the setup on the first Xcode Cloud run.

**Local Swift packages.**
- Apple's CI doc says "Xcode Cloud requires the package to be part of a project or workspace." Our local package is referenced from the project, so that applies.
- `Package.resolved` is only needed for remote dependencies. If you add any, commit it at `<Name>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Xcode Cloud disables automatic package resolution.

**`ci_scripts`.**
- Put the directory next to the Xcode project, which here means the repo root.
- Script names (top level only): `ci_post_clone.sh`, `ci_pre_xcodebuild.sh`, `ci_post_xcodebuild.sh`.
- Use `chmod +x` and a shebang, otherwise they run as `zsh <file>`.
- No `sudo`. Files created by one script are not available to the others.
- `ci_post_xcodebuild.sh` runs even if the build fails.

**Environment variables.**
- Always available: `CI`, `CI_XCODE_CLOUD`, `CI_BUILD_NUMBER` (an integer such as `42`), `CI_BUILD_ID`, `CI_COMMIT`, `CI_PRIMARY_REPOSITORY_PATH`, `CI_PROJECT_FILE_PATH`, `CI_XCODE_PROJECT`, `CI_XCODE_SCHEME`, `CI_XCODEBUILD_ACTION`, `CI_BUNDLE_ID`, `CI_TEAM_ID`.
- Test actions also get `CI_TEST_DESTINATION_*` and `CI_RESULT_BUNDLE_PATH`.

**Build numbers.**
- Xcode Cloud assigns an auto-incrementing integer build number starting at 1. App Store Connect and TestFlight use it.
- You can set the next build number in App Store Connect, under Xcode Cloud > Settings > Build Number.
- `agvtool` is unusable with JSON projects (section 2, finding 3).
- If an explicit `CURRENT_PROJECT_VERSION` is wanted, a `sed` edit of `project.xcproj` in `ci_post_clone.sh` should work. I did not test it, nor whether Xcode Cloud overwrites the build number itself.

**`mise` in Xcode Cloud.**
- Apple documents Homebrew as preinstalled, and says "third-party tools … aren't included."
- Real repos install mise in `ci_post_clone.sh` with `curl https://mise.run | sh` followed by `export PATH="$HOME/.local/bin:$PATH"` and `eval "$(mise activate bash --shims)"`.
  - `Infomaniak/ios-kDrive:ci_scripts/ci_post_clone.sh:4-13` does this.
  - `HedvigInsurance/ugglan:ci_scripts/ci_post_clone.sh:14-19` does the same.
  - `ZUM-Internet/iOS-DemoProject:ci_scripts/tuist_install.sh:1-3` uses `brew install mise`.
- Each `ci_*.sh` script runs in its own shell, so `export`ed variables and `mise activate` from `ci_post_clone.sh` do not carry over to `ci_pre_xcodebuild.sh` or `ci_post_xcodebuild.sh`, and build phases never see them. Re-run the PATH setup (or call `~/.local/bin/mise` by absolute path) in every script that needs it. Files written to disk (such as the installed binary) do persist within the same build. This is from the documented script model; I did not run it on Xcode Cloud.
- The Xcode Cloud release notes (Sep 2025) record a Homebrew install failure on macOS beta (26) environments, so use stable macOS environments.
- Since the app uses only built-in frameworks and local SPM, you may not need `ci_post_clone.sh` at all.

---

## 6. Item 5: iPhone Duo simulator

Verified locally:

```
$ xcrun simctl list devicetypes | grep -i duo
iPhone Duo (com.apple.CoreSimulator.SimDeviceType.iPhone-Duo)

$ xcrun simctl list runtimes | grep -E "iOS 27.2"
iOS 27.2 (27.2 - 24B8117)    - com.apple.CoreSimulator.SimRuntime.iOS-27-2
iOS 27.2 (27.2 - 24B91016s)  - com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4
```

- **Device type.** The model identifier is `iPhone19,4` and the minimum runtime is 27.1.0. The Duo-specific runtime `iOS-27-2-iPhone19-4` is installed alongside the regular iOS 27.2 runtime, and it supports only the iPhone Duo device type.
- **Local simulators.** Two iPhone Duo simulators exist, with UDIDs `14905026-EB42-4DB6-92FC-99A5FDA8D31D` and `497F0F11-822C-4E83-9BE7-188FF2E656FE`. Both are Shutdown.
- **Destination.** Because two Duos exist locally, `name=iPhone Duo,OS=27.2` failed with "multiple devices matched". Use the UDID:
  - `-destination 'platform=iOS Simulator,id=497F0F11-822C-4E83-9BE7-188FF2E656FE'`.
  - Tests passed on it (xcodebuild made a "Clone 1 of iPhone Duo").
  - On a fresh runner with a single Duo, the name form should work (not verified).
- **GitHub runner.** The `xcode-27` image lists iPhone Duo under iOS 27.1 and 27.2.
- **Xcode 27.1 and 27.2 release notes (known issues):**
  - StandBy is unavailable in the Duo simulator runtime (27.1; 27.2 notes added StandBy support in Device Hub).
  - Running and debugging most app extensions is unavailable in the Duo simulator runtime.
  - Screenshots and recordings can be black for a few minutes after boot.
  - Device Hub CarPlay support needs a USB-connected device ("iOS Simulator is not supported for CarPlay").
- **Other runtimes installed locally:** iOS 26.5, 27.0, 27.1 and 27.2; tvOS, watchOS and visionOS 26.5, 27.0 and 27.2. The iPad (A16) iOS 26.5 simulator is ineligible for a 27.0 deployment target.
- **Test run noise.** Xcodebuild printed `xcrun: error: unable to find utility "simctl"` during the Duo test run, yet tests succeeded.

---

## 7. Item 6: `swift format`

Verified:

```
$ swift format --version
6.4.4
$ xcrun --find swift-format
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format
```

- **Subcommands:** `format` (the default), `lint`, `dump-configuration`.
- **Useful flags** (from `swift format lint --help`): `-r/--recursive`, `-p/--parallel`, `-s/--strict`, `--configuration <path-or-json>`.
- **CI lint:** `swift format lint --strict --recursive --parallel .`
  - Exit 0 means clean. Exit 1 means findings (each printed as `file:line:col: error: [Rule] message` with `--strict`).
  - I verified both outcomes.
- **Auto-fix:** `swift format format --in-place --recursive .`
  - On a deliberately bad file, lint reported `[Spacing]`, `[AddLines]` and similar findings, and the formatter fixed the file; lint was then clean.
- **Config discovery.**
  - `.swift-format` is auto-discovered from the current directory or a parent. `dump-configuration --effective` showed 4 spaces after I added the file.
  - The default config uses 2-space indentation, so lint fails on Xcode-style 4-space code without a `.swift-format`. That is why the skeleton includes one.
  - The skeleton lints clean with it.
- **Runner image.** It has a separate nicklockwood `SwiftFormat 0.64.5`. You do not need it; `swift format` comes with the Xcode 27.2 toolchain.

---

## 8. Optional `mise.toml` sketch

I did not run this.

```toml
[tasks.lint]
run = "swift format lint --strict --recursive --parallel ."
[tasks.build-ios]
run = "xcodebuild build -project Audiobookshelf.xcodeproj -scheme Audiobookshelf -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO"
[tasks.build-mac]
run = "xcodebuild build -project Audiobookshelf.xcodeproj -scheme Audiobookshelf -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO"
[tasks.test-kit]
dir = "Packages/AudiobookshelfKit"
run = "swift test"
```

---

## 9. Gaps and uncertainties

- **Xcode Cloud.** I could not verify that it supports `.xcproj`, or that it offers Xcode 27.2.
  - The conversion-back path (`xcodebuild -convert-project "Xcode 16.0"`) is the fallback.
  - The requirement for a shared scheme is based on general knowledge rather than a fetched doc. The skeleton includes one regardless.
- **GitHub Actions YAML is unverified.** The runner readme and toolset are authoritative for what exists, but I cannot execute a hosted job. Line numbers cited from `xcode-27-arm64-Readme.md` are approximate (±1).
- **Not tested:**
  - Omitting the `Info.plist` membership exception.
  - The CarPlay scene delegate and its entitlement.
  - `UISupportedInterfaceOrientations` on macOS.
  - Release/archive builds and signing with a real team.
  - Preservation of JSON5 comments by the formatter.
  - A `sed`-based `CURRENT_PROJECT_VERSION` update in the JSON.
  - Installing `xcprojformatter` through mise.
- **Package tests are not in the app scheme.** My attempt to add them to the shared scheme did not work. Run them via `swift test` or `xcodebuild test` inside the package directory. A test plan (`.xctestplan`) might solve this, but I did not try it.
