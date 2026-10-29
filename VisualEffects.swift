import SwiftUI

private final class EffectMotion: ObservableObject {
    @Published var active = false
}

struct AmbientBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Palette.background
                RadialGradient(colors: [Palette.iris.opacity(0.17), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.75)
                RadialGradient(colors: [Palette.accent.opacity(0.08), .clear], center: .topLeading,
                               startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.6)
                RadialGradient(colors: [Palette.mint.opacity(0.045), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.55)
                Canvas { context, canvas in
                    for x in stride(from: CGFloat(12), to: canvas.width, by: 28) {
                        for y in stride(from: CGFloat(12), to: canvas.height, by: 28) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.035)))
                        }
                    }
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ScanPulseView: View {
    var isScanning: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isScanning || scenePhase != .active)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion || !isScanning || scenePhase != .active ? 0.25 : seconds.truncatingRemainder(dividingBy: 3) / 3
            ZStack {
                ForEach(0..<3) { index in
                    Circle()
                        .stroke(Palette.accent.opacity(0.12 + Double(index) * 0.04), lineWidth: 1)
                        .padding(CGFloat(index) * 18)
                }
                if isScanning {
                    Circle()
                        .stroke(Palette.accent.opacity(0.65 * (1 - phase)), lineWidth: 1.5)
                        .scaleEffect(0.3 + phase * 0.7)
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [.clear, Palette.accent.opacity(0.9)], center: .center), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(phase * 360))
                        .padding(5)
                }
                Circle().fill(Palette.accent.opacity(0.12)).frame(width: 54, height: 54)
                Image(systemName: isScanning ? "sparkle.magnifyingglass" : "checkmark.shield.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .shadow(color: Palette.accent.opacity(0.4), radius: 12)
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityHidden(true)
    }
}

struct MotionButtonStyle: ButtonStyle {
    var prominent: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        MotionButtonBody(configuration: configuration, prominent: prominent)
    }
    private struct MotionButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @StateObject private var hover = EffectMotion()
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.90))
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: prominent ? [Palette.accent.opacity(hover.active && isEnabled ? 0.96 : 0.85), Palette.accentDeep] : [Color.white.opacity(hover.active && isEnabled ? 0.11 : 0.065), Color.white.opacity(0.035)], startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(prominent ? 0.16 : 0.12), lineWidth: 1)
                }
                .shadow(color: prominent && hover.active ? Palette.accent.opacity(0.08) : .clear, radius: 14, y: 4)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed && isEnabled ? 0.98 : 1))
                .opacity(isEnabled ? 1 : 0.42)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hover.active)
                .onHover { hover.active = $0 && isEnabled }
        }
    }
}


/// Compact custom checkbox with an animated check and standard toggle semantics.
struct AnimatedCheckStyle: ToggleStyle {
    var title: String = "בחירת קובץ"
    func makeBody(configuration: Configuration) -> some View {
        CheckBody(configuration: configuration, title: title)
    }
    private struct CheckBody: View {
        let configuration: ToggleStyle.Configuration
        let title: String
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)) {
                    configuration.isOn.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(configuration.isOn ? Palette.accent : Color.white.opacity(0.05))
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(configuration.isOn ? Palette.accent : Color.white.opacity(0.23), lineWidth: 1.2)
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Color(red: 0.02, green: 0.1, blue: 0.18))
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .shadow(color: configuration.isOn ? Palette.accent.opacity(0.08) : .clear, radius: 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CheckPressStyle())
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel(title)
            .accessibilityValue(configuration.isOn ? "נבחר" : "לא נבחר")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        }
    }
    private struct CheckPressStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.62), value: configuration.isPressed)
        }
    }
}

enum Palette {
    static let accent = Color(red: 0.61, green: 0.70, blue: 1.0)
    static let accentDeep = Color(red: 0.32, green: 0.36, blue: 0.80)
    static let iris = Color(red: 0.57, green: 0.43, blue: 0.94)
    static let surface = Color(red: 0.075, green: 0.093, blue: 0.15)
    static let mint = Color(red: 0.40, green: 0.84, blue: 0.73)
    static let background = Color(red: 0.027, green: 0.037, blue: 0.065)
}

/// A small, native vector companion for “מקום לנשום”. Motion communicates state,
/// never progress or a promise that disk space has already been reclaimed.
enum BreathMood { case ready, searching, relieved }

