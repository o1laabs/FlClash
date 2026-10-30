import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var servicePlugin: FlClashServicePlugin?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            let plugin = FlClashServicePlugin(messenger: controller.binaryMessenger)
            plugin.register()
            self.servicePlugin = plugin
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        super.applicationDidReceiveMemoryWarning(application)
        servicePlugin?.handleLowMemory()
    }
}
