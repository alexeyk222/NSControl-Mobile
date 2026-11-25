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

/// One screen per state, docs/ux/watch.md §3 (W-01…W-09).
struct RootView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        Group {
            switch link.screen {
            case .alarm(let title, let reason):
                // W-06: tap anywhere.
                FullScreen(color: .red, icon: "exclamationmark.triangle.fill", title: title,
                           subtitle: reason, footer: "Коснитесь — я в порядке", action: link.acknowledgeAlarm)
            case .advice(let title, let reason):
                // W-07
                FullScreen(color: .orange, icon: "cup.and.saucer.fill", title: title,
                           subtitle: reason, footer: nil, action: link.dismiss)
            case .test:
                // W-08
                FullScreen(color: .blue, icon: "applewatch.radiowaves.left.and.right", title: "Проверка вибрации",
                           subtitle: "Почувствовали? Ответьте на iPhone", footer: nil, action: link.dismiss)
            case .summary(let minutes, let alarms):
                // W-09
                FullScreen(color: .gray, icon: "flag.fill", title: Self.duration(minutes),
                           subtitle: "Тревог: \(alarms)", footer: nil, action: link.dismiss)
            default:
                StatusView(link: link)
            }
        }
        .onAppear {
            // Ask once, while the app is in front: the trip may later start it in the background.
            if link.workout.needsAuthorization { link.enableBackground() }
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
}

/// Coloured full-screen state; the whole screen is one tap target.
struct FullScreen: View {
    let color: Color
    let icon: String
    let title: String
    let subtitle: String
    let footer: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.title2).bold().multilineTextAlignment(.center).minimumScaleFactor(0.6)
            if !subtitle.isEmpty {
                Text(subtitle).font(.footnote).multilineTextAlignment(.center).lineLimit(3)
            }
            if let footer {
                Spacer(minLength: 2)
                Text(footer).font(.footnote).bold().multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// W-01…W-05: calm state, nothing to press during a trip.
struct StatusView: View {
    @ObservedObject var link: WatchLink

    private var look: (color: Color, icon: String, title: String, subtitle: String?) {
        switch link.screen {
        case .noLink: return (.gray, "iphone.slash", "Откройте NSControl на iPhone", nil)
        case .watching: return (.green, "eye.fill", "Слежу", elapsed)
        case .unseen(let headOnly):
            return (.yellow, "eye.slash.fill", headOnly ? "Только голова" : "Телефон не видит вас", elapsed)
        case .paused: return (.gray, "pause.fill", "Пауза", elapsed)
        default: return (.blue, "car.fill", "Готов к поездке", "Начните поездку на iPhone")
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
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(look.color.opacity(0.4), lineWidth: 6)
                    Image(systemName: look.icon).font(.title2).foregroundStyle(look.color)
                }
                .frame(width: 58, height: 58)
                Text(look.title).font(.headline).multilineTextAlignment(.center)
                if let subtitle = look.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                backgroundRow
                if idle {
                    Button("Проверить вибрацию", action: link.testVibration).font(.footnote)
                    Text("NSControl 1.0 • 2").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// Screen-off alerts need the background session; say plainly when it is missing.
    @ViewBuilder private var backgroundRow: some View {
        switch link.background {
        case .denied:
            VStack(spacing: 4) {
                Text("Без разрешения часы молчат, когда экран погас")
                    .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                if link.workout.deniedBefore {
                    // HealthKit shows its sheet only once; after a "no" only Settings help.
                    Text("Включите: iPhone → Здоровье → Профиль → Приложения → NSControl → Тренировки")
                        .font(.caption2).multilineTextAlignment(.center)
                } else {
                    Button("Разрешить", action: link.enableBackground).font(.footnote)
                }
            }
        case .failed, .unavailable:
            Text("Держите приложение открытым: фоновый режим не запустился")
                .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
        case .active, .off, .starting:
            EmptyView()
        }
    }
}
