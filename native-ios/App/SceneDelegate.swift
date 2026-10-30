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
            preferences = nil
        } else { store = SnapshotStore() }
        #else
        store = SnapshotStore()
        #endif
        let model = NativeAppModel(store: store)
        var root = AnyView(NativeRootView(model: model, preferences: preferences))
        #if DEBUG
        if ProcessInfo.processInfo.environment["KCAL_UI_LARGE_TEXT"] == "1" {
            root = AnyView(NativeRootView(model: model, preferences: preferences).environment(\.dynamicTypeSize, .accessibility5))
        }
        #endif
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
    }

}
