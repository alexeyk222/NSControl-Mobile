import Foundation
import HealthKit

/// Keeps the watch app running with the screen off during a trip.
///
/// Without it watchOS suspends the app a few seconds after the wrist goes
/// down: WatchConnectivity stops delivering live messages and a haptic cannot
/// be played, so the ФТ-14 "автоматически погасший экран" case fails.
/// A workout session is the only public mode that keeps a third-party watch
/// app running in the background for hours and lets it play haptics there.
/// No workout is saved to Health: the session has no builder and is only ended.
final class BackgroundSession: NSObject, HKWorkoutSessionDelegate {
    enum State: String {
        case off            // no session
        case starting
        case active         // running, screen-off alerts work
        case denied         // the user did not allow workouts
        case unavailable    // HealthKit not available
        case failed
    }

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private(set) var state: State = .off { didSet { if state != oldValue { onChange?(state) } } }
    var onChange: ((State) -> Void)?

    static func configuration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        return configuration
    }

    /// Shown by the system as "NSControl wants to save workouts". Only the
    /// workout type is requested (СП-01: no unused health categories).
    func authorize(_ done: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { state = .unavailable; done(false); return }
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    var authorized: Bool {
        store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    /// The user already said no. HealthKit never shows the sheet again, so
    /// requestAuthorization returns at once and a button would do nothing.
    var deniedBefore: Bool {
        HKHealthStore.isHealthDataAvailable()
            && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingDenied
    }

    var needsAuthorization: Bool {
        HKHealthStore.isHealthDataAvailable()
            && store.authorizationStatus(for: HKObjectType.workoutType()) == .notDetermined
    }

    func start(configuration: HKWorkoutConfiguration = BackgroundSession.configuration()) {
        guard session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { state = .unavailable; return }
        guard authorized else { state = .denied; return }
        do {
            let created = try HKWorkoutSession(healthStore: store, configuration: configuration)
            created.delegate = self
            session = created
            state = .starting
            created.startActivity(with: Date())
        } catch {
            session = nil
            state = .failed
        }
    }

    func stop() {
        guard let session else { state = .off; return }
        self.session = nil
        session.end()
        state = .off
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            guard workoutSession === self.session else { return }
            switch toState {
            case .running: self.state = .active
            case .ended, .stopped: self.session = nil; self.state = .off
            default: break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            guard workoutSession === self.session else { return }
            self.session = nil
            self.state = .failed
        }
    }
}
