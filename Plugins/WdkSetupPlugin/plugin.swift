import Foundation
import PackagePlugin

/// `swift package wdk-setup` — runs Scripts/wdk-setup.js from the *consumer's*
/// project root (context.package.directory when invoked from the package that
/// depends on WdkSwiftCore, per the Track B probe from the Phase 0 spike),
/// producing wdk.config.js's worklet bundle, addons, BareKit, and the local
/// .wdk-runtime satellite package the consumer then adds as a one-time local
/// package dependency.
///
/// This plugin is a thin wrapper. All the real logic — bundler install, the
/// dynamic-import patch, the bare-lief pin, BareKit fetch, satellite package
/// generation, idempotency marker — lives in Scripts/wdk-setup.js, which is
/// plain Node and has been tested independently of Xcode/SwiftPM. Keeping the
/// logic there rather than in Swift means it can be run and debugged directly
/// (`node Scripts/wdk-setup.js`) without going through `swift package` at all.
@main
struct WdkSetupPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let consumerRoot = context.package.directory

        let scriptURL = context.package.directory
            .appending(subpath: "Scripts")
            .appending(subpath: "wdk-setup.js")

        guard FileManager.default.fileExists(atPath: scriptURL.string) else {
            // WdkSwiftCore ships Scripts/wdk-setup.js, but the consumer invokes
            // this plugin from their own project. If the consumer hasn't copied
            // the script in yet (see the setup instructions in the issue #5
            // writeup), point them at it rather than failing silently.
            Diagnostics.error(
                "wdk-setup.js not found at \(scriptURL.string). " +
                "Copy Scripts/wdk-setup.js from wdk-core-swift into your project root " +
                "(next to wdk.config.js) once, then re-run `swift package wdk-setup`."
            )
            return
        }

        var nodeArguments = [scriptURL.string]
        nodeArguments.append(contentsOf: arguments)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // bash -lc ensures an nvm-managed Node is on PATH, same reasoning as
        // wdk-core-kotlin's fetchBareKit task — a plain `node` invocation can
        // fail in shells where Node is provisioned through a login-shell rc file.
        process.arguments = ["bash", "-lc", "node \(nodeArguments.map { "'\($0)'" }.joined(separator: " "))"]
        process.currentDirectoryURL = URL(fileURLWithPath: consumerRoot.string)

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            Diagnostics.error("wdk-setup.js exited with status \(process.terminationStatus)")
        }
    }
}
