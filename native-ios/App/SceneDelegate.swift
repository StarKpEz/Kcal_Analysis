import UIKit
import SwiftUI

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let store: SnapshotStore
        var preferences: UserDefaults? = .standard
        #if DEBUG
        if ProcessInfo.processInfo.environment["KCAL_UI_TESTING"] == "1" {
            // Every UI-test launch is empty and separate from the real app sandbox.
            store = SnapshotStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("KcalUITest-" + UUID().uuidString, isDirectory: true))
            window.overrideUserInterfaceStyle = ProcessInfo.processInfo.environment["KCAL_UI_DARK"] == "1" ? .dark : .light
            // A scene trait reaches SwiftUI presentations and UIKit controls,
            // unlike an environment override confined to the root view.
            if ProcessInfo.processInfo.environment["KCAL_UI_LARGE_TEXT"] == "1" {
                windowScene.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            }
            preferences = nil
        } else { store = SnapshotStore() }
        #else
        store = SnapshotStore()
        #endif
        let model = NativeAppModel(store: store)
        let root = NativeRootView(model: model, preferences: preferences)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
    }

}
