import ActivityKit
import BackgroundTasks
import CoreLocation
import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "background")

/// What keeps open terminals going while aOS is in the background (iOS/NOTES.md, "Terminals in the background"):
///
/// - A Live Activity shows the open terminals on the Lock Screen and in the Dynamic Island, with an End button. By
///   itself it gives the app no time in the background: it shows, it doesn't keep alive.
/// - iOS's continued processing task (BGContinuedProcessingTask, iOS 26+): asked for when the person opens a
///   terminal, it gives the app time in the background for up to an hour, with iOS's own progress in the Dynamic
///   Island (the person can stop it there). iOS can end it earlier when it needs the resources.
/// - Optionally the location service (off by default): an app that receives location updates keeps running. aOS asks
///   for the coarsest location and does nothing with it; it costs battery, and iOS shows the location arrow.
///
/// When none of them holds, iOS suspends the app about 30 s after it went to the background and the connection
/// drops; on the Mac the session keeps running and the terminal attaches again when the app comes back.
@MainActor
final class TerminalKeepAlive: NSObject {
    private let settings: AppSettings
    /// The terminals that are open (connected, reconnecting or detached on the Mac).
    private let open: () -> [TerminalSession]
    private var activity: Activity<TerminalActivityAttributes>?
    private var continued: BGContinuedProcessingTask?
    /// A continued task was asked for and not yet given or refused.
    private var continuedPending = false
    private var continuedTicker: Task<Void, Never>?
    private var location: CLLocationManager?
    private var locationSession: CLBackgroundActivitySession?
    private var inBackground = false
    private var lastContent: TerminalActivityAttributes.ContentState?

    /// How long the continued task may keep the app (its progress counts this down).
    static let backgroundMinutes = 60
    static let taskPrefix = "dev.marquart.aos.ios.terminal."

    init(settings: AppSettings, open: @escaping () -> [TerminalSession]) {
        self.settings = settings
        self.open = open
        super.init()
        // A Live Activity left from before (the app was closed): it is ours again, or it goes.
        activity = Activity<TerminalActivityAttributes>.activities.first
    }

    /// Something holds the app in the background: the connection may stay.
    var holdsInBackground: Bool { continued != nil || location != nil }

    /// The person opened a terminal (their action is what lets the app ask iOS for background time).
    func terminalOpened() {
        startContinuedTaskIfWanted()
    }

    /// A terminal's state changed.
    func terminalsChanged() {
        let sessions = open()
        updateActivity(sessions)
        if sessions.isEmpty {
            finishContinuedTask()
            stopLocation()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            inBackground = false
            stopLocation()
        case .inactive:
            // Still in the foreground: the last moment to start location updates for the background.
            if settings.terminalKeepAliveLocation, !open().filter(\.isActive).isEmpty { startLocation() }
        case .background:
            inBackground = true
        @unknown default:
            break
        }
        updateActivity(open())
    }

    // MARK: The Live Activity

    private func updateActivity(_ sessions: [TerminalSession]) {
        let items = sessions.sorted { $0.title < $1.title }.map { s in
            let state = switch s.phase {
            case .connected: "connected"
            case .detached: "detached"
            default: "reconnecting"
            }
            return TerminalActivityAttributes.ContentState.Item(
                id: s.id.key, title: s.title, held: s.holderID != nil && s.holdsSession, state: state,
                since: s.connectedSince)
        }
        guard settings.terminalLiveActivity, !items.isEmpty else {
            endActivity()
            return
        }
        let keptBy: String? = location != nil ? "location" : (continued != nil ? "time" : nil)
        let content = TerminalActivityAttributes.ContentState(items: Array(items.prefix(4)), keptBy: keptBy)
        guard content != lastContent || activity == nil else { return }
        lastContent = content
        // Without time in the background the content goes stale soon after the app is suspended: the Live
        // Activity then says the sessions are kept on the Mac.
        let stale = Date().addingTimeInterval(holdsInBackground || !inBackground ? 15 * 60 : 60)
        if let activity {
            // Activity isn't Sendable; it is only ever used from here, one update after the other.
            nonisolated(unsafe) let current = activity
            Task { await current.update(ActivityContent(state: content, staleDate: stale)) }
        } else if !inBackground, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: TerminalActivityAttributes(),
                                                content: ActivityContent(state: content, staleDate: stale), pushType: nil)
            } catch {
                log.notice("No Live Activity: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func endActivity() {
        lastContent = nil
        activity = nil
        Task {
            for a in Activity<TerminalActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: iOS's background time

    private func startContinuedTaskIfWanted() {
        guard settings.terminalBackgroundTime, continued == nil, !continuedPending,
              UIApplication.shared.applicationState == .active else { return }
        continuedPending = true
        let identifier = Self.taskPrefix + UUID().uuidString.prefix(8).lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { self?.started(task) }
        }
        guard registered else {
            continuedPending = false
            log.notice("Continued processing isn't available here")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: String(localized: "Terminal in the background"),
            subtitle: String(localized: "aOS keeps your terminal connected."))
        request.strategy = .fail
        // iOS 27's way to submit; never from the main thread.
        Task.detached { [weak self] in
            BGTaskScheduler.shared.submitTaskRequest(request) { error in
                guard let error else { return }
                log.notice("Continued processing not granted: \(String(describing: error), privacy: .public)")
                Task { @MainActor in self?.continuedPending = false }
            }
        }
    }

    private func started(_ task: BGContinuedProcessingTask) {
        continuedPending = false
        continued = task
        let units = Int64(Self.backgroundMinutes * 6)
        task.progress.totalUnitCount = units
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            // iOS needs the resources, or the person stopped it in the Dynamic Island.
            Task { @MainActor in self?.finishContinuedTask(expired: true) }
        }
        log.info("Background time for the terminal granted")
        updateActivity(open())
        // Progress every 10 s: the time the app may still stay. Done when no terminal is open or the time is up.
        continuedTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let task = self.continued else { return }
                if self.open().filter(\.isActive).isEmpty || task.progress.completedUnitCount + 1 >= units {
                    self.finishContinuedTask()
                    return
                }
                task.progress.completedUnitCount += 1
                let left = Int((units - task.progress.completedUnitCount) / 6)
                task.updateTitle(task.title, subtitle: String(localized: "Connected for \(left) more min at most."))
            }
        }
    }

    private func finishContinuedTask(expired: Bool = false) {
        continuedTicker?.cancel()
        continuedTicker = nil
        guard let task = continued else { return }
        continued = nil
        if expired { log.info("Background time for the terminal ended by iOS") }
        task.setTaskCompleted(success: !expired)
        updateActivity(open())
    }

    // MARK: Location (optional)

    /// Asks for "while using" permission when the person turns the option on.
    static func requestLocationPermission() {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        locationPermissionAsker = manager
    }

    private static var locationPermissionAsker: CLLocationManager?

    static var locationAllowed: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private func startLocation() {
        guard location == nil, Self.locationAllowed else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        // The coarsest the service has (cell and Wi-Fi, no GPS), and no updates worth mentioning: only running matters.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        locationSession = CLBackgroundActivitySession()
        location = manager
        log.info("Keeping the terminal alive with location updates")
        updateActivity(open())
    }

    private func stopLocation() {
        guard let location else { return }
        location.stopUpdatingLocation()
        locationSession?.invalidate()
        locationSession = nil
        self.location = nil
        updateActivity(open())
    }
}

extension TerminalKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Nothing is kept or sent: the updates only keep the app running.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
