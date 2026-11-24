import Foundation
import SwiftUI
import UIKit
import UserNotifications
import CoreLocation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// User-started long work (Debian installation, APT package changes, headless
/// mode packages, an opted-in terminal) and what iOS genuinely allows it
/// while LinuxRunner is not in front:
///
/// * Always: a UIApplication background-task assertion, a short grace period
///   (typically about 30 seconds) after the app leaves the foreground.
/// * iOS 26 and later: a BGContinuedProcessingTask. iOS may keep the app
///   running and shows the task in its own Live Activity with this progress.
///   The system decides; it can expire the task at any time (load, thermal
///   state, user cancellation, or progress that looks stalled).
///
/// Nothing here plays silent audio, uses location or any other background
/// mode to avoid suspension. When iOS suspends the app, Linux processes are
/// frozen with it and continue when it returns, unless iOS terminates it;
/// interrupted package operations are then finished by the existing
/// interrupted-installation recovery on the next run.
@objc(LRLongTaskCenter) @MainActor final class LongTaskCenter: NSObject, ObservableObject {
    @objc static let shared = LongTaskCenter()

    enum State: String { case running = "Running", backgroundGranted = "Running in background", pausedByIOS = "Paused by iOS", completed = "Completed", failed = "Failed" }
    struct Entry: Identifiable {
        let id: String
        var title: String
        var detail: String
        var fraction: Double?
        var state: State
        let started: Date
        var ended: Date?
    }
    @Published private(set) var entries: [Entry] = []

    private var assertions: [String: UIBackgroundTaskIdentifier] = [:]
    private var system: [String: AnyObject] = [:]          // BGContinuedProcessingTask, iOS 26+
    private var installTokens: [String: String] = [:]     // support-install title -> token
    private var observer: NSObjectProtocol?

