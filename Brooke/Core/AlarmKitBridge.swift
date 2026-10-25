import Foundation
import SwiftUI
#if canImport(AlarmKit) && !NO_ALARMKIT
import AlarmKit
import AppIntents
#endif

/// Thin wrapper around AlarmKit (iOS 26+).
/// On iOS 18 every call is a no-op and the app uses its background mode instead.
@MainActor
enum AlarmKitBridge {
    private static var dailyID: UUID { storedID("alarmkit.daily") }
    private static var testID: UUID { storedID("alarmkit.test") }

    private static func storedID(_ key: String) -> UUID {
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    /// The phone runs iOS 26+ and the app was built with AlarmKit.
    static var isSupported: Bool {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// AlarmKit is supported and the person allowed it.
    static var isActive: Bool {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) {
            return AlarmManager.shared.authorizationState == .authorized
        }
        #endif
        return false
    }

    static var isUndetermined: Bool {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) {
            return AlarmManager.shared.authorizationState == .notDetermined
        }
        #endif
        return false
    }

    static func requestAuthorization() async -> Bool {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) {
            do {
                return try await AlarmManager.shared.requestAuthorization() == .authorized
            } catch {
                return false
            }
        }
        #endif
        return false
    }

    static func scheduleDaily(hour: Int, minute: Int) async {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) {
            cancelAll()
            let days: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
            let schedule = Alarm.Schedule.relative(.init(time: time, repeats: .weekly(days)))
            await BrookeAlarmScheduler.schedule(id: dailyID, schedule: schedule)
        }
        #endif
    }

    static func scheduleTest(at date: Date) async {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) {
            try? AlarmManager.shared.cancel(id: testID)
            await BrookeAlarmScheduler.schedule(id: testID, schedule: .fixed(date))
        }
        #endif
    }

    static func cancelAll() {
        #if canImport(AlarmKit) && !NO_ALARMKIT
        if #available(iOS 26.0, *) {
            try? AlarmManager.shared.cancel(id: dailyID)
            try? AlarmManager.shared.cancel(id: testID)
        }
        #endif
    }
}

#if canImport(AlarmKit) && !NO_ALARMKIT

@available(iOS 26.0, *)
struct BrookeAlarmMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
@MainActor
enum BrookeAlarmScheduler {
    static func schedule(id: UUID, schedule: Alarm.Schedule) async {
        let stopButton = AlarmButton(text: "Встаю", textColor: .black, systemImageName: "sun.max.fill")
        let openButton = AlarmButton(text: "Открыть", textColor: .white, systemImageName: "arrow.up.forward.app")
        let alert = AlarmPresentation.Alert(
            title: "Brooke · пора вставать",
            stopButton: stopButton,
            secondaryButton: openButton,
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<BrookeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            tintColor: Theme.accent
        )
        let configuration = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: OpenBrookeIntent(),
            secondaryIntent: OpenBrookeIntent()
        )
        _ = try? await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }
}

/// Runs when the alarm is stopped: opens Brooke straight into the wake-up flow.
@available(iOS 26.0, *)
struct OpenBrookeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Открыть Brooke"
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { AlarmEngine.shared.refresh() }
        return .result()
    }
}

#endif
