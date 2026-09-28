# Integrating WdkSwiftCore into your own project

This is the full guide for adding `WdkSwiftCore` to an app that isn't
`wdk-starter-swift`. If you just want to run the existing example, see
[wdk-starter-swift](https://github.com/Tetherto/wdk-starter-swift) instead —
its README covers running that specific project, and links back here for the
general pattern.

## Before you start: one known limitation

Any wallet initialization — create **or** import — currently crashes with an
`ADDON_NOT_FOUND` error the moment it touches a worker thread
(`bare-worker`). This has been traced to `bare-worker`'s own bundled copy of
`bare-module-traverse` re-resolving its addon graph independently at runtime,
without the `linked:` context the rest of the bundle correctly uses — a gap
in Bare's runtime itself, not in anything below. It reproduces identically
regardless of how you wire the artifacts in (this guide's automated path,
the manual path, XcodeGen, or the plain Xcode IDE), and regardless of
whether you create a new wallet or import an existing one. Tracked upstream;
not something this guide's setup steps can work around. Confirmed **not**
present on Android against the same wallet functionality — this appears
specific to iOS/JSC's interaction with `bare-worker`.

Everything else in this guide — the Swift API itself, every non-worker
operation (addresses, balances, arbitrary method calls) — works correctly.

## The fast path

### 1. Copy the setup script into your project

```bash
mkdir -p Scripts
curl -o Scripts/wdk-setup.js https://raw.githubusercontent.com/Tetherto/wdk-core-swift/main/Scripts/wdk-setup.js
```

(Or copy it from a local clone of this repo — same file either way.)

This one script replaces the entire manual "WDK Worklet Bundler" section
further down in this guide: it installs the bundler correctly (locally, never
globally — a global install breaks the bundler's own internal dependency
resolution), works around two bundler bugs that otherwise block bundle
generation outright, generates the worklet bundle and native addons, fetches
`BareKit.xcframework`, and produces a local Swift package
(`.wdk-runtime/Package.swift`) with one `.binaryTarget` per artifact — which
is what actually gets embedded and signed, automatically, by Xcode's own SPM
build phase.

### 2. Create `wdk.config.js` in your project root

```js
module.exports = {
  transport: "jsonrpc",
  networks: {
    ethereum: { package: "@tetherto/wdk-wallet-evm" },
    // add whichever networks you need — see the bundler's own reference:
    // https://github.com/tetherto/wdk-worklet-bundler#quick-start--swift--kotlin-json-rpc
  },
  output: {
    bundle: "./wdk-worklet.mobile.bundle",
    addons: { ios: "./addons" },
    addonsYml: "./addons/addons.yml",
  },
  options: {
    platforms: ["ios"],
    swiftTarget: "<your Xcode target name>",
    convertEsmToCjs: true, // required — JavaScriptCore cannot load ES modules from the bundle
  },
};
```

### 3. Run it

```bash
node Scripts/wdk-setup.js --barekit-tag v2.3.0
```

Run this **before** generating an Xcode project the first time — there's a
genuine bootstrap ordering constraint here, not just a suggestion: XcodeGen
validates local package references before it generates anything, so
`.wdk-runtime/Package.swift` has to already exist, which means this step has
to come before step 4, not after.

`--barekit-tag v2.3.0` is pinned deliberately, not a stale default — BareKit
≥ 2.5 ships a `bare-module` version that breaks this bundler's ESM→CJS
conversion outright (tracked in
[wdk-worklet-bundler#66](https://github.com/tetherto/wdk-worklet-bundler/issues/66)).
Bump the tag once that lands upstream.

### 4. Wire the two dependencies into your project

You need both `WdkSwiftCore` itself (this repo) and the local `.wdk-runtime`
package the setup script just generated. Two ways to do this — pick based on
how you manage your Xcode project. **Only the XcodeGen path below has
actually been built and run on a physical device as part of validating this
guide.** The plain-Xcode-IDE steps are the same underlying SwiftPM mechanism
and should work identically, but they haven't been device-tested by us —
flagged honestly rather than presented with equal confidence.

#### XcodeGen — proven, device-tested

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

#### Plain Xcode IDE — same mechanism, not yet device-tested by us

1. **File → Add Package Dependencies...** → enter this repo's URL
   (`https://github.com/tetherto/wdk-core-swift`) → add the `WdkSwiftCore`
   product to your app target.
2. **File → Add Package Dependencies... → Add Local...** → select the
   `.wdk-runtime` folder the setup script generated → add the `WdkRuntime`
   product to your app target.
3. Add `wdk-worklet.mobile.bundle` to your target's **Build Phases → Copy
   Bundle Resources**.

Either way, once both packages are added, Xcode's own SwiftPM embed phase
handles embedding and signing every addon xcframework and `BareKit.xcframework`
automatically, on every build — no dragging frameworks in, no manual
Embed & Sign toggling.

### 5. Build and run

Set your Team under Signing & Capabilities if you haven't already, then
build normally.

### 6. Changing your config later

If you edit `wdk.config.js` after your project already exists (different
networks, a new BareKit tag), re-run setup from inside Xcode's own terminal
using the command plugin instead of running the script directly:

```bash
swift package wdk-setup --barekit-tag v2.3.0
```

If that refuses network access:

```bash
swift package --allow-network-connections all wdk-setup --barekit-tag v2.3.0
```

---

## Doing it manually (what the script above replaces)

The rest of this document is the same manual, artifact-by-artifact process
`wdk-setup.js` automates. You shouldn't need any of it if the fast path
above works — it's kept here because it's the ground truth for what the
script is actually doing, useful if you're debugging a setup failure or
adapting this for a build system the script doesn't support yet.

### The three artifacts

| Artifact | What it is |
| --- | --- |
| **BareKit.xcframework** | The Bare runtime that hosts the JavaScript worklet |
| **Worklet bundle** | `wdk-worklet.mobile.bundle` (iOS) or `wdk-worklet.macos.bundle` (macOS) |
| **Native addon xcframeworks** | One xcframework per native dependency (crypto, networking, filesystem, etc.) |

### Generating the bundle and addons by hand

Install the bundler **locally, not globally** — a global install breaks its
own internal dependency resolution (`bare-pack` becomes unresolvable from a
project's working directory):

```bash
npm install --save-dev @tetherto/wdk-worklet-bundler
```

Two bugs currently block a clean `generate --install` run on any install
method:

1. The bundler's own dynamic-import validator has a false positive — it
   flags any method literally named `import` (e.g. `bare-module`'s own
   `ModuleLoader.import(...)`) as if it were a real `import()` expression.
   `wdk-setup.js` patches this automatically; done by hand, find the line
   matching `still contains a dynamic import()` in
   `node_modules/@tetherto/wdk-worklet-bundler/dist/*.js` and replace the
   naive regex check with one that also excludes matches preceded by
   `async ` or followed by `{` (a method-definition shape).
2. `bare-lief` `0.2.8` non-deterministically corrupts a random subset of
   addon binaries on repeated builds (both iOS and Android — see
   [holepunchto/bare-lief#14](https://github.com/holepunchto/bare-lief/issues/14)).
   Pin it via `package.json`:
   ```json
   "overrides": { "bare-lief": "0.2.7" }
   ```

Then:

```bash
wdk-worklet-bundler generate --install
```

One addon the bundler's own built-in list doesn't yet cover —
`bare-broadcast-channel`, needed by `bare-worker` — has to be linked
separately:

```bash
node -e "
const link = require('bare-link');
const path = require('path');
(async () => {
  for await (const _ of link(
    path.join(process.cwd(), 'node_modules', 'bare-broadcast-channel'),
    { hosts: ['ios-arm64', 'ios-arm64-simulator', 'ios-x64-simulator'], out: 'addons' }
  )) {}
})();
"
```

Download **BareKit.xcframework** from
[bare-kit releases](https://github.com/holepunchto/bare-kit/releases) —
pinned at `v2.3.0` for the reason given in the fast path above.

### Wiring the manually-generated artifacts in

This is the original, pre-automation flow — embedding raw files via
XcodeGen's `addons.yml` include or dragging them into the Xcode IDE, rather
than through generated `.binaryTarget`s. It works, but needs the manual
codesigning/rpath fixes covered in this repo's own
[Troubleshooting](README.md#troubleshooting) section, which the fast path's
`.binaryTarget` approach avoids by construction (Xcode's own embed phase
signs everything correctly on its own).

See the [Troubleshooting](README.md#troubleshooting) section in this repo's
main README for the codesigning, Gatekeeper quarantine, and signal-6-abort
issues this manual path can hit.
