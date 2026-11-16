import SwiftUI

/// Logs how the app started and stopped, to explain gaps in syncing.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let reason = launchOptions?[.bluetoothCentrals] != nil ? "by iOS for the strap"
            : application.applicationState == .background ? "in the background" : "by opening it"
        Log.shared("App launched \(reason)")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) { Log.shared("App terminating") }
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) { Log.shared("Memory warning") }
}

@main
struct WhoopSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    init() {
        #if DEBUG
        if ZoneCheck.enabled { return }  // the Simulator's zone check runs instead of the app (ZoneCheck.swift)
        #endif
        AppModel.registerBackgroundFlush()
        // Create the Bluetooth manager now: when iOS relaunches the app in the background for the
        // strap, it hands the link back to whichever manager uses the restore identifier.
        _ = AppModel.shared
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ZoneCheck.enabled {
                ZoneCheckView()
            } else {
                app
            }
            #else
            app
            #endif
        }
        .onChange(of: phase) { _, newPhase in
            #if DEBUG
            if ZoneCheck.enabled { return }
            #endif
            switch newPhase {
            case .active:
                Log.shared("App opened")
                model.foreground()
            case .background:
                Log.shared("App in the background")
                AppModel.scheduleBackgroundFlush()
            default: break
            }
        }
    }

    private var app: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.health)
            .environmentObject(Log.shared)
    }
}
