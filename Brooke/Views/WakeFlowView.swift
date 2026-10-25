import SwiftUI
import AVFoundation

struct WakeFlowView: View {
    let stage: WakeStage

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch stage {
            case .ringing:
                RingingView().transition(.opacity)
            case .video:
                VideoStageView().transition(.opacity)
            case .done:
                GoodMorningView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: stage)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - Ringing: photos + math

struct MathProblem: Equatable {
    let a: Int
    let b: Int
    var answer: Int { a * b }
    var text: String { "\(a) × \(b)" }

    /// Medium level: two-digit × one-digit, e.g. 23 × 6.
    static func random() -> MathProblem {
        var a = Int.random(in: 12...49)
        while a % 10 == 0 { a = Int.random(in: 12...49) }
        return MathProblem(a: a, b: Int.random(in: 3...9))
    }
}

struct RingingView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var media: MediaStore

    @State private var problem = MathProblem.random()
    @State private var input = ""
    @State private var state: AnswerState = .typing
    @State private var shakes: CGFloat = 0

    enum AnswerState { case typing, wrong, right }

    var body: some View {
        ZStack(alignment: .bottom) {
            Slideshow(urls: media.photos)
                .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.75), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 4) {
                        Text(Format.clock.string(from: context.date))
                            .font(Theme.display(76))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("Доброе утро. Пора вставать")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .shadow(color: .black.opacity(0.35), radius: 12)
                }
                .padding(.top, 12)

                Spacer()

                challenge
            }
        }
    }

    private var challenge: some View {
        VStack(spacing: 14) {
            Eyebrow(text: "Реши, чтобы выключить", color: .white.opacity(0.7))

            HStack(spacing: 10) {
                Text(problem.text)
                Text("=").foregroundStyle(.white.opacity(0.5))
                Text(input.isEmpty ? "?" : input)
                    .foregroundStyle(answerColor)
                    .frame(minWidth: 70, alignment: .leading)
            }
            .font(Theme.display(40, .regular))
            .monospacedDigit()
            .foregroundStyle(.white)
            .modifier(ShakeEffect(animatableData: shakes))

            NumberPad(
                onDigit: { digit in
                    guard state != .right, input.count < 4 else { return }
                    Haptics.tap()
                    if state == .wrong { input = "" }
                    state = .typing
                    input.append(digit)
                },
                onDelete: {
                    guard state != .right, !input.isEmpty else { return }
                    state = .typing
                    input.removeLast()
                },
                onSubmit: submit
            )
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var answerColor: Color {
        switch state {
        case .typing: return Theme.accent
        case .wrong: return Theme.danger
        case .right: return Theme.success
        }
    }

    private func submit() {
        guard state != .right, let value = Int(input) else { return }
        if value == problem.answer {
            state = .right
            Haptics.success()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                engine.challengeSolved()
            }
        } else {
            state = .wrong
            Haptics.error()
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard state == .wrong else { return }
                problem = MathProblem.random()
                input = ""
                state = .typing
            }
        }
    }
}

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct NumberPad: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void
    let onSubmit: () -> Void

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["⌫", "0", "✓"]]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        Button {
            switch key {
            case "⌫": onDelete()
            case "✓": onSubmit()
            default: onDigit(key)
            }
        } label: {
            Group {
                switch key {
                case "⌫":
                    Image(systemName: "delete.left").font(.system(size: 20, weight: .medium))
                case "✓":
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .bold))
                default:
                    Text(key).font(.system(size: 26, weight: .regular, design: .rounded))
                }
            }
            .foregroundStyle(key == "✓" ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(key == "✓" ? Theme.accent : Color.white.opacity(0.1))
            )
        }
        .buttonStyle(PadButtonStyle())
    }
}

struct PadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Slideshow

struct Slideshow: View {
    let urls: [URL]
    var interval: Double = 5

    @State private var current: UIImage?
    @State private var index = 0

    var body: some View {
        ZStack {
            Theme.bg
            if let current {
                KenBurnsImage(image: current, duration: interval + 2)
                    .id(index)
                    .transition(.opacity)
            } else if urls.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34, weight: .light))
                    Text("Добавь фото в настройках")
                        .font(.system(size: 14))
                }
                .foregroundStyle(Theme.muted)
                .offset(y: -80)
            }
        }
        .task(id: urls) { await run() }
    }

    private func run() async {
        guard !urls.isEmpty else {
            current = nil
            return
        }
        let order = urls.shuffled()
        var position = 0
        while !Task.isCancelled {
            let image = await ImageLoader.load(order[position % order.count], maxPixel: 2000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                current = image
                index += 1
            }
            position += 1
            if order.count == 1 { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

struct KenBurnsImage: View {
    let image: UIImage
    let duration: Double
    @State private var zoomed = false

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoomed ? 1.1 : 1.0)
                .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: duration)) { zoomed = true }
        }
    }
}

// MARK: - Video

struct VideoStageView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var media: MediaStore
    @State private var url: URL?
    @State private var progress: Double = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let url {
                PlayerView(url: url, progress: $progress) {
                    engine.videoFinished()
                }
                .ignoresSafeArea()
            }
            VStack(spacing: 10) {
                Text("Досмотри до конца")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .onAppear {
            url = media.videos.randomElement()
            if url == nil { engine.videoFinished() }
        }
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Full-screen video without controls: it can't be paused or skipped.
struct PlayerView: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.start(url: url, in: view)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PlayerView
        private var player: AVPlayer?
        private var timeObserver: Any?
        private var observers: [NSObjectProtocol] = []
        private var statusObservation: NSKeyValueObservation?
        private var finished = false

        init(_ parent: PlayerView) {
            self.parent = parent
        }

        func start(url: URL, in view: PlayerUIView) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true)

            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            view.playerLayer.player = player
            self.player = player

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
            observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
            // Keep playing after the phone was locked and unlocked.
            observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in self?.finish() }
            }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.updateProgress(time) }
            }
            player.play()
        }

        private func resume() {
            guard !finished else { return }
            player?.play()
        }

        private func updateProgress(_ time: CMTime) {
            guard let duration = player?.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0 else { return }
            parent.progress = min(1, max(0, time.seconds / duration))
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            parent.progress = 1
            parent.onFinish()
        }

        func stop() {
            player?.pause()
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            statusObservation = nil
            player = nil
        }
    }
}

// MARK: - Good morning

struct GoodMorningView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(
                colors: [Theme.accent.opacity(0.28), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 460
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Eyebrow(text: wakeText, color: Theme.accent)
                Text("Доброе утро")
                    .font(Theme.display(50, .regular))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 12)

                VStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(engine.streak > 0 ? Theme.accent : Theme.muted)
                        .symbolEffect(.bounce, value: appeared)
                    Text("\(engine.streak)")
                        .font(Theme.display(72))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    Text("\(Format.days(engine.streak)) подряд")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 40)

                Text(message)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                    .padding(.horizontal, 12)

                Spacer()

                Button("Начать день") { engine.finishMorning() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { appeared = true }
        }
    }

    private var wakeText: String {
        guard let time = engine.lastWakeTime else { return "" }
        return "Встал в \(Format.clock.string(from: time))"
    }

    private var message: String {
        if engine.lastWakeWasTest {
            return "Это была проверка — всё работает. Серия не изменилась."
        }
        if !engine.lastWakeOnTime {
            return "Сегодня позже, чем через 15 минут после звонка. Серия начнётся заново — завтра получится."
        }
        if engine.streak <= 1 {
            return "Первый день серии. Завтра — второй."
        }
        return "Так держать. Не прерывай серию."
    }
}
