import UIKit
import LogHealth
import LogUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        // Native tab bar (Liquid Glass on iOS 26) around the app's screens; see LogShell.swift.
        window?.rootViewController = ShellTabBarController()
        window?.makeKeyAndVisible()

        // Opened from a widget.
        if let url = connectionOptions.urlContexts.first?.url, DeepLink.handles(url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { DeepLink.open(url) }
        }
    }

    // Leaving the app: ask iOS for the next background Apple Health catch-up.
    func sceneDidEnterBackground(_ scene: UIScene) {
        NativeHealthSync.scheduleBackgroundRefresh()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url, DeepLink.handles(url) {
            DeepLink.open(url)
        }
    }
}
