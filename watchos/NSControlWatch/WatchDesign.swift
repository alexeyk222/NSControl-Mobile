import SwiftUI

/// The look chosen on the iPhone («Настройки → Оформление»), sent with
/// every state snapshot as `design` (TripController.watchExtras) and kept
/// for the next launch. Colours are the dark palettes of the design
/// handoff (tokens.json); the form of the indicator is the main sign, the
/// colour only confirms it.
enum WatchDesign: String {
    case cockpit, companion, roadsign

    static let storageKey = "nscontrol.design"

    static var stored: WatchDesign {
        WatchDesign(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .cockpit
    }

    func store() { UserDefaults.standard.set(rawValue, forKey: Self.storageKey) }

    /// Normal state (never green).
    var accent: Color {
        switch self {
        case .cockpit: return Color(hex: 0x7CC8E8)
        case .companion: return Color(hex: 0xC9B8F5)
        case .roadsign: return Color(hex: 0x5B9BF0)
        }
    }

    var background: Color {
        self == .companion ? Color(hex: 0x0E0C10) : .black
    }

    var secondary: Color {
        switch self {
        case .cockpit: return Color(hex: 0x9BA6B0)
        case .companion: return Color(hex: 0xB0A6B5)
        case .roadsign: return Color(hex: 0xB3B3B3)
        }
    }

    var pause: Color {
        switch self {
        case .cockpit: return Color(hex: 0x8A949D)
        case .companion: return Color(hex: 0xA49AA9)
        case .roadsign: return Color(hex: 0xA0A0A0)
        }
    }

    var idle: Color {
        switch self {
        case .cockpit: return Color(hex: 0x5E6870)
        case .companion: return Color(hex: 0x6E6575)
        case .roadsign: return Color(hex: 0x6A6A6A)
        }
    }

    /// Type of the look: Geologica / Nunito / Onest on the phone; the
    /// watch uses the system font in a close design and weight.
    func font(_ size: CGFloat, heavy: Bool = false) -> Font {
        switch self {
        case .cockpit: return .system(size: size, weight: heavy ? .heavy : .semibold)
        case .companion: return .system(size: size, weight: heavy ? .black : .bold, design: .rounded)
        case .roadsign: return .system(size: size, weight: heavy ? .black : .heavy)
        }
    }

    static let attention = Color(hex: 0xF2D04B)
    static let advice = Color(hex: 0xF2A33A)
    /// The only red, on the alarm.
    static let alarm = Color(hex: 0xC8161D)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// State of the indicator, as on the phone (lib/ui/widgets/status_indicator.dart).
enum IndicatorKind { case watching, headOnly, unseen, paused, idle }

/// The trip status indicator in the form of the look: A rings, B a soft
/// face, C still figures. Breathes in «Слежу» (A, B), 6 s.
struct IndicatorView: View {
    let design: WatchDesign
    let kind: IndicatorKind
    var size: CGFloat = 64
    @State private var breath = false

    var body: some View {
        Canvas { context, canvas in
            draw(&context, canvas.width)
        }
        .frame(width: size, height: size)
        .opacity(breathes && breath ? 1 : (breathes ? breatheOpacity : 1))
        .scaleEffect(breathes && !breath ? breatheScale : 1)
        .onAppear {
            guard breathes else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { breath = true }
        }
        .accessibilityLabel(label)
    }

    private var breathes: Bool { kind == .watching && design != .roadsign }
    private var breatheOpacity: Double { design == .cockpit ? 0.45 : 0.75 }
    private var breatheScale: CGFloat { design == .cockpit ? 0.965 : 0.94 }

    private var label: String {
        switch kind {
        case .watching: return "Слежу"
        case .headOnly: return "Слежу за головой"
        case .unseen: return "Не вижу вас"
        case .paused: return "Пауза"
        case .idle: return "Ожидание"
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        let c = CGPoint(x: s / 2, y: s / 2)
        let yellow = WatchDesign.attention
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        func stroke(_ p: Path, _ color: Color, _ w: CGFloat, dash: [CGFloat] = []) {
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, dash: dash))
        }
        func pauseBars(_ color: Color, rounded: Bool) {
            let bw = s * 0.07, bh = s * 0.26
            for x in [c.x - bw * 1.6, c.x + bw * 0.6] {
                let r = CGRect(x: x, y: c.y - bh / 2, width: bw, height: bh)
                ctx.fill(Path(roundedRect: r, cornerRadius: rounded ? bw / 2 : 0), with: .color(color))
            }
        }
        switch design {
        case .cockpit:
            let sw: CGFloat = 3, r = s / 2 - sw * 2
            switch kind {
            case .watching:
                stroke(circle(r), design.accent.opacity(0.16), sw * 3)
                stroke(circle(r), design.accent, sw)
            case .headOnly:
                var top = Path()
                top.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                stroke(top, yellow, sw)
                var bottom = Path()
                bottom.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                stroke(bottom, yellow.opacity(0.45), sw / 1.5, dash: [0.1, 6])
            case .unseen:
                let seg = 2 * .pi * r / 20
                stroke(circle(r), yellow, sw, dash: [seg * 0.42, seg * 0.58])
            case .paused, .idle:
                let col = kind == .idle ? design.idle : design.pause
                stroke(circle(r), col, 1.5)
                if kind == .paused { pauseBars(col, rounded: true) }
            }
        case .companion:
            let r = s / 2 * 0.86, sw = max(2, s / 55)
            func eyes(_ col: Color) {
                for dx in [-r * 0.34, r * 0.34] {
                    let e = CGRect(x: c.x + dx - r * 0.085, y: c.y - r * 0.06 - r * 0.12, width: r * 0.17, height: r * 0.24)
                    ctx.fill(Path(ellipseIn: e), with: .color(col))
                }
            }
            switch kind {
            case .watching:
                ctx.fill(circle(r), with: .color(design.accent.opacity(0.14)))
                stroke(circle(r), design.accent.opacity(0.55), sw)
                eyes(design.accent)
            case .headOnly:
                ctx.fill(circle(r), with: .color(yellow.opacity(0.1)))
                stroke(circle(r), yellow.opacity(0.6), sw)
                let bar = CGRect(x: c.x - r * 0.6, y: c.y - r * 0.22, width: r * 1.2, height: r * 0.3)
                ctx.fill(Path(roundedRect: bar, cornerRadius: r * 0.15), with: .color(yellow))
            case .unseen:
                stroke(circle(r), yellow, sw * 1.5, dash: [r * 0.16, r * 0.17])
            case .paused, .idle:
                let col = kind == .idle ? design.idle : design.pause
                ctx.fill(circle(r), with: .color(col.opacity(0.08)))
                stroke(circle(r), col, sw)
                if kind == .paused { pauseBars(col, rounded: true) } else { eyes(col) }
            }
        case .roadsign:
            let r = s / 2 * 0.82, sw = max(3, s / 20)
            switch kind {
            case .watching:
                ctx.fill(circle(r), with: .color(design.accent))
            case .headOnly:
                stroke(circle(r - sw / 2), yellow, sw)
                var half = Path()
                half.move(to: c)
                half.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                half.closeSubpath()
                ctx.fill(half, with: .color(yellow))
            case .unseen:
                var d = Path()
                let k = r * 0.99
                d.move(to: CGPoint(x: c.x, y: c.y - k))
                d.addLine(to: CGPoint(x: c.x + k, y: c.y))
                d.addLine(to: CGPoint(x: c.x, y: c.y + k))
                d.addLine(to: CGPoint(x: c.x - k, y: c.y))
                d.closeSubpath()
                ctx.stroke(d, with: .color(yellow), style: StrokeStyle(lineWidth: sw, lineJoin: .round))
            case .paused, .idle:
                let col = kind == .idle ? design.idle : design.pause
                let box = CGRect(x: c.x - r * 0.8, y: c.y - r * 0.8, width: r * 1.6, height: r * 1.6)
                ctx.stroke(Path(roundedRect: box, cornerRadius: r * 0.1), with: .color(col), lineWidth: sw)
                if kind == .paused { pauseBars(col, rounded: false) }
            }
        }
    }
}

/// The owl of the app (owl-watch.svg): brows, eyes, beak in one colour.
struct OwlView: View {
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Canvas { ctx, canvas in
            let k = canvas.width / 100
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let style = StrokeStyle(lineWidth: 5.5 * k, lineCap: .round, lineJoin: .round)
            var brows = Path()
            brows.move(to: p(20, 28)); brows.addLine(to: p(33, 39))
            brows.move(to: p(80, 28)); brows.addLine(to: p(67, 39))
            ctx.stroke(brows, with: .color(color), style: style)
            for x in [35.0, 65.0] as [CGFloat] {
                let eye = Path(ellipseIn: CGRect(x: (x - 15) * k, y: 39 * k, width: 30 * k, height: 30 * k))
                ctx.fill(eye, with: .color(color.opacity(0.14)))
                ctx.stroke(eye, with: .color(color), style: style)
                ctx.fill(Path(ellipseIn: CGRect(x: (x - 6) * k, y: 48 * k, width: 12 * k, height: 12 * k)),
                         with: .color(color))
            }
            var beak = Path()
            beak.move(to: p(45, 72)); beak.addLine(to: p(50, 79)); beak.addLine(to: p(55, 72))
            ctx.stroke(beak, with: .color(color), style: StrokeStyle(lineWidth: 4.5 * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The amber advice diamond (W-07).
struct DiamondMark: View {
    let color: Color
    var size: CGFloat = 14
    var body: some View {
        Rectangle().fill(color).frame(width: size * 0.72, height: size * 0.72)
            .rotationEffect(.degrees(45)).frame(width: size, height: size)
    }
}
