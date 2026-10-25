import SwiftUI
import UserNotifications

@main
struct BrookeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = AlarmEngine.shared
    @StateObject private var media = MediaStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(media)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // While the app is open it rings by itself, so banners stay quiet.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    // Tapping a notification opens the wake-up flow.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            AlarmEngine.shared.refresh()
            completionHandler()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            HomeView()
            if let stage = engine.wakeStage {
                WakeFlowView(stage: stage)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: engine.wakeStage)
        .onAppear { engine.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.refresh() }
        }
    }
}
