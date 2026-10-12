# Integrating WdkSwiftCore into your own project

How to add `WdkSwiftCore` to an app that isn't `wdk-starter-swift`, and how to run this repo's own
macOS test suite. The iOS native pieces cover iPhone and iPad (Apple builds one iOS slice for both);
macOS is covered by the test suite.

To just run the example app, use [wdk-starter-swift](https://github.com/Tetherto/wdk-starter-swift)
instead — its README covers that, and links back here for the general pattern.

## What has and hasn't been verified

| Setup | Verified how |
| --- | --- |
| iOS app: **V8** engine, latest BareKit (v2.5.5), bundler 1.0.0-beta.15 (the script's default), `targets` config, `convertEsmToCjs: false` | Physical iPhone, Xcode 27: build, launch, create a wallet |
| iOS app: same, but with the bundler at an unreleased pre-release commit (`e0d4f59`) and a `platforms` config | Physical iPhone, Xcode 27: build, launch, create a wallet |
| macOS test suite: **JavaScriptCore** engine, BareKit v2.3.0, nine pinned dependencies, bundler 1.0.0-beta.15, `convertEsmToCjs: true` | `swift test`: 24 of 24 pass on Xcode 27 (also passed with bundler 1.0.0-beta.14, and reproduced independently on Xcode 26.6) |
| iOS app on the **JavaScriptCore** engine (the script's default) | Not yet verified on a device |
| iOS Simulator and iPad | Not yet verified |
| Plain Xcode IDE wiring (no XcodeGen) | Not run; it is the same SwiftPM mechanism |

## Why V8 is selected for now (temporary)

These work around problems being fixed upstream. Remove each one once its fix is released.

| Flag | Why | Remove when |
| --- | --- | --- |
| `--engine v8` | BareKit's `prebuilds.zip` ships two complete engine builds: V8 and JavaScriptCore (about 11× smaller, and the script's default). JavaScriptCore's port lacks the `SharedArrayBuffer` binding `bare-worker` needs ([libjsc#26](https://github.com/holepunchto/libjsc/issues/26)), and `bare-node-runtime` 1.5.1 loads `bare-worker` on every start ([bare-node-runtime#13](https://github.com/holepunchto/bare-node-runtime/issues/13)). On JavaScriptCore, worker threads do not work. | Both issues are fixed and JavaScriptCore is verified on a device |
| `convertEsmToCjs` | V8 loads ES modules natively, so `false` works. JavaScriptCore cannot, so it needs `true` — but with BareKit 2.5 or newer that conversion breaks until [wdk-worklet-bundler#66](https://github.com/tetherto/wdk-worklet-bundler/issues/66) is fixed, which is why the JavaScriptCore setup below uses BareKit v2.3.0. | #66 is fixed |

The script also pins `bare-node-runtime` to 1.5.0 as a direct dependency (for the reason in the first
row). It is a direct dependency, not an npm `overrides` entry, on purpose: the bundler's own install
step adds an unversioned `bare-node-runtime`, which npm rejects as a conflict with an override.

The script installs the worklet bundler at an **exact version** (`1.0.0-beta.15`), not a range. A
floating range picked up beta.15 the day it was published; that release rejects `options.platforms`
and links a different set of addons, so existing configs stopped working. The version is bumped
deliberately, together with these docs and a test run. To try a different or unreleased bundler,
pass `--bundler-ref` (an npm version, or `github:tetherto/wdk-worklet-bundler#<commit>`; pin a full
commit SHA, because a branch or PR head can change under you).

## iOS: the fast path

### 1. Copy the setup script into your project

Copy `Scripts/wdk-setup.js` from this repository into your project's `Scripts/` folder.

It replaces the whole manual process further down: it installs the bundler locally (a global install
breaks the bundler's own `bare-pack` lookup), generates the worklet bundle and native addons,
downloads BareKit, and writes a local Swift package (`.wdk-runtime/Package.swift`) with one
`.binaryTarget` per addon plus BareKit. Xcode's own SwiftPM embed phase then embeds and signs
everything on every build — no dragging frameworks in, no manual Embed & Sign.

`package.json`, `package-lock.json`, `node_modules/` and `.wdk-runtime/` are generated output. Don't
commit them and don't hand-edit them; the script rewrites `package.json` on every run.

### 2. Create `wdk.config.js` in your project root

```js
module.exports = {
  transport: "jsonrpc",
  networks: {
    ethereum: { package: "@tetherto/wdk-wallet-evm" },
    // add the networks you need — see the bundler's reference:
    // https://github.com/tetherto/wdk-worklet-bundler#quick-start--swift--kotlin-json-rpc
  },
  output: {
    bundle: "./wdk-worklet.mobile.bundle",
    addons: { ios: "./addons" },
    addonsYml: "./addons/addons.yml",
  },
  options: {
    targets: ["ios-arm64", "ios-arm64-simulator", "ios-x64-simulator"],
    swiftTarget: "<your Xcode target name>",
    convertEsmToCjs: false,
    linkAddons: true,
  },
};
```

`targets` decides which platforms the bundler builds addons for (`ios-*` for iOS, `darwin-*` for
macOS). Always set it: if you leave it out, the bundler builds for all iOS and Android hosts. Bundler
1.0.0-beta.14 and earlier used an `options.platforms` list instead, and 1.0.0-beta.15 rejects that
key; the script reads either form, so an older bundler selected with `--bundler-ref` keeps working.

### 3. Run it

```bash
node Scripts/wdk-setup.js --platform ios --engine v8
```

Run this **before** generating an Xcode project the first time. XcodeGen validates local package
references before it generates anything, so `.wdk-runtime/Package.swift` has to exist already.

With no `--barekit-tag` it fetches the latest BareKit; pass `--barekit-tag vX.Y.Z` to pin one. The
first run downloads about 400 MB.

### 4. Wire the two dependencies into your project

You need `WdkSwiftCore` itself (this repo) and the local `.wdk-runtime` package. The generated
`.wdk-runtime` package declares iOS 16.0 as its minimum platform, so your app's deployment target must be
16.0 or higher (`WdkSwiftCore` itself supports iOS 14).

#### XcodeGen — verified

```yaml
packages:
  WdkSwiftCore:
    url: https://github.com/tetherto/wdk-core-swift
    branch: main
  WdkRuntime:
    path: ./.wdk-runtime

targets:
  YourApp:
    type: application
    platform: iOS
    dependencies:
      - package: WdkSwiftCore
        product: WdkSwiftCore
      - package: WdkRuntime
        product: WdkRuntime
    sources:
      - path: YourApp
      - path: wdk-worklet.mobile.bundle
        optional: true
        buildPhase: resources
```

```bash
xcodegen generate
open YourApp.xcodeproj
```

#### Plain Xcode IDE — same mechanism, not yet verified

1. **File → Add Package Dependencies…** → this repo's URL → add the `WdkSwiftCore` product to your target.
2. **File → Add Package Dependencies… → Add Local…** → select the `.wdk-runtime` folder → add the `WdkRuntime` product.
3. Add `wdk-worklet.mobile.bundle` to **Build Phases → Copy Bundle Resources**.

### 5. Build and run

Set your Team under Signing & Capabilities and build.

### 6. Changing your config later

Run the same command again after editing `wdk.config.js`. Add `--force` to regenerate when nothing
changed.

## The JavaScriptCore engine

JavaScriptCore is the script's default (`--engine jsc`) and what Apple ships with the OS. It is the
long-term target, but today it needs the older, fully pinned dependency set and has no worker
threads. This is the setup the macOS suite below validates:

- `--engine jsc`, `--barekit-tag v2.3.0`, `convertEsmToCjs: true`
- the pins listed in the next section (`bare-node-runtime@1.5.0` is added by the script itself)

It has not yet been run on an iOS device.

## Running the macOS test suite (for contributors to this repo)

The suite runs `swift test` against a real worklet bundle and real addon frameworks.
`wdk-setup.js --platform macos` generates both and stages them where the tests look. Run it from this
repository's root (the script refuses to run elsewhere, since `Scripts/prepare-macos-frameworks.sh`
and the test target only exist here).

### 1. Create `wdk.config.js`

```js
module.exports = {
  transport: "jsonrpc",
  networks: {
    ethereum: { package: "@tetherto/wdk-wallet-evm" },
    polygon:  { package: "@tetherto/wdk-wallet-evm" },
    bitcoin:  { package: "@tetherto/wdk-wallet-btc" },
  },
  output: {
    bundle: "./wdk-worklet.macos.bundle",
    addons: { ios: "./addons-ios-macrun", macos: "./mac-addons" },
    addonsYml: "./addons-ios-macrun/addons.yml",
  },
  options: {
    targets: ["ios-arm64", "ios-arm64-simulator", "ios-x64-simulator", "darwin-arm64", "darwin-x64"],
    swiftTarget: "wdk-starter-swift",
    convertEsmToCjs: true,
  },
};
```

This is the validated configuration. It also builds iOS addons into `addons-ios-macrun/`, which the
test run doesn't use.

### 2. Generate and stage

```bash
node Scripts/wdk-setup.js --platform macos --engine jsc --barekit-tag v2.3.0 \
  --pin bare-thread@1.2.4 --pin bare-type@1.1.0 --pin bare-module@6.4.0 \
  --pin bare-channel@5.2.4 --pin bare-broadcast-channel@0.2.0 \
  --pin bare-inspect@3.1.4 --pin bare-structured-clone@1.6.0 --pin bare-worker@4.4.0
```

This writes `Frameworks/BareKit.xcframework` (the macOS JavaScriptCore build),
`Tests/Resources/macos/Frameworks/*.framework` and
`Tests/Resources/macos/wdk-worklet.macos.bundle`, then runs
`Scripts/prepare-macos-frameworks.sh` (fixes rpaths, re-signs ad hoc, removes the download
quarantine). No satellite Swift package is created for macOS. All of these paths are git-ignored.

### 3. Run the tests

```bash
./Scripts/test-with-frameworks.sh
```

Expected: 24 tests pass in about a minute. The first takes around 15 seconds while the worklet boots.

On Xcode 27 the script passes BareKit's location as an absolute path (the new build backend resolves
relative `-F` paths from the directory above the package) and copies `BareKit.framework` into both
`.build/arm64-apple-macosx/debug` and `.build/out/Products/Debug`, so it works with either backend.

## Doing it manually (what the script automates)

This is the ground truth for what the script does — useful when debugging a setup failure or adapting
this to a build system the script doesn't cover. You shouldn't need it if the fast path works.

### The three artifacts

| Artifact | What it is |
| --- | --- |
| **BareKit.xcframework** | The Bare runtime that hosts the JavaScript worklet |
| **Worklet bundle** | `wdk-worklet.mobile.bundle` (iOS) or `wdk-worklet.macos.bundle` (macOS) |
| **Native addon frameworks** | One per native dependency: xcframeworks for iOS, flat `.framework` bundles for macOS |

### Generating the bundle and addons by hand

1. Create a `package.json` in your project and install the bundler **locally, not globally**:
   `npm install --save-dev @tetherto/wdk-worklet-bundler@1.0.0-beta.15`.
2. Add `bare-node-runtime` **1.5.0** as an exact direct dependency (see the first row of the flags table).
3. The bundler (1.0.0-beta.15 and earlier) has a false positive in its dynamic-import validator: it
   flags a method literally named `import` (such as `bare-module`'s `ModuleLoader.import(...)`) as a
   real `import()` expression. Find the line containing `still contains a dynamic import()` in
   `node_modules/@tetherto/wdk-worklet-bundler/dist/*.js` and change its regex check to ignore matches
   preceded by `async ` or followed by `{`. The script applies this patch for you, and does it after
   every install, since an install would undo it.
4. Run `npx wdk-worklet-bundler generate --install`.
5. Bundlers before 1.0.0-beta.15 link a fixed list of addons and miss `bare-broadcast-channel`, so link it
   yourself with `bare-link` and the hosts you target. The script always does this; with 1.0.0-beta.15, which
   discovers addons from the bundle, it is redundant but harmless.

### Choosing the BareKit build

Download `prebuilds.zip` from [bare-kit releases](https://github.com/holepunchto/bare-kit/releases)
and take `BareKit.xcframework` from the folder for your platform and engine:

| | V8 | JavaScriptCore |
| --- | --- | --- |
| iOS | `ios/` | `ios-javascriptcore/` |
| macOS | `darwin/` | `darwin-javascriptcore/` |

(`apple/` and `apple-javascriptcore/` are combined iOS + macOS builds, which the script doesn't use.)

### Wiring raw artifacts into Xcode

Embedding raw files by hand (dragging them in, or XcodeGen's `addons.yml` include) works, but needs
the manual codesigning and rpath fixes in this repo's
[Troubleshooting](README.md#troubleshooting) section — covering code signature errors, the Gatekeeper
quarantine, and signal 6 aborts. The fast path's `.binaryTarget` approach avoids all of them, because
Xcode's embed phase signs everything itself.
