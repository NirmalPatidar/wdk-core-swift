# WdkSwiftCore

A Swift Package for the [Tether WDK](https://github.com/Tetherto/wdk) (Wallet Development Kit). Provides a clean async/await API for wallet operations, key management, and multi-chain interactions on iOS and macOS.

Supported networks: EVM (Ethereum, Polygon, Arbitrum, Sepolia, etc.), Bitcoin, Solana, and ERC-4337.

## Integration Guide

Adding `WdkSwiftCore` to your own project takes one setup command plus adding
two Swift Package dependencies — see **[INTEGRATION.md](INTEGRATION.md)** for
the full guide, including the manual artifact-by-artifact process it
replaces and a note on one known limitation (worker-thread-dependent
operations currently crash; tracked upstream).

For running the existing example rather than integrating into your own app,
see [wdk-starter-swift](https://github.com/Tetherto/wdk-starter-swift).

## Example

[**wdk-starter-swift**](https://github.com/Tetherto/wdk-starter-swift) is a minimal iOS app that integrates `WdkSwiftCore` end to end: create or import a wallet, derive Ethereum (Sepolia) and Bitcoin addresses, fetch balances, call arbitrary WDK methods, and dispose.

It follows the XcodeGen flow described above, so it does not depend on the Xcode IDE. The project was developed and built using only the Xcode Command Line Tools and VS Code — `xcodegen generate` followed by `xcodebuild` for a simulator destination — and it can equally be opened in Xcode. That command-line path was last verified against this package's `main` with Xcode 26.6 and XcodeGen 2.44 (build, install, and a create-wallet / addresses / balances / dispose run on an iOS 26 simulator). Use it as a reference for the `project.yml` layout, the `addons.yml` include, and where the worklet bundle and `BareKit.xcframework` live in the tree.

## Quick Start

```swift
import WdkSwiftCore

// Initialize
let wdk = WdkSwiftCore()

// Create a new wallet
let entropy = try await wdk.generateEntropyAndEncrypt(wordCount: 12)

// Show the mnemonic to the user for backup
let mnemonic = try await wdk.getMnemonicFromEntropy(
    encryptedEntropy: entropy.encryptedEntropyBuffer,
    encryptionKey: entropy.encryptionKey
)
print("Backup phrase: \(mnemonic)")

// Initialize WDK with network configuration
let config = """
{
    "networks": {
        "ethereum": {
            "blockchain": "ethereum",
            "config": { "chainId": 1, "rpcUrl": "https://eth-mainnet.example.com" }
        }
    }
}
"""
try await wdk.initializeWDK(
    encryptionKey: entropy.encryptionKey,
    encryptedSeed: entropy.encryptedSeedBuffer,
    config: config
)

// Get an address
let address = try await wdk.getAddress(network: "ethereum")
print("Address: \(address)")

// Get balance
let balance = try await wdk.getBalance(network: "ethereum")
print("Balance: \(balance)")

// Clean up when done
try await wdk.dispose()
```

## API Reference

### Initialization

```swift
// Default: auto-detects platform bundle
//   macOS → wdk-worklet.macos.bundle
//   iOS   → wdk-worklet.mobile.bundle
let wdk = WdkSwiftCore()

// Custom bundle name
let wdk = WdkSwiftCore(bundleName: "my-custom-worklet")

// Custom bundle path (for frameworks, test targets, or app extensions)
let wdk = WdkSwiftCore(bundlePath: "/path/to/wdk-worklet.mobile.bundle")
```

### Wallet Lifecycle

| Method                                                    | Description                                                                                          |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `workletStart()`                                          | Start the worklet explicitly (otherwise started automatically on first use)                          |
| `generateEntropyAndEncrypt(wordCount:)`                   | Generate a new mnemonic (12 or 24 words) and return encrypted entropy                                |
| `getMnemonicFromEntropy(encryptedEntropy:encryptionKey:)` | Decrypt entropy to get the mnemonic phrase                                                           |
| `getSeedAndEntropyFromMnemonic(mnemonic:)`                | Convert an existing mnemonic to encrypted seed + entropy                                             |
| `initializeWDK(encryptionKey:encryptedSeed:config:)`      | Initialize WDK with keys and network configuration                                                   |
| `dispose(blockchains:)`                                   | Clean up resources. Omit `blockchains` to tear down the whole instance, or pass names to release only those |

### Account Operations

| Method                                                      | Description                           |
| ----------------------------------------------------------- | ------------------------------------- |
| `getAddress(network:accountIndex:)`                         | Get the account address for a network |
| `getBalance(network:accountIndex:)`                         | Get the account balance for a network |
| `callMethod(methodName:network:accountIndex:args:options:)` | Call any WDK method on an account     |

### Dynamic Registration

| Method                      | Description                                 |
| --------------------------- | ------------------------------------------- |
| `registerWallet(config:)`   | Register additional wallet types at runtime |
| `registerProtocol(config:)` | Register additional protocols at runtime    |

## Error Handling

All methods throw `WDKError` with the following cases:

```swift
public enum WDKError: Error {
    case ipcError(String)
    case rpcError(code: String, message: String)
    case invalidResponse(String)
    case bundleNotFound(String)
}
```

## Architecture

```
Your App
  │
  ├── WdkSwiftCore (Swift, async/await API)
  │     │
  │     ├── JSON-RPC 2.0 over length-prefixed IPC
  │     │
  │     └── BareKit (Worklet + IPC)
  │           │
  │           ├── wdk-worklet.{mobile,macos}.bundle (JavaScript worklet)
  │           │
  │           └── native addon xcframeworks
  │                 (crypto, networking, filesystem, etc. — one per native dependency)
  │
  └── BareKit.xcframework (Bare runtime — from holepunchto/bare-kit)
```

## Running the Tests

The test suite runs on macOS against a real worklet bundle and the addon frameworks. Generate them with the bundler using `platforms: ["macos"]`, `convertEsmToCjs: true`, and `output.bundle: "./.wdk-bundle/wdk-worklet.macos.bundle"`, then place them where the tests expect:

```
Frameworks/BareKit.xcframework          # from bare-kit releases
Tests/Resources/macos/wdk-worklet.macos.bundle
Tests/Resources/macos/Frameworks/*.framework   # contents of mac-addons/
```

Then prepare the frameworks and run the suite:

```bash
./Scripts/prepare-macos-frameworks.sh   # fix rpaths, re-sign ad hoc, unquarantine BareKit
./Scripts/test-with-frameworks.sh    # wraps `swift test` with BareKit linked
```

The first script adds the rpaths sibling addons need to load each other and re-signs them (see [Troubleshooting](#troubleshooting)). It resolves paths relative to the repository root, so it can be called from anywhere. The second symlinks the addon frameworks into the working directory so the Bare runtime can `dlopen` them, and cleans up afterwards. All of these paths are git-ignored.

## Troubleshooting

> These apply to the manual artifact-wiring path in
> [INTEGRATION.md](INTEGRATION.md#doing-it-manually). If you're using the
> automated `wdk-setup` path, Xcode's own SwiftPM embed phase handles
> signing correctly on its own — you shouldn't hit these at all.

**Xcode refuses the addon frameworks with a code signature error.** Frameworks copied or dragged out of the bundler output lose their signature, and `install_name_tool` invalidates it too. Re-sign them ad hoc:

```bash
# iOS xcframeworks in your app
find ios-addons -name '*.framework' -type d -exec codesign -s - --force {} \;

# macOS test frameworks in this repo
./Scripts/prepare-macos-frameworks.sh
```

**`BareKit.xcframework` is blocked by Gatekeeper.** Archives downloaded from GitHub releases carry the `com.apple.quarantine` attribute, which can make the linker or `dyld` reject the framework. Strip it:

```bash
xattr -dr com.apple.quarantine path/to/BareKit.xcframework
```

**Worklet fails to boot with a signal 6 abort.** Two common causes:

- An addon cannot `dlopen` a sibling. Check that every framework the bundle needs is present and, on macOS, that the rpath fix above has been applied.
- The bundle contains ES modules. The console shows `Uncaught (in promise) createModule@[native code]` with a `bare-module` stack ending in a `require` from the worklet, and the process aborts on the first call. JavaScriptCore cannot load ESM from the bundle; set `options.convertEsmToCjs: true` in `wdk.config.js` and regenerate.

## Requirements

- iOS 14.0+ / macOS 11.0+
- Swift 5.9+
- Xcode 15.0+ (the full IDE, or just the Command Line Tools plus [XcodeGen](https://github.com/yonaskolb/XcodeGen))

## License

Apache-2.0
