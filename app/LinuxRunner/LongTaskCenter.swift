import Foundation
import SwiftUI
import UIKit
import UserNotifications
import CoreLocation
import AVFoundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// User-started long work (Debian installation, APT package changes, headless
/// mode packages) and what iOS genuinely allows it
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
        if entries[index].ended == nil && entries[index].state == .pausedByIOS && system[token] == nil {
            entries[index].state = .running
        }
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
        // Always release system background tasks and UIKit assertions even if the
        // entry was pruned from the 20-item history list before completion.
        #if canImport(BackgroundTasks) && compiler(>=6.2)
        if #available(iOS 26.0, *), let task = system.removeValue(forKey: token) as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = 1000; task.progress.completedUnitCount = 1000
            task.setTaskCompleted(success: success)
        }
        #endif
        if let assertion = assertions.removeValue(forKey: token) { UIApplication.shared.endBackgroundTask(assertion) }
        guard let index = entries.firstIndex(where: { $0.id == token }) else { return }
        entries[index].state = success ? .completed : .failed
        entries[index].ended = Date()
        entries[index].detail = message
        if UIApplication.shared.applicationState != .active { notify(title: entries[index].title, body: message, success: success) }
        LRRuntimeBridge.logCategory("BACKGROUND", event: "task end title=\(entries[index].title) success=\(success)")
    }

    var running: [Entry] { entries.filter { $0.ended == nil } }
    var hasClearableEntries: Bool { entries.contains { $0.ended != nil } }

    func clearFinished() {
        entries.removeAll { $0.ended != nil }
    }

    func removeEntry(_ id: String) {
        entries.removeAll { $0.id == id && $0.ended != nil }
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
                        if let self {
                            self.system.removeValue(forKey: token)
                            if let i = self.entries.firstIndex(where: { $0.id == token }), self.entries[i].ended == nil {
                                self.entries[i].state = .pausedByIOS
                                LRRuntimeBridge.logCategory("BACKGROUND", event: "iOS expired continued processing title=\(self.entries[i].title)")
                                if UIApplication.shared.applicationState != .active {
                                    self.notify(title: self.entries[i].title, body: "iOS paused this task. Open DebianRunner to continue.", success: false)
                                }
                            }
                        }
                        task.setTaskCompleted(success: false)
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


/// Opt-in "Keep Linux Running in Background" (Settings > General & SSH Server).
///
/// iOS suspends an app shortly after leaving the foreground or locking the
/// screen, freezing Linux processes (SSH sessions, remote agents like agy
/// remote-control, background services) and letting Wi-Fi/TCP flows drop.
///
/// While enabled, this combines two iOS background assertions:
/// 1. A silent `.playback` + `.mixWithOthers` AVAudioPlayer loop (8 kHz mono
///    all-zero PCM) that keeps the process and network stack awake even when
///    the iPhone is locked and stationary, without pausing music/podcasts or
///    taking over Lock Screen media controls.
/// 2. A continuous CoreLocation session (kCLLocationAccuracyHundredMeters,
///    kCLDistanceFilterNone, plus CLBackgroundActivitySession on iOS 17+) when
///    Location permission is granted, matching iSH's background keep-alive.
@objc(LRBackgroundRunner) @MainActor final class BackgroundRunner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @objc static let shared = BackgroundRunner()
    static let defaultsKey = "LinuxRunner.keepRunningInBackground"
    @Published private(set) var status = "Off"
    private let manager = CLLocationManager()
    private var activitySession: AnyObject?   // CLBackgroundActivitySession on iOS 17+
    private var audioPlayer: AVAudioPlayer?
    private var audioActive = false
    private var locationActive = false
    private var requestedAlwaysUpgrade = false
    private var observers: [NSObjectProtocol] = []

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = byteRate * 2 // 2 seconds of digital silence
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        var leChunk = chunkSize.littleEndian
        data.append(Data(bytes: &leChunk, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt
        var fmtSize = UInt32(16).littleEndian
        data.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian
        data.append(Data(bytes: &audioFormat, count: 2))
        var leChannels = numChannels.littleEndian
        data.append(Data(bytes: &leChannels, count: 2))
        var leRate = sampleRate.littleEndian
        data.append(Data(bytes: &leRate, count: 4))
        var leByteRate = byteRate.littleEndian
        data.append(Data(bytes: &leByteRate, count: 4))
        var leBlockAlign = blockAlign.littleEndian
        data.append(Data(bytes: &leBlockAlign, count: 2))
        var leBits = bitsPerSample.littleEndian
        data.append(Data(bytes: &leBits, count: 2))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        var leDataSize = dataSize.littleEndian
        data.append(Data(bytes: &leDataSize, count: 4))
        data.append(Data(count: Int(dataSize)))
        return data
    }()

    private override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        // Hundred-meter accuracy with no distance filter keeps locationd active
        // even while the phone sits stationary on a desk (matching iSH's /dev/location),
        // without powering full GPS navigation tracking.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // Execute synchronously on the main thread before didEnterBackground returns
            // so UIKit background-task and audio/location handoff occur prior to suspension.
            MainActor.assumeIsolated { self?.reinforceForBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.enabled == true { self?.start() }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor in
                guard let self, self.enabled else { return }
                if AVAudioSession.InterruptionType(rawValue: typeRaw) == .ended {
                    self.startAudioKeepAlive(forceRestart: true)
                    self.updateStatus()
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.audioPlayer = nil
                self.audioActive = false
                self.startAudioKeepAlive(forceRestart: true)
                self.updateStatus()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                if self.audioPlayer?.isPlaying != true {
                    self.startAudioKeepAlive(forceRestart: true)
                    self.updateStatus()
                }
            }
        })
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
    /// Settings writes the flag (AppStorage) and then calls apply.
    func apply(_ on: Bool) { on ? start() : stop() }

    /// Call at launch: resumes the session when the user left it enabled.
    @objc func restore() { if enabled { start() } }

    private func startAudioKeepAlive(forceRestart: Bool = false) {
        if !forceRestart, let player = audioPlayer, player.isPlaying {
            audioActive = true
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player: AVAudioPlayer
            if let existing = audioPlayer, !forceRestart {
                player = existing
            } else {
                player = try AVAudioPlayer(data: Self.silentWAVData, fileTypeHint: AVFileType.wav.rawValue)
                player.numberOfLoops = -1
                // Non-zero gain on all-zero PCM samples outputs digital silence while
                // ensuring iOS does not treat the player as muted/inert when locked.
                player.volume = 0.01
                player.prepareToPlay()
                audioPlayer = player
            }
            let started = player.play()
            let wasActive = audioActive
            audioActive = started
            if started && !wasActive {
                LRRuntimeBridge.logCategory("BACKGROUND", event: "silent audio keep-alive started (mixWithOthers)")
            }
        } catch {
            audioActive = false
            LRRuntimeBridge.logCategory("BACKGROUND", event: "silent audio keep-alive failed: \(error.localizedDescription)")
        }
    }

    private func stopAudioKeepAlive() {
        audioPlayer?.stop()
        audioPlayer = nil
        if audioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        audioActive = false
    }

    private func reinforceForBackground() {
        guard enabled else { return }
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "DebianRunner-BackgroundHandoff") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        startAudioKeepAlive(forceRestart: audioPlayer?.isPlaying != true)
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationSession()
        default:
            break
        }
        updateStatus()
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }

    private func start() {
        // Start silent audio keep-alive first — works immediately even without Location permission.
        startAudioKeepAlive()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            stopLocationSession()
        case .authorizedWhenInUse:
            beginLocationSession()
            if !requestedAlwaysUpgrade {
                requestedAlwaysUpgrade = true
                manager.requestAlwaysAuthorization()
            }
        case .authorizedAlways:
            beginLocationSession()
        @unknown default:
            beginLocationSession()
        }
        updateStatus()
    }

    private func beginLocationSession() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if #available(iOS 17.0, *), activitySession == nil {
            activitySession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        if !locationActive {
            locationActive = true
            LRRuntimeBridge.logCategory("BACKGROUND", event: "location keep-alive started (hundred-meter + continuous filter)")
        }
    }

    private func stopLocationSession() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        if #available(iOS 17.0, *), let session = activitySession as? CLBackgroundActivitySession {
            session.invalidate()
        }
        activitySession = nil
        locationActive = false
    }

    private func updateStatus() {
        guard enabled else { status = "Off"; return }
        if audioActive && locationActive {
            status = "Active (audio + location): Linux, SSH & remote services stay awake when locked"
        } else if audioActive {
            status = "Active (silent audio): Linux, SSH & remote services stay awake when locked"
        } else if locationActive {
            status = "Active (location): Linux stays awake in background"
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            status = "Keep-alive unavailable: audio failed and Location permission is denied"
        } else {
            status = "Starting background keep-alive…"
        }
    }

    private func stop() {
        let wasActive = audioActive || locationActive
        stopAudioKeepAlive()
        stopLocationSession()
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
