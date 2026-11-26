import Foundation
import AppIntents
import LogCore
import LogActivity

/// The hunger Live Activity's buttons: log a food thought (the same food_thought write as
/// Today's "Thinking about food?" buttons). Compiled into both the app and the LogWidgets
/// extension so the system can find it; as a LiveActivityIntent it always runs in the app's
/// process, with the passcode from the Keychain.
struct LogFoodThoughtIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Log a food thought"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Strength")
    var strength: Int

    init() { strength = 1 }
    init(strength: Int) { self.strength = strength }

    func perform() async throws -> some IntentResult {
        let s = max(1, min(3, strength))
        guard let code = PasscodeStore.read(), !code.isEmpty else { return .result() }
        _ = try? await LogAPI.write("food_thought", payload: ["strength": s], passcode: code)
        await HungerActivity.appendNow(strength: s)
        return .result()
    }
}
