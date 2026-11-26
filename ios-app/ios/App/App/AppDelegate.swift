import UIKit
import AppIntents
import Capacitor
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

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
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
