import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    // Garmin Connect returns the selected watches through the nscontrol-ciq scheme.
    override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        var rest = Set<UIOpenURLContext>()
        for context in URLContexts where AppDelegate.platform?.handle(url: context.url) != true {
            rest.insert(context)
        }
        if !rest.isEmpty { super.scene(scene, openURLContexts: rest) }
    }
}
