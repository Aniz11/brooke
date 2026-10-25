import Foundation
import AVFoundation
import UserNotifications
import UIKit

enum WakeStage: Equatable {
    case ringing   // photos + math problem, music playing
    case video     // video, cannot be skipped
    case done      // "Доброе утро" screen
}

/// The heart of the app: keeps the alarm armed, rings, and tracks the streak.
///
/// iOS 18 mode: while armed, the app quietly plays silence in the background so
/// iOS keeps it running, and at the alarm time it starts the chosen track at full
/// volume (this ignores the silent switch). Backup notifications with a 29-second
/// clip of the track fire every 30 seconds in case iOS closed the app.
///
/// iOS 26 mode: AlarmKit rings like the built-in Clock app; stopping it opens the
/// app, which then plays the track until the math problem is solved.
@MainActor
final class AlarmEngine: ObservableObject {
    static let shared = AlarmEngine()

    // Settings
    @Published private(set) var hour: Int
    @Published private(set) var minute: Int
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: K.enabled)
            armNext()
        }
    }

    // State shown in the UI
    @Published private(set) var nextFire: Date?
    @Published private(set) var wakeStage: WakeStage?
    @Published private(set) var isRinging = false
    @Published private(set) var streak = 0
    @Published private(set) var bestStreak = 0
    @Published private(set) var lastWakeTime: Date?
    @Published private(set) var lastWakeOnTime = true
    @Published private(set) var lastWakeWasTest = false
    @Published private(set) var usesAlarmKit = false
    @Published private(set) var notificationsAllowed = true
    @Published private(set) var outputVolume: Float = 1
    @Published private(set) var now = Date()

    /// How long after the alarm time opening the app still counts as "the alarm is ringing".
    static let wakeWindow: TimeInterval = 2 * 60 * 60
    /// Solving within this time keeps the streak going.
    static let onTimeLimit: TimeInterval = 15 * 60

    private static let backupCount = 40          // 40 × 30 s = 20 minutes
    private static let backupSpacing: TimeInterval = 30
    private static let backupPrefix = "brooke.backup."
    private static let ringingBannerID = "brooke.ringing"

    private let defaults = UserDefaults.standard
    private var silentPlayer: AVAudioPlayer?
    private var alarmPlayer: AVAudioPlayer?
    private var ticker: Timer?
    private var lastBackupRoll = Date.distantPast
    private var prerolledFor: Date?
    private var started = false
    private var ringStartedAt: Date?
    private var musicTimedOut = false

    /// Music stops by itself after this long, so it doesn't play all day if nobody answers.
    private static let maxRingDuration: TimeInterval = 30 * 60

    private enum K {
        static let hour = "hour"
        static let minute = "minute"
        static let enabled = "enabled"
        static let armedFire = "armedFire"
        static let armedIsTest = "armedIsTest"
        static let solvedFire = "solvedFire"
        static let streak = "streak"
        static let best = "bestStreak"
        static let lastSuccessDay = "lastSuccessDay"
    }

    private init() {
        let stored = UserDefaults.standard
        hour = stored.object(forKey: K.hour) as? Int ?? 6
        minute = stored.object(forKey: K.minute) as? Int ?? 0
        enabled = stored.object(forKey: K.enabled) as? Bool ?? false
        bestStreak = stored.integer(forKey: K.best)
    }

    // MARK: Persisted alarm state

    /// The exact moment the currently armed alarm should ring.
    private var armedFire: Date? {
        get {
            let t = defaults.double(forKey: K.armedFire)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: K.armedFire)
            } else {
                defaults.removeObject(forKey: K.armedFire)
            }
        }
    }

    private var isTestRun: Bool {
        get { defaults.bool(forKey: K.armedIsTest) }
        set { defaults.set(newValue, forKey: K.armedIsTest) }
    }

    private func isHandled(_ fire: Date) -> Bool {
        abs(defaults.double(forKey: K.solvedFire) - fire.timeIntervalSince1970) < 1
    }

    private func markHandled(_ fire: Date) {
        defaults.set(fire.timeIntervalSince1970, forKey: K.solvedFire)
    }

    var timeString: String { String(format: "%02d:%02d", hour, minute) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in AlarmEngine.shared.refreshNotificationStatus() }
        }
        observeAudioSession()
        if AlarmKitBridge.isSupported && AlarmKitBridge.isUndetermined {
            Task {
                _ = await AlarmKitBridge.requestAuthorization()
                self.refresh()
            }
        }
        refresh()
    }

    /// Called on launch, when the app comes to the foreground,
    /// when a notification is tapped and when AlarmKit's button opens the app.
    func refresh() {
        let alarmKit = AlarmKitBridge.isActive
        let modeChanged = alarmKit != usesAlarmKit
        usesAlarmKit = alarmKit
        refreshStreak()
        refreshNotificationStatus()
        outputVolume = AVAudioSession.sharedInstance().outputVolume

        if isRinging || wakeStage != nil { return }

        if let fire = armedFire, !isHandled(fire) {
            let late = Date().timeIntervalSince(fire)
            if late >= 0 {
                if late < Self.wakeWindow {
                    startRinging()
                    return
                }
                if !isTestRun { resetStreak() }
                markHandled(fire)
            }
        }

        if modeChanged || !isArmedForFuture {
            armNext()
        } else {
            keepArmed()
        }
    }

    private var isArmedForFuture: Bool {
        guard enabled, let fire = armedFire else { return false }
        return fire > Date() && !isHandled(fire)
    }

    // MARK: Arming

    func setTime(hour: Int, minute: Int) {
        guard hour != self.hour || minute != self.minute else { return }
        self.hour = hour
        self.minute = minute
        defaults.set(hour, forKey: K.hour)
        defaults.set(minute, forKey: K.minute)
        armNext()
    }

    /// Schedules the next regular alarm (or disarms when switched off).
    private func armNext() {
        guard wakeStage == nil, !isRinging else { return }
        cancelBackups()
        isTestRun = false
        prerolledFor = nil

        guard enabled else {
            armedFire = nil
            nextFire = nil
            stopSilentLoop()
            stopTicker()
            AlarmKitBridge.cancelAll()
            return
        }

        let fire = Self.nextOccurrence(hour: hour, minute: minute, after: Date())
        armedFire = fire
        nextFire = fire

        if usesAlarmKit {
            stopSilentLoop()
            let h = hour, m = minute
            Task { await AlarmKitBridge.scheduleDaily(hour: h, minute: m) }
        } else {
            AlarmKitBridge.cancelAll()
            scheduleBackups(startingAt: fire)
            startSilentLoop()
        }
        startTicker()
    }

    private func keepArmed() {
        nextFire = armedFire
        if !usesAlarmKit { startSilentLoop() }
        startTicker()
    }

    /// Rings in a few seconds so the whole flow can be checked. Doesn't touch the streak.
    func startTest(in seconds: TimeInterval = 10) {
        guard wakeStage == nil, !isRinging else { return }
        cancelBackups()
        prerolledFor = nil
        let fire = Date().addingTimeInterval(seconds)
        isTestRun = true
        armedFire = fire
        nextFire = fire
        if usesAlarmKit {
            Task { await AlarmKitBridge.scheduleTest(at: fire) }
        } else {
            scheduleBackups(startingAt: fire)
            startSilentLoop()
        }
        startTicker()
    }

    static func nextOccurrence(hour: Int, minute: Int, after date: Date) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }

    // MARK: Ticker

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AlarmEngine.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        let volume = AVAudioSession.sharedInstance().outputVolume
        if abs(volume - outputVolume) > 0.01 { outputVolume = volume }
        guard let fire = armedFire, !isHandled(fire) else { return }

        if isRinging {
            if let start = ringStartedAt, now.timeIntervalSince(start) > Self.maxRingDuration {
                if !musicTimedOut {
                    musicTimedOut = true
                    stopAlarmMusic()
                    cancelBackups()
                }
                return
            }
            if !usesAlarmKit, now.timeIntervalSince(lastBackupRoll) > 20 { rollBackups() }
            return
        }
        guard wakeStage == nil else { return }

        let remaining = fire.timeIntervalSince(now)

        if usesAlarmKit {
            // AlarmKit rings by itself; if the app happens to be open, join in.
            if remaining <= 0, remaining > -Self.wakeWindow,
               UIApplication.shared.applicationState == .active {
                startRinging()
            }
            return
        }

        // Just before ringing, push the backups back so they don't play on top of the music.
        if remaining <= 6, remaining > 0, prerolledFor != fire {
            prerolledFor = fire
            scheduleBackups(startingAt: fire.addingTimeInterval(45))
        }

        if remaining <= 0, remaining > -Self.wakeWindow {
            startRinging()
        }
    }

    // MARK: Ringing

    func startRinging() {
        guard !isRinging else { return }
        isRinging = true
        ringStartedAt = Date()
        musicTimedOut = false
        wakeStage = .ringing
        stopSilentLoop()
        if !usesAlarmKit { rollBackups() }
        playAlarmMusic()
        postRingingBanner()
    }

    private func playAlarmMusic() {
        configureSession(mixWithOthers: false)
        let url = MediaStore.shared.trackURL ?? SoundFactory.fallbackToneURL()
        let player = (try? AVAudioPlayer(contentsOf: url))
            ?? (try? AVAudioPlayer(contentsOf: SoundFactory.fallbackToneURL()))
        guard let player else { return }
        player.numberOfLoops = -1
        player.volume = 0.3
        player.prepareToPlay()
        player.play()
        player.setVolume(1.0, fadeDuration: 20)
        alarmPlayer = player
    }

    private func stopAlarmMusic() {
        alarmPlayer?.stop()
        alarmPlayer = nil
    }

    /// The math problem was solved.
    func challengeSolved() {
        guard isRinging else { return }
        stopAlarmMusic()
        cancelBackups()
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        isRinging = false
        ringStartedAt = nil
        musicTimedOut = false

        let fire = armedFire ?? Date()
        let solvedAt = Date()
        markHandled(fire)
        lastWakeTime = solvedAt
        lastWakeWasTest = isTestRun
        if isTestRun {
            lastWakeOnTime = true
        } else {
            recordWake(fire: fire, solvedAt: solvedAt)
        }
        wakeStage = MediaStore.shared.videos.isEmpty ? .done : .video
    }

    func videoFinished() {
        guard wakeStage == .video else { return }
        wakeStage = .done
    }

    /// "Начать день" — close the flow and arm tomorrow's alarm.
    func finishMorning() {
        wakeStage = nil
        isTestRun = false
        armNext()
    }

    // MARK: Streak

    private func recordWake(fire: Date, solvedAt: Date) {
        let onTime = solvedAt.timeIntervalSince(fire) <= Self.onTimeLimit
        lastWakeOnTime = onTime
        guard onTime else {
            resetStreak()
            return
        }
        let day = Format.dayKey.string(from: fire)
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: fire).map { Format.dayKey.string(from: $0) }
        let last = defaults.string(forKey: K.lastSuccessDay)
        var value = defaults.integer(forKey: K.streak)
        if last == day {
            value = max(value, 1)
        } else if last != nil && last == previousDay {
            value += 1
        } else {
            value = 1
        }
        defaults.set(value, forKey: K.streak)
        defaults.set(day, forKey: K.lastSuccessDay)
        if value > bestStreak {
            bestStreak = value
            defaults.set(value, forKey: K.best)
        }
        refreshStreak()
    }

    private func refreshStreak() {
        guard let last = defaults.string(forKey: K.lastSuccessDay) else {
            streak = 0
            return
        }
        let today = Format.dayKey.string(from: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map { Format.dayKey.string(from: $0) }
        streak = (last == today || last == yesterday) ? defaults.integer(forKey: K.streak) : 0
    }

    private func resetStreak() {
        defaults.set(0, forKey: K.streak)
        defaults.removeObject(forKey: K.lastSuccessDay)
        refreshStreak()
    }

    func clearStats() {
        resetStreak()
        bestStreak = 0
        defaults.set(0, forKey: K.best)
    }

    func countdownText(from date: Date) -> String {
        guard let fire = nextFire, fire > date else { return "" }
        let minutes = Int((fire.timeIntervalSince(date) / 60).rounded(.up))
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "через \(m) мин" }
        return "через \(h) ч \(m) мин"
    }

    // MARK: Audio session

    private func configureSession(mixWithOthers: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: mixWithOthers ? [.mixWithOthers] : [])
        try? session.setActive(true)
    }

    private func startSilentLoop() {
        if let silentPlayer, silentPlayer.isPlaying { return }
        configureSession(mixWithOthers: true)
        guard let player = try? AVAudioPlayer(contentsOf: SoundFactory.silentLoopURL()) else { return }
        player.numberOfLoops = -1
        player.volume = 1
        player.prepareToPlay()
        player.play()
        silentPlayer = player
    }

    private func stopSilentLoop() {
        silentPlayer?.stop()
        silentPlayer = nil
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in AlarmEngine.shared.resumeAudio() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let engine = AlarmEngine.shared
                engine.silentPlayer = nil
                engine.resumeAudio()
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AlarmEngine.shared.resumeAudio() }
        }
    }

    /// Restarts whatever should be playing after a call, Siri or another app took the audio.
    private func resumeAudio() {
        if isRinging {
            guard !musicTimedOut else { return }
            if let alarmPlayer {
                configureSession(mixWithOthers: false)
                alarmPlayer.play()
            } else {
                playAlarmMusic()
            }
        } else if wakeStage == nil, enabled, !usesAlarmKit, let fire = armedFire, fire > Date() {
            silentPlayer?.stop()
            silentPlayer = nil
            startSilentLoop()
        }
    }

    // MARK: Notifications

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in AlarmEngine.shared.notificationsAllowed = allowed }
        }
    }

    private static var backupIDs: [String] {
        (0..<backupCount).map { backupPrefix + String($0) }
    }

    private func scheduleBackups(startingAt start: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.backupIDs)
        let soundName = defaults.string(forKey: Keys.notificationSound)
        for index in 0..<Self.backupCount {
            let date = start.addingTimeInterval(Double(index) * Self.backupSpacing)
            let interval = date.timeIntervalSinceNow
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Brooke"
            content.body = index == 0
                ? "Доброе утро. Пора вставать ☀️"
                : "Ты ещё не встал. Открой Brooke и выключи будильник."
            if let soundName {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
            } else {
                content.sound = .default
            }
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.add(UNNotificationRequest(identifier: Self.backupPrefix + String(index), content: content, trigger: trigger))
        }
    }

    /// While ringing, keep the backups 45 s ahead: if the app gets closed, they take over.
    private func rollBackups() {
        lastBackupRoll = Date()
        scheduleBackups(startingAt: Date().addingTimeInterval(45))
    }

    private func cancelBackups() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.backupIDs)
    }

    /// A silent banner so the lock screen shows what's going on; tapping it opens the app.
    private func postRingingBanner() {
        let content = UNMutableNotificationContent()
        content.title = "Brooke"
        content.body = "Пора вставать. Нажми, чтобы выключить будильник."
        content.sound = nil
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: Self.ringingBannerID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
