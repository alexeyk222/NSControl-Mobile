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

struct RootView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        Group {
            switch link.phase {
            case .alarm: AlarmView(link: link)
            case .notice: NoticeView(link: link)
            default: StatusView(link: link)
            }
        }
        .onAppear {
            // Ask once, while the app is in front: the trip may later start it in the background.
            if link.workout.needsAuthorization { link.enableBackground() }
        }
    }
}

/// Full-screen alarm. One big target: the driver answers without looking for it.
struct AlarmView: View {
    @ObservedObject var link: WatchLink
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2)
            Text(link.title).font(.title3).bold()
            Text(link.detail).font(.footnote).multilineTextAlignment(.center).lineLimit(4)
            Spacer(minLength: 2)
            Button(action: link.acknowledgeAlarm) {
                Text("Я в порядке").font(.headline).frame(maxWidth: .infinity)
            }
            .tint(.white)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.ignoresSafeArea())
    }
}

struct NoticeView: View {
    @ObservedObject var link: WatchLink
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cup.and.saucer.fill").font(.title2).foregroundStyle(.orange)
            Text(link.title).font(.headline)
            Text(link.detail).font(.footnote).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
    }
}

struct StatusView: View {
    @ObservedObject var link: WatchLink

    private var color: Color {
        switch link.phase {
        case .observing: return .green
        case .limited: return .orange
        case .noLink: return .gray
        default: return .blue
        }
    }

    private var icon: String {
        switch link.phase {
        case .observing: return "eye.fill"
        case .limited: return "eye.slash.fill"
        case .noLink: return "iphone.slash"
        default: return "car.fill"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(color.opacity(0.35), lineWidth: 6)
                    Image(systemName: icon).font(.title2).foregroundStyle(color)
                }
                .frame(width: 58, height: 58)
                Text(link.title).font(.headline).multilineTextAlignment(.center)
                Text(link.detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let minutes = link.driveMinutes, link.phase == .observing || link.phase == .limited {
                    Text("В пути \(minutes) мин").font(.footnote)
                }
                if let text = link.recommendation {
                    Text(text).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                backgroundRow
                Button("Проверить вибрацию", action: link.testVibration)
                    .font(.footnote)
                Text("NSControl 1.0 • 2").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    /// Screen-off alerts need the background session; say plainly when it is missing.
    @ViewBuilder private var backgroundRow: some View {
        switch link.background {
        case .active:
            Label("Работает при погасшем экране", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .denied:
            VStack(spacing: 4) {
                Text("Без разрешения часы молчат, когда экран погас")
                    .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                Button("Разрешить", action: link.enableBackground).font(.footnote)
            }
        case .failed, .unavailable:
            Text("Фоновый режим не запустился. Держите приложение открытым")
                .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
        case .off, .starting:
            EmptyView()
        }
    }
}