    /// The system shows its own UI for continued tasks; this switch only
    /// controls LinuxRunner's completion notifications.
    @objc static var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "LinuxRunner.notifyTaskCompletion") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "LinuxRunner.notifyTaskCompletion") }
    }

    /// Follow the support installer's real progress notifications.
    @objc func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("LRInstallProgressNotification"), object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo, let title = info["title"] as? String, let phase = info["phase"] as? String else { return }
            Task { @MainActor in
                guard let self else { return }
                let fraction = (info["fraction"] as? Double).flatMap { $0 >= 0 ? $0 : nil }
                let stage = info["stage"] as? String ?? ""
                switch phase {
                case "running":
                    if let token = self.installTokens[title] { self.update(token, detail: stage, fraction: fraction) }
                    else { self.installTokens[title] = self.begin(title: title, detail: stage) }
                case "succeeded", "failed":
                    if let token = self.installTokens.removeValue(forKey: title) {
                        self.end(token, success: phase == "succeeded", message: phase == "succeeded" ? "\(title) finished." : (info["error"] as? String ?? "\(title) failed."))
                    }
                default: break
                }
            }
        }
    }

    /// `userStarted`: the user explicitly started this task (install button);
    /// only then may iOS's notification permission prompt appear, never in
    /// the middle of an implicit background step.
    @objc @discardableResult func begin(title: String, detail: String) -> String { begin(title: title, detail: detail, userStarted: false) }
    @discardableResult func begin(title: String, detail: String, userStarted: Bool) -> String {
        let token = UUID().uuidString.lowercased()
        entries.insert(Entry(id: token, title: title, detail: detail, fraction: nil, state: .running, started: Date()), at: 0)
        if entries.count > 20 { entries.removeLast(entries.count - 20) }
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "DebianRunner: " + title) { [weak self] in
            Task { @MainActor in self?.assertionExpired(token) }
        }
        if assertion != .invalid { assertions[token] = assertion }
        requestContinuedProcessing(token, title: title, detail: detail)
        if userStarted { requestNotificationPermissionOnce() }
        LRRuntimeBridge.logCategory("BACKGROUND", event: "task begin title=\(title) assertion=\(assertion != .invalid)")
        return token
    }

    @objc(updateToken:detail:fraction:) func update(_ token: String, detail: String, fraction: NSNumber?) { update(token, detail: detail, fraction: fraction?.doubleValue) }
    func update(_ token: String, detail: String, fraction: Double?) {
        guard let index = entries.firstIndex(where: { $0.id == token }) else { return }
        if !detail.isEmpty { entries[index].detail = detail }
        if let fraction { entries[index].fraction = min(1, max(0, fraction)) }
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *), let task = system[token] as? BGContinuedProcessingTask {
            if let fraction { task.progress.totalUnitCount = 1000; task.progress.completedUnitCount = Int64(min(1, max(0, fraction)) * 1000) }
            task.updateTitle(entries[index].title, subtitle: entries[index].detail)
        }
        #endif
    }

    @objc func end(_ token: String, success: Bool, message: String) {
        guard let index = entries.firstIndex(where: { $0.id == token }) else { return }
        entries[index].state = success ? .completed : .failed
        entries[index].ended = Date()
        entries[index].detail = message
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *), let task = system.removeValue(forKey: token) as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = 1000; task.progress.completedUnitCount = 1000
            task.setTaskCompleted(success: success)
        }
        #endif
        if let assertion = assertions.removeValue(forKey: token) { UIApplication.shared.endBackgroundTask(assertion) }
        if UIApplication.shared.applicationState != .active { notify(title: entries[index].title, body: message, success: success) }
        LRRuntimeBridge.logCategory("BACKGROUND", event: "task end title=\(entries[index].title) success=\(success)")
    }

    var running: [Entry] { entries.filter { $0.ended == nil } }
    var hasClearableEntries: Bool { entries.contains { $0.ended != nil || $0.state == .pausedByIOS } }

    func clearFinished() {
        entries.removeAll { $0.ended != nil || $0.state == .pausedByIOS }
    }

    func removeEntry(_ id: String) {
        entries.removeAll { $0.id == id && ($0.ended != nil || $0.state == .pausedByIOS) }
    }

    // MARK: - System mechanisms

    private func assertionExpired(_ token: String) {
        // The grace period is over. Without a continued-processing grant, iOS
        // suspends the app now; Linux resumes when LinuxRunner returns.
        if let assertion = assertions.removeValue(forKey: token) { UIApplication.shared.endBackgroundTask(assertion) }
        if let index = entries.firstIndex(where: { $0.id == token }), entries[index].ended == nil, system[token] == nil {
            entries[index].state = .pausedByIOS
            LRRuntimeBridge.logCategory("BACKGROUND", event: "background grace ended; work pauses until LinuxRunner is reopened title=\(entries[index].title)")
        }
    }

    private func requestContinuedProcessing(_ token: String, title: String, detail: String) {
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        guard #available(iOS 26.0, *), let bundle = Bundle.main.bundleIdentifier else { return }
        let identifier = bundle + ".linuxtask." + token
        // Continued-processing registrations may happen after launch; each
        // identifier is registered exactly once (the token is unique).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                guard let self, let index = self.entries.firstIndex(where: { $0.id == token }), self.entries[index].ended == nil else { task.setTaskCompleted(success: true); return }
                self.system[token] = task
                self.entries[index].state = .backgroundGranted
                task.progress.totalUnitCount = 1000
                task.progress.completedUnitCount = Int64((self.entries[index].fraction ?? 0) * 1000)
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.system.removeValue(forKey: token)
                        if let i = self.entries.firstIndex(where: { $0.id == token }), self.entries[i].ended == nil {
                            self.entries[i].state = .pausedByIOS
                            LRRuntimeBridge.logCategory("BACKGROUND", event: "iOS expired continued processing title=\(self.entries[i].title)")
                            if UIApplication.shared.applicationState != .active {
                                self.notify(title: self.entries[i].title, body: "iOS paused this task. Open DebianRunner to continue.", success: false)
                            }
                        }
                    }
                }
            }
        }
        guard registered else { LRRuntimeBridge.logCategory("BACKGROUND", event: "continued processing unavailable: identifier not permitted"); return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: detail.isEmpty ? "Linux task in progress" : detail)
        request.strategy = .fail     // now or not at all; the assertion still applies
        do { try BGTaskScheduler.shared.submit(request) }
        catch { LRRuntimeBridge.logCategory("BACKGROUND", event: "continued processing not granted: \(error.localizedDescription)") }
        #endif
    }

    private func requestNotificationPermissionOnce() {
        guard Self.notificationsEnabled, !UserDefaults.standard.bool(forKey: "LinuxRunner.notificationPermissionAsked") else { return }
        UserDefaults.standard.set(true, forKey: "LinuxRunner.notificationPermissionAsked")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String, success: Bool) {
        guard Self.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = success ? title : title + " needs attention"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}


