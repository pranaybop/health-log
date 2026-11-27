import UIKit
import AppIntents
import LogCore
import LogHealth
import LogUI

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Apple Health catch-up in the background (BGAppRefreshTask). Has to be registered before launch ends.
        NativeHealthSync.registerBackgroundTasks()
        ReminderScheduler.shared.install()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// MARK: - Siri and Shortcuts

/// "Log my weight in Log": a weigh-in without opening the app.
struct LogWeightIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a weigh-in"
    static var description = IntentDescription("Adds a weigh-in to your log.")

    @Parameter(title: "Weight (lb)")
    var pounds: Double

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (50...600).contains(pounds) else { return .result(dialog: "That weight looks off. Say it in pounds.") }
        guard let credential = await LogCredentials.shared.current() else {
            return .result(dialog: "Open Log and sign in first.")
        }
        let r = try await LogAPI.write("weigh_in", payload: ["weight_lb": pounds], credential: credential)
        if (r["ok"] as? Bool) == false { return .result(dialog: "Log didn't take that weight.") }
        await MainActor.run { Task { await LogStore.shared.refresh() } }
        return .result(dialog: "Logged \(Fmt.num(pounds, 1)) pounds.")
    }
}

/// "I'm thinking about food": a food thought (hunger signal), like Today's buttons.
struct LogHungerIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a food thought"
    static var description = IntentDescription("Notes a hunger signal: passing, strong or a craving.")

    @Parameter(title: "How strong", default: .passing)
    var strength: HungerStrength

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let credential = await LogCredentials.shared.current() else {
            return .result(dialog: "Open Log and sign in first.")
        }
        _ = try await LogAPI.write("food_thought", payload: ["strength": strength.rawValue], credential: credential)
        return .result(dialog: "Noted.")
    }
}

enum HungerStrength: Int, AppEnum {
    case passing = 1, strong = 2, craving = 3
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Strength"
    static var caseDisplayRepresentations: [HungerStrength: DisplayRepresentation] = [
        .passing: "Passing", .strong: "Strong", .craving: "Craving",
    ]
}

struct LogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogWeightIntent(), phrases: ["Log my weight in \(.applicationName)", "Add a weigh-in to \(.applicationName)"],
                    shortTitle: "Log weight", systemImageName: "scalemass")
        AppShortcut(intent: LogHungerIntent(), phrases: ["Log hunger in \(.applicationName)", "I'm thinking about food in \(.applicationName)"],
                    shortTitle: "Food thought", systemImageName: "fork.knife")
    }
}
