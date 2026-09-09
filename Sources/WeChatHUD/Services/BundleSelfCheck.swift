import Foundation
import CZstd

/// Distribution smoke check: no account bootstrap, settings, network, or GUI.
enum BundleSelfCheck {
    static func inspect(loadPrompt: (String) throws -> String = { version in
        if Bundle.main.bundleURL.pathExtension == "app" {
            // Never let SwiftPM's development-directory fallback hide a
            // missing resource in a distribution app.
            guard let url = PromptLoader.packagedPromptURL(version: version, resourcesURL: Bundle.main.resourceURL) else {
                throw PromptLoader.PromptError.notFound(version)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try PromptLoader().load(version: version)
    }) -> [String: String] {
        do {
            for version in ["classifier_v4", "discussion_v2"] {
                guard !(try loadPrompt(version)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ["mode": "bundle-check", "result": "failed", "reason": "bundled_prompts"]
                }
            }
            // Exercise the bundled native library without any user data.
            guard czstd_is_error(0) == 0 else {
                return ["mode": "bundle-check", "result": "failed", "reason": "native_dependency"]
            }
            return ["mode": "bundle-check", "result": "ready", "bundled_prompts": "ready", "native_dependency": "ready"]
        } catch {
            return ["mode": "bundle-check", "result": "failed", "reason": "bundled_prompts"]
        }
    }

    static func run() -> Int32 {
        let result = inspect()
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return 1 }
        print(text)
        return result["result"] == "ready" ? 0 : 1
    }
}
