import HealthKit
import SwiftUI
import WatchKit

/// Receives the workout configuration when the iPhone starts a trip
/// (`HKHealthStore.startWatchApp`), even if the watch app was not running.
final class AppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchLink.shared.launchedForTrip(workoutConfiguration)
    }
}

@main
struct NSControlWatchApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup { RootView(link: WatchLink.shared) }
    }
}

/// One screen per state, docs/ux/watch.md §3 (W-01…W-09), in the look
/// chosen on the iPhone (WatchDesign). Red only on the alarm (W-06).
struct RootView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        let design = link.design
        Group {
            switch link.screen {
            case .alarm(let title, let reason):
                // W-06: red, one big word, tap anywhere.
                FullScreen(design: design, background: WatchDesign.alarm, foreground: .white,
                           title: title, subtitle: reason, footer: "Коснитесь — я в порядке",
                           action: link.acknowledgeAlarm)
            case .advice(let title, let reason):
                // W-07: dark with the amber diamond.
                FullScreen(design: design, background: design.background, foreground: WatchDesign.advice,
                           title: title, subtitle: reason, footer: nil, action: link.dismiss) {
                    DiamondMark(color: WatchDesign.advice, size: 26)
                }
            case .test:
                // W-08
                FullScreen(design: design, background: design.background, foreground: design.accent,
                           title: "Проверка вибрации", subtitle: "Почувствовали? Ответьте на iPhone",
                           footer: nil, action: link.dismiss) {
                    OwlView(color: design.accent, size: 36)
                }
            case .summary(let minutes, let alarms):
                // W-09: the trip time, big, and how many times it woke you.
                FullScreen(design: design, background: design.background, foreground: .white,
                           title: Self.duration(minutes), subtitle: Self.woke(alarms),
                           footer: nil, action: link.dismiss) {
                    Text("Поездка завершена").font(design.font(13)).foregroundStyle(design.secondary)
                }
            default:
                StatusView(link: link)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: link.screen)
        .onAppear {
            // Ask once, while the app is in front: the trip may later start it in the background.
            if link.workout.needsAuthorization { link.enableBackground() }
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }

    /// «Не будил» / «Будил 1 раз» / «Будил 3 раза» / «Будил 5 раз», as on the phone.
    static func woke(_ alarms: Int) -> String {
        guard alarms > 0 else { return "Не будил" }
        let tens = alarms % 100, ones = alarms % 10
        let word = (11...14).contains(tens) ? "раз" : (2...4).contains(ones) ? "раза" : "раз"
        return "Будил \(alarms) \(word)"
    }
}

/// A full-screen state; the whole screen is one tap target. An optional
/// mark sits above the title (diamond, owl, caption).
struct FullScreen<Mark: View>: View {
    let design: WatchDesign
    let background: Color
    let foreground: Color
    let title: String
    let subtitle: String
    let footer: String?
    let action: () -> Void
    let mark: () -> Mark

    init(design: WatchDesign, background: Color, foreground: Color, title: String, subtitle: String,
         footer: String?, action: @escaping () -> Void, @ViewBuilder mark: @escaping () -> Mark) {
        self.design = design
        self.background = background
        self.foreground = foreground
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.action = action
        self.mark = mark
    }

    var body: some View {
        VStack(spacing: 6) {
            mark()
            Text(title)
                .font(design.font(30, heavy: true))
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            if !subtitle.isEmpty {
                Text(subtitle).font(design.font(14)).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            if let footer {
                Spacer(minLength: 2)
                Text(footer).font(design.font(14, heavy: true)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .transition(.opacity)
    }
}

extension FullScreen where Mark == EmptyView {
    init(design: WatchDesign, background: Color, foreground: Color, title: String, subtitle: String,
         footer: String?, action: @escaping () -> Void) {
        self.init(design: design, background: background, foreground: foreground, title: title,
                  subtitle: subtitle, footer: footer, action: action) { EmptyView() }
    }
}

/// W-01…W-05: calm state, nothing to press during a trip. The indicator
/// has the form of the look; the word under it is the same as on the phone.
struct StatusView: View {
    @ObservedObject var link: WatchLink

    private var design: WatchDesign { link.design }

    private var look: (kind: IndicatorKind?, color: Color, title: String, subtitle: String?) {
        switch link.screen {
        case .noLink: return (nil, design.secondary, "Откройте NSControl на iPhone", nil)
        case .watching: return (.watching, design.accent, "Слежу", elapsed)
        case .unseen(let headOnly):
            return headOnly
                ? (.headOnly, WatchDesign.attention, "Слежу за головой", elapsed)
                : (.unseen, WatchDesign.attention, "Не вижу вас", elapsed)
        case .paused: return (.paused, design.pause, "Пауза", elapsed)
        default: return (.idle, design.secondary, "Готов к поездке", "Начните поездку на iPhone")
        }
    }

    /// "1:12 в пути"
    private var elapsed: String? {
        guard let minutes = link.driveMinutes else { return nil }
        return String(format: "%d:%02d в пути", minutes / 60, minutes % 60)
    }

    private var idle: Bool {
        switch link.screen {
        case .noLink, .ready: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Group {
                    if let kind = look.kind {
                        IndicatorView(design: design, kind: kind, size: 64)
                    } else {
                        OwlView(color: design.secondary, size: 52)  // W-01
                    }
                }
                .id(look.title)  // a new state fades in, breathing restarts
                .transition(.opacity)
                Text(look.title)
                    .font(design.font(20, heavy: true))
                    .foregroundStyle(look.kind == .idle || look.kind == nil ? .white : look.color)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                if let subtitle = look.subtitle {
                    Text(subtitle).font(design.font(14)).foregroundStyle(design.secondary)
                        .multilineTextAlignment(.center)
                }
                backgroundRow
                if idle {
                    Button("Проверить вибрацию", action: link.testVibration)
                        .font(design.font(14)).tint(design.accent)
                    Text("NSControl 1.0 • 2").font(.caption2).foregroundStyle(design.idle)
                }
            }
            .padding(.horizontal, 4)
            .animation(.easeInOut(duration: 0.3), value: look.title)
        }
        .background(design.background.ignoresSafeArea())
    }

    /// Screen-off alerts need the background session; say plainly when it is missing.
    @ViewBuilder private var backgroundRow: some View {
        switch link.background {
        case .denied:
            VStack(spacing: 4) {
                Text("Без разрешения часы молчат, когда экран погас")
                    .font(.caption2).foregroundStyle(WatchDesign.attention).multilineTextAlignment(.center)
                if link.workout.deniedBefore {
                    // HealthKit shows its sheet only once; after a "no" only Settings help.
                    Text("Включите: iPhone → Здоровье → Профиль → Приложения → NSControl → Тренировки")
                        .font(.caption2).multilineTextAlignment(.center)
                } else {
                    Button("Разрешить", action: link.enableBackground).font(.footnote).tint(design.accent)
                }
            }
        case .failed, .unavailable:
            Text("Держите приложение открытым: фоновый режим не запустился")
                .font(.caption2).foregroundStyle(WatchDesign.attention).multilineTextAlignment(.center)
        case .active, .off, .starting:
            EmptyView()
        }
    }
}
