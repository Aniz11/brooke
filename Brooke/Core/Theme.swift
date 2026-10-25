import SwiftUI

/// Dark, minimal palette: near-black, warm white text and a champagne accent.
enum Theme {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.043)
    static let surface = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.09)
    static let text = Color(red: 0.957, green: 0.937, blue: 0.910)
    static let muted = Color(red: 0.62, green: 0.60, blue: 0.58)
    static let accent = Color(red: 0.906, green: 0.725, blue: 0.561)
    static let success = Color(red: 0.50, green: 0.80, blue: 0.64)
    static let danger = Color(red: 0.92, green: 0.46, blue: 0.43)

    static func display(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Small uppercase label used above headings.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(2.2)
            .foregroundStyle(color)
    }
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(radius: CGFloat = 22) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

/// Big pill-shaped primary button.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Capsule().fill(Theme.accent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Large on/off switch for the alarm.
struct PowerToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.12))
                    .frame(width: 84, height: 44)
                Circle()
                    .fill(configuration.isOn ? Color.black : Theme.text)
                    .frame(width: 36, height: 36)
                    .padding(4)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.isOn ? "Будильник включён" : "Будильник выключен")
    }
}

enum Format {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 1 день, 2 дня, 5 дней
    static func days(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "день" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "дня" }
        return "дней"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