/// Opt-in "Keep Linux Running in Background" (Settings > General).
///
/// iOS suspends an app shortly after it leaves the screen, which freezes every
/// Linux process (terminal sessions, servers, downloads). The one public way
/// to keep running indefinitely that this app already declares is the
/// `location` background mode (it backs /dev/location; iSH users get the same
/// effect with `cat /dev/location > /dev/null &`). While enabled, this runs a
/// coarse location session: kCLLocationAccuracyThreeKilometers (cell/Wi-Fi,
/// no GPS), updates discarded, never stored or sent anywhere. iOS shows its
/// location indicator so the user can always see it is active. Off by default.
@objc(LRBackgroundRunner) @MainActor final class BackgroundRunner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @objc static let shared = BackgroundRunner()
    static let defaultsKey = "LinuxRunner.keepRunningInBackground"
    @Published private(set) var status = "Off"
    private let manager = CLLocationManager()
    private var activitySession: AnyObject?   // CLBackgroundActivitySession on iOS 17+
    private var requestedAlwaysUpgrade = false
    private var activeSession = false
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        // A finite distance filter (not CLLocationDistanceMax) prevents iOS 17/18
        // from treating the location session as inert and suspending the process.
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reinforceForBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.enabled == true { self?.start() }
            }
        })
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
    /// Settings writes the flag (AppStorage) and then calls apply.
    func apply(_ on: Bool) { on ? start() : stop() }

    /// Call at launch: resumes the session when the user left it enabled.
    @objc func restore() { if enabled { start() } }

    private func reinforceForBackground() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            if #available(iOS 17.0, *), activitySession == nil {
                activitySession = CLBackgroundActivitySession()
            }
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    private func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Waiting for location permission"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            stopSessionObjects()
            status = "Location permission denied: allow it in iOS Settings > DebianRunner > Location"
        case .authorizedWhenInUse:
            beginLocationSession()
            if !requestedAlwaysUpgrade {
                requestedAlwaysUpgrade = true
                manager.requestAlwaysAuthorization()
            }
            status = "On (While Using): Linux keeps running in background; Allow Always for longest uptime"
        case .authorizedAlways:
            beginLocationSession()
            status = "On: Linux keeps running when you leave DebianRunner"
        @unknown default:
            beginLocationSession()
            status = "On: Linux keeps running when you leave DebianRunner"
        }
    }

    private func beginLocationSession() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if #available(iOS 17.0, *), activitySession == nil {
            activitySession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        if !activeSession {
            activeSession = true
            LRRuntimeBridge.logCategory("BACKGROUND", event: "keep-running session started (coarse location + background activity session)")
        }
    }

    private func stopSessionObjects() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        if #available(iOS 17.0, *), let session = activitySession as? CLBackgroundActivitySession {
            session.invalidate()
        }
        activitySession = nil
        activeSession = false
    }

    private func stop() {
        let wasActive = activeSession
        stopSessionObjects()
        status = "Off"
        if wasActive {
            LRRuntimeBridge.logCategory("BACKGROUND", event: "keep-running session stopped")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.enabled { self.start() } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}   // discarded
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient CLErrorLocationUnknown is normal indoors; only log persistent failures.
        if (error as NSError).code != CLError.locationUnknown.rawValue {
            Task { @MainActor in
                LRRuntimeBridge.logCategory("BACKGROUND", event: "location error: \(error.localizedDescription)")
            }
        }
    }
}
