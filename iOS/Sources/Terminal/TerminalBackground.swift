import ActivityKit
import CoreLocation
import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "background")

/// What keeps open terminals going while aOS is in the background (iOS/NOTES.md, "Terminals in the background"):
///
/// - A Live Activity shows the open terminals on the Lock Screen and in the Dynamic Island, with an End button. By
///   itself it gives the app no time in the background: it shows, it doesn't keep alive.
/// - Optionally the location service (off by default): an app that receives location updates keeps running. aOS asks
///   for the coarsest location and does nothing with it; it costs battery, and iOS shows the location arrow.
///
/// Without location, iOS suspends the app about 30 s after it went to the background and the connection drops; on
/// the Mac the session keeps running and the terminal attaches again when the app comes back. (iOS's continued
/// processing task, BGContinuedProcessingTask, isn't used: its progress in the Dynamic Island read as a task that
/// runs, not as a terminal that is kept.)
@MainActor
final class TerminalKeepAlive: NSObject {
    private let settings: AppSettings
    /// The terminals that are open (connecting, connected or reconnecting).
    private let open: () -> [TerminalSession]
    private var activity: Activity<TerminalActivityAttributes>?
    private var location: CLLocationManager?
    private var locationSession: CLBackgroundActivitySession?
    private var inBackground = false
    private var lastContent: TerminalActivityAttributes.ContentState?

    init(settings: AppSettings, open: @escaping () -> [TerminalSession]) {
        self.settings = settings
        self.open = open
        super.init()
        // A Live Activity left from before (the app was closed): it is ours again, or it goes.
        activity = Activity<TerminalActivityAttributes>.activities.first
    }

    /// Something holds the app in the background: the connection may stay.
    var holdsInBackground: Bool { location != nil }

    /// A terminal's state changed.
    func terminalsChanged() {
        let sessions = open()
        updateActivity(sessions)
        if sessions.isEmpty { stopLocation() }
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
            let state = s.phase == .connected ? "connected" : "reconnecting"
            return TerminalActivityAttributes.ContentState.Item(
                id: s.id.key, title: s.title, held: s.holderID != nil && s.holdsSession, state: state,
                since: s.connectedSince)
        }
        guard settings.terminalLiveActivity, !items.isEmpty else {
            endActivity()
            return
        }
        let keptBy: String? = location != nil ? "location" : nil
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
