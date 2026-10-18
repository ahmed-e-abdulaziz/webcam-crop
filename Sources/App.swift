import AppKit
import SwiftUI

@main
struct WebcamCropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var engine = CameraEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(engine)
        } label: {
            Image(systemName: engine.sending ? "camera.viewfinder" : "camera")
        }
        .menuBarExtraStyle(.window)

        Window("Webcam Crop", id: "settings") {
            SettingsView().environmentObject(engine)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(engine.firstLaunch || CommandLine.arguments.contains("--settings") ? .presented : .suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CameraEngine.shared.appLaunched()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CameraEngine.shared.shutdown()  // hand the virtual camera back to OBS's placeholder cleanly
    }
}