struct BreathCompanion: View {
    var mode: BreathMood = .ready
    var diameter: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion || scenePhase != .active ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breath = sin(time * (mode == .searching ? 1.8 : 1.2))
            let drift = mode == .searching ? sin(time * 0.9) : 0
            ZStack {
                Circle().fill(Palette.accent.opacity(0.045)).padding(3)
                Circle().stroke(Palette.accent.opacity(0.10), lineWidth: 1).padding(8)
                    .scaleEffect(1 + breath * 0.025)
                // Soft shoulders and face make a character, without a noisy illustration.
                Capsule().fill(Palette.accent.opacity(0.17))
                    .frame(width: 57, height: 19).offset(y: 27)
                    .scaleEffect(x: 1 + breath * 0.035, y: 1)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.75, green: 0.84, blue: 1), Palette.accent, Palette.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 49, height: 53)
                    .overlay(alignment: .topLeading) {
                        Capsule().fill(.white.opacity(0.38)).frame(width: 15, height: 4).rotationEffect(.degrees(-28)).offset(x: 8, y: 9)
                    }
                    .shadow(color: Palette.accent.opacity(0.2), radius: 8, y: 4)
                    .scaleEffect(x: 1 + breath * 0.018, y: 1 + breath * 0.035)
                HStack(spacing: 13) {
                    eye
                    eye
                }.offset(x: drift * 2, y: -4)
                if mode == .relieved {
                    // A relaxed smile and a little exhale: relief, rather than celebration.
                    Capsule().trim(from: 0.05, to: 0.45)
                        .stroke(Color(red: 0.10, green: 0.18, blue: 0.34), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 10, height: 6).rotationEffect(.degrees(180)).offset(y: 8)
                    ForEach(0..<3) { index in
                        Capsule().fill(Palette.mint.opacity(0.25 + Double(index) * 0.1))
                            .frame(width: CGFloat(10 - index * 2), height: 2)
                            .offset(x: 33 + CGFloat(index) * 5 + CGFloat(breath) * 2, y: CGFloat(4 + index * 6))
                    }
                } else {
                    Capsule().fill(Color(red: 0.10, green: 0.18, blue: 0.34).opacity(0.7))
                        .frame(width: mode == .searching ? 5 : 4, height: 3 + CGFloat(breath + 1)).offset(y: 9)
                }
                if mode == .searching {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color.white)
                        .shadow(color: Palette.accentDeep.opacity(0.7), radius: 2, y: 2)
                        .rotationEffect(.degrees(drift * 12 - 12))
                        .offset(x: 23 + drift * 5, y: 15 + cos(time * 0.9) * 3)
                }
            }
            .frame(width: 92, height: 92)
            .offset(y: CGFloat(breath) * (mode == .searching ? 0.6 : 1.4))
            .scaleEffect(diameter / 92)
            .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private var eye: some View {
        Group {
            if mode == .relieved {
                Capsule().fill(Color(red: 0.10, green: 0.18, blue: 0.34)).frame(width: 7, height: 2)
            } else {
                Capsule().fill(Color(red: 0.10, green: 0.18, blue: 0.34)).frame(width: 3, height: 5)
            }
        }
    }
}

/// Keeps action groups readable when the window cannot fit a horizontal row.
struct ResponsiveRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: spacing) { content() }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ResponsiveSheet: ViewModifier {
    let width: CGFloat
    let height: CGFloat?
    func body(content: Content) -> some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1024, height: 768)
        let availableWidth = max(320, screen.width - 80)
        let availableHeight = max(360, screen.height - 100)
        return content.frame(minWidth: min(420, availableWidth),
                             idealWidth: min(width, availableWidth), maxWidth: min(width, availableWidth),
                             minHeight: height.map { min(360, $0, availableHeight) },
                             idealHeight: height.map { min($0, availableHeight) }, maxHeight: availableHeight)
    }
}

extension View {
    func responsiveSheet(width: CGFloat, height: CGFloat? = nil) -> some View {
        modifier(ResponsiveSheet(width: width, height: height))
    }
}

/// All alternatives stay visible; selection never opens a system dropdown.
struct VisibleChoices<Value: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button { selection = option.1 } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selection == option.1 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == option.1 ? Palette.accent : .secondary)
                            Text(option.0).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }.padding(10).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .background(selection == option.1 ? Palette.accent.opacity(0.13) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection == option.1 ? Palette.accent.opacity(0.4) : Color.white.opacity(0.08)))
                    }.buttonStyle(.plain).studioHover(radius: 10)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection == option.1)
                        .accessibilityAddTraits(selection == option.1 ? .isSelected : [])
                }
            }
        }
    }
}

/// Compact controls share one material and tactile motion across every screen.
struct StudioButtonStyle: ButtonStyle {
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        StudioButton(configuration: configuration, prominent: prominent)
    }
    private struct StudioButton: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .frame(minHeight: 28)
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.86))
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: prominent
                            ? [Color(red: 0.43, green: 0.49, blue: 0.96), Palette.accentDeep, Palette.iris.opacity(0.8)]
                            : [Color.white.opacity(hovered ? 0.105 : 0.065), Color.white.opacity(hovered ? 0.045 : 0.025)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(prominent ? 0.3 : hovered ? 0.22 : 0.12), .white.opacity(0.025)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: prominent ? Palette.iris.opacity(hovered ? 0.24 : 0.1) : .black.opacity(0.13), radius: hovered ? 12 : 5, y: 3)
                .scaleEffect(reduceMotion || !enabled ? 1 : configuration.isPressed ? 0.97 : 1)
                .offset(y: reduceMotion || !enabled || !hovered || configuration.isPressed ? 0 : -1)
                .opacity(enabled ? 1 : 0.34)
                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.76), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.17), value: hovered)
                .onHover { hovered = $0 && enabled }
        }
    }
}

private struct StudioPanel: ViewModifier {
    let radius: CGFloat
    let accented: Bool
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Palette.surface.opacity(0.97), Palette.surface.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(LinearGradient(colors: [accented ? Palette.accent.opacity(0.32) : .white.opacity(0.13), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }.shadow(color: .black.opacity(0.15), radius: 12, y: 5)
    }
}

private struct StudioHover: ViewModifier {
    let radius: CGFloat
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Palette.accent.opacity(hovered ? 0.075 : 0), Palette.iris.opacity(hovered ? 0.04 : 0)], startPoint: .leading, endPoint: .trailing))
        }.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(hovered ? 0.1 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }.onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
    }
}

extension View {
    func studioPanel(radius: CGFloat = 16, accented: Bool = false) -> some View {
        modifier(StudioPanel(radius: radius, accented: accented))
    }
    func studioHover(radius: CGFloat = 12) -> some View {
        modifier(StudioHover(radius: radius))
    }
}
