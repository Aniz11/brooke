import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var media: MediaStore
    @State private var showSettings = false
    @State private var testStarted = false

    var body: some View {
        ZStack {
            HomeBackdrop(photo: media.photos.first)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 20)
                clock
                Spacer(minLength: 28)
                VStack(spacing: 12) {
                    streakCard
                    ForEach(hints) { hint in
                        HintRow(hint: hint)
                    }
                    testButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(media)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text("BROOKE")
                .font(.system(size: 13, weight: .semibold))
                .tracking(5)
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Настройки")
        }
    }

    private var clock: some View {
        VStack(spacing: 8) {
            Eyebrow(
                text: engine.enabled ? "Будильник включён" : "Будильник выключен",
                color: engine.enabled ? Theme.accent : Theme.muted
            )
            Button {
                showSettings = true
            } label: {
                Text(engine.timeString)
                    .font(Theme.display(104))
                    .monospacedDigit()
                    .foregroundStyle(engine.enabled ? Theme.text : Theme.muted)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .contentTransition(.numericText())

            Toggle("Будильник", isOn: $engine.enabled)
                .toggleStyle(PowerToggleStyle())
                .padding(.top, 20)
        }
    }

    private var subtitle: String {
        guard engine.enabled else { return "Каждый день · включи, чтобы зазвонил" }
        let countdown = engine.countdownText(from: engine.now)
        return countdown.isEmpty ? "Каждый день" : "Каждый день · \(countdown)"
    }

    private var streakCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(engine.streak > 0 ? 0.16 : 0.07))
                    .frame(width: 54, height: 54)
                Image(systemName: "flame.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(engine.streak > 0 ? Theme.accent : Theme.muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(engine.streak) \(Format.days(engine.streak)) подряд")
                    .font(Theme.display(24, .regular))
                    .foregroundStyle(Theme.text)
                Text(engine.bestStreak > 0 ? "Рекорд: \(engine.bestStreak) \(Format.days(engine.bestStreak))" : "Встань вовремя — начнётся серия")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card()
    }

    private var testButton: some View {
        Button {
            engine.startTest()
            testStarted = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                testStarted = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: testStarted ? "hourglass" : "play.circle")
                Text(testStarted ? "Зазвонит через 10 секунд — можешь заблокировать экран" : "Проверить: зазвонит через 10 секунд")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .disabled(testStarted)
    }

    // MARK: Hints

    private var hints: [Hint] {
        var list: [Hint] = []
        if engine.enabled {
            if engine.usesAlarmKit {
                list.append(Hint(icon: "checkmark.seal.fill", text: "AlarmKit включён: зазвонит, даже если приложение закрыто.", tint: Theme.success))
            } else {
                list.append(Hint(icon: "moon.zzz.fill", text: "На ночь сверни Brooke, но не смахивай его. Лучше поставить на зарядку.", tint: Theme.accent))
            }
            if engine.outputVolume < 0.5 {
                list.append(Hint(icon: "speaker.wave.1.fill", text: "Громкость низкая — прибавь звук кнопками сбоку.", tint: Theme.danger))
            }
            if !engine.notificationsAllowed {
                list.append(Hint(icon: "bell.slash.fill", text: "Уведомления выключены — включи их в Настройках iPhone, это запасной сигнал.", tint: Theme.danger))
            }
        }
        if media.trackURL == nil {
            list.append(Hint(icon: "music.note", text: "Добавь свой трек — пока звучит стандартный сигнал.", tint: Theme.muted))
        }
        if media.photos.isEmpty {
            list.append(Hint(icon: "photo", text: "Добавь фото в настройках — они будут на экране будильника.", tint: Theme.muted))
        }
        return Array(list.prefix(3))
    }
}

struct Hint: Identifiable {
    let icon: String
    let text: String
    let tint: Color
    var id: String { text }
}

struct HintRow: View {
    let hint: Hint

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: hint.icon)
                .font(.system(size: 15))
                .foregroundStyle(hint.tint)
                .frame(width: 22)
            Text(hint.text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .card(radius: 18)
    }
}

/// Her photo, faded far into the background of the home screen.
struct HomeBackdrop: View {
    let photo: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.bg
            if let image {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .opacity(0.32)
                    .transition(.opacity)
                LinearGradient(
                    colors: [Theme.bg.opacity(0.35), Theme.bg.opacity(0.8), Theme.bg],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .task(id: photo) {
            let loaded = await ImageLoader.load(photo, maxPixel: 1400)
            withAnimation(.easeInOut(duration: 0.6)) { image = loaded }
        }
    }
}
