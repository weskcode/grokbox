# Build and test results

## Commands used

```bash
# Generate the Xcode project
cd ~/Documents/Developer/grokbox && xcodegen generate

# Build the app (derived data MUST be outside the iCloud-synced folder — see below)
xcodebuild -project Grokbox.xcodeproj -scheme Grokbox -configuration Debug \
           -derivedDataPath <scratch>/dd build

# Engine test suite
cd GrokboxCore && swift test
```

## Results

| Target | Result |
|---|---|
| `Grokbox` app, Debug, arm64 | **BUILD SUCCEEDED**, 0 errors, 1 warning |
| `GrokboxCore` package | **BUILD SUCCEEDED**, 0 errors, 0 warnings |
| `GrokboxCore` tests | **101 tests in 27 suites — all passed** in 102.6 s |
| Release configuration | **Not attempted** — no Release scheme configured beyond defaults |
| Signed / notarized build | **Not possible** — ad-hoc signing only, no Developer ID |
| Installer / package | **Does not exist** |

The single build warning is `appintentsmetadataprocessor: No AppIntents.framework
dependency found`, which is benign for an app that declares no App Intents.

## Build environment hazards found

1. **Derived data cannot live inside the repo.** The repository sits under
   `~/Documents/Developer`, which is a synced (file-provider) folder. macOS stamps
   extended attributes onto build products there, and `codesign` then refuses the bundle
   with `resource fork, Finder information, or similar detritus not allowed`. Building to
   a derived-data path outside the synced tree is required. Xcode's own default location
   already satisfies this; only command-line builds with `-derivedDataPath .` are affected.
   Documented in the project README.

2. **`swift test` does not exit.** The test process lingers after reporting results, so
   scripted runs must watch the log for `Test run with` and then terminate it.

## Not tested

Clean-build-from-scratch timing, incremental build correctness, Release/optimised build,
multi-architecture (Intel) build, CI (none configured), installer creation, upgrade
packaging, and uninstall — none of which exist yet.
