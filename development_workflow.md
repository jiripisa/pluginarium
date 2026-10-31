# Pluginarium — Development Workflow, Build & Distribution

## 1. Toolchain & Project Layout

- Xcode command line tools (Swift 6), macOS 15+. No Xcode project: Swift
  Package Manager builds the code, `build.sh` assembles the `.app` bundle.

```
pluginarium/
├── Package.swift
├── Sources/Pluginarium/          # SwiftUI app (thin layer)
├── Sources/PluginariumCore/      # logic without UI, tested
├── Tests/PluginariumCoreTests/   # Swift Testing
├── Resources/               # Info.plist, entitlements, AppIcon.png (1024 px)
├── build.sh                 # debug | release | dist | clean
└── run.sh                   # debug (logs in terminal) | release (open .app)
```

## 2. Build (`build.sh`)

| Command | Result |
|---|---|
| `./build.sh` / `./build.sh debug` | `swift build` → `build/debug/Pluginarium.app` (ad-hoc signed) |
| `./build.sh release` | same with `-c release` → `build/release/Pluginarium.app` |
| `./build.sh dist` | release build → **Developer ID signing (hardened runtime)** → notarized + stapled app → **DMG** → notarized + stapled DMG |
| `./build.sh clean` | removes `build/` and `.build/` |

### 2.1 App-bundle assembly (all modes)

Executable → `Contents/MacOS`, `Resources/Info.plist` → `Contents/`,
`Resources/AppIcon.png` → `AppIcon.icns` (sips + iconutil), PkgInfo,
then an ad-hoc signature with the entitlements. New resource files must be
copied in `build.sh` explicitly.

### 2.2 Distribution (`dist`)

1. Sign the app with the first "Developer ID
   Application" identity in the Keychain, hardened runtime, timestamp.
2. Notarize the zipped app (`notarytool --keychain-profile notary --wait`), staple it.
3. Build `build/Pluginarium.dmg` (app + Applications symlink), sign, notarize, staple.

A notarization `HTTP status code: 403. A required agreement is missing or has
expired` is an account issue: accept the updated agreement at
developer.apple.com/account.

### 2.3 One-time signing setup (per machine)

1. A **Developer ID Application** certificate in the login keychain.
2. A stored notarization profile named `notary` (or set `NOTARY_PROFILE`):
   ```
   xcrun notarytool store-credentials notary \
     --apple-id <apple-id-email> --team-id <TEAMID> --password <app-specific-password>
   ```

### 2.4 Entitlements & sandbox policy

The app ships **unsandboxed** (`com.apple.security.app-sandbox = false`),
which is fine for Developer ID / DMG distribution; Gatekeeper needs the
hardened runtime and notarization. Add entitlements to
`Resources/Pluginarium.entitlements` only when a feature needs them.

## 3. Run (`run.sh`)

- `./run.sh debug` *(default)* — rebuilds when anything under `Sources/` or
  `Resources/` is newer than the binary, registers the bundle with Launch
  Services, then runs the binary in the terminal: logs stream live, Ctrl+C quits.
- `./run.sh release` — rebuilds if stale, then `open`s the app.

## 4. Development Methodology

- Logic goes into `PluginariumCore`, test first (`swift test`); the UI is checked
  by running the app.
- Conventional Commits with a scope: `feat(core): …`, `fix(ui): …`,
  `docs(manual): …`, `chore(release): v1.2.0 — …`.
- `main` is always green: builds, tests pass, the app launches.

### Versioning & releases

- The version lives in `Resources/Info.plist` (`CFBundleShortVersionString`
  and `CFBundleVersion`), semantic versioning, starting at 0.1.0.
- Releases follow the project skill `.claude/skills/release/SKILL.md`.
- Pushes to GitHub happen only after explicit confirmation.
