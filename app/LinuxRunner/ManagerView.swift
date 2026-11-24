import SwiftUI
import Combine
import UniformTypeIdentifiers
import GameController
import Network
import Darwin
import os

@MainActor final class EnvironmentManager: ObservableObject {
    @Published var environments: [LinuxEnvironment] = []
    @Published var storage: [UUID: Int64] = [:]
    @Published var error: String?
    // Environment create/import/remove/install in progress (also keeps the screen awake).
    @Published var busy = false { didSet { if busy != oldValue { busy ? LRRuntimeBridge.beginAwake("environment-operation") : LRRuntimeBridge.endAwake("environment-operation") } } }
    @Published var detected: [LinuxApplication] = []
    @Published var discovering = false
    @Published var logs: [String] = []
    private var lastStorageMeasurement = Date.distantPast
    private var measuringStorage = false
    private var storageMeasurement: Task<Void, Never>?
    private var storageGeneration = UUID()
    private var catalogWritable = true
    private var observers: [NSObjectProtocol] = []

    init() {
        do {
            let url = LRRuntimeBridge.catalogURL()
            if FileManager.default.fileExists(atPath: url.path) {
                environments = try EnvironmentCatalog.read(url).environments
            }
            for root in LRRuntimeBridge.rootNames() where !environments.contains(where: { $0.rootfsName == root }) {
                var recovered = LinuxEnvironment(name: root == "default" ? "Debian Minimal" : "Debian Minimal · \(root.prefix(8))", rootfsName: root)
                if let data = try? Data(contentsOf: LRRuntimeBridge.rootURL(root).appendingPathComponent("environment-install.json")),
                   let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    recovered.distributionID = metadata["distributionID"] ?? "debian"
                    recovered.distribution = metadata["distribution"] ?? recovered.distribution
                    recovered.name = metadata["distribution"] ?? recovered.name
                    recovered.rootfsVersion = metadata["version"] ?? recovered.rootfsVersion
                    recovered.packageManager = metadata["packageManager"] ?? "apt"
                    recovered.defaultShell = metadata["defaultShell"] ?? "/bin/bash"
                    recovered.installationState = "Imported"
                }
                environments.append(recovered)
            }
            if let index = environments.firstIndex(where: { $0.rootfsName == LRRuntimeBridge.activeRootName() }), LRRuntimeBridge.isRunning() {
                environments[index].lastBootedAt = Date()
            }
            storage = Dictionary(uniqueKeysWithValues: environments.compactMap { environment in
                environment.storageBytes.map { (environment.id, $0) }
            })
            try persist()
        } catch { catalogWritable = false; self.error = error.localizedDescription }
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name("ProcessExitedNotification"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }
    deinit { storageMeasurement?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

    func persist() throws {
        guard catalogWritable else { throw EnvironmentError.invalidMetadata }
        try EnvironmentCatalog(environments: environments).write(LRRuntimeBridge.catalogURL())
    }

    func refresh() {
        if !discovering {
            discovering = true
            let root = LRRuntimeBridge.activeRootName()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let commands = LRRuntimeBridge.isRunning() ? LRRuntimeBridge.discoverApplications() : []
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.discovering = false
                    guard root == LRRuntimeBridge.activeRootName() else { return }
                    self.detected = commands.compactMap { item in
                        guard let name = item["name"], let command = item["command"] else { return nil }
                        return LinuxApplication(name: name, command: command)
                    }
                }
            }
        }
        logs = LRRuntimeBridge.logLines()
        guard !measuringStorage, Date().timeIntervalSince(lastStorageMeasurement) >= 30 else { return }
        measuringStorage = true
        let items = environments.map { ($0.id, LRRuntimeBridge.rootURL($0.rootfsName), LRRuntimeBridge.exchangeURL($0.rootfsName)) }
        let generation = storageGeneration
        storageMeasurement = Task.detached(priority: .background) { [weak self] in
            guard let measured = EnvironmentStorage.measure(items), !Task.isCancelled else { return }
            await self?.setStorage(measured, generation: generation)
        }
    }

    private func setStorage(_ measured: [UUID: Int64], generation: UUID) {
        guard generation == storageGeneration else { return }
        storage = measured; measuringStorage = false; storageMeasurement = nil
        lastStorageMeasurement = Date()
        for index in environments.indices {
            environments[index].storageBytes = measured[environments[index].id]
            if active(environments[index]) {
                environments[index].lastBootResult = "Runtime running"
                let marker = LRRuntimeBridge.rootURL(environments[index].rootfsName).appendingPathComponent("data/var/lib/linuxrunner/initialized").path
                environments[index].installationState = FileManager.default.fileExists(atPath: marker)
                    ? "Base Debian packages configured"
                    : "First-start configuration pending; setup may require repair"
            }
        }
        try? persist()
    }

    func acceptInstalled(_ environment: LinuxEnvironment) {
        do { environments.append(environment); try persist(); refresh() } catch { self.error = error.localizedDescription }
    }

    func add(application: LinuxApplication, to environment: LinuxEnvironment) {
        do {
            try application.validate()
            guard let index = environments.firstIndex(where: { $0.id == environment.id }) else { return }
            let previous = environments
            environments[index].applications.append(application)
            do { try persist() } catch { environments = previous; throw error }
        } catch { self.error = error.localizedDescription }
    }

    func active(_ environment: LinuxEnvironment) -> Bool {
        !environment.rootfsName.isEmpty && environment.rootfsName == LRRuntimeBridge.activeRootName() && LRRuntimeBridge.isRunning()
    }

    func delete(_ environment: LinuxEnvironment) {
        guard !busy else { return }
        do { try persist() } catch { self.error = error.localizedDescription; return }
        busy = true
        LRRuntimeBridge.deleteEnvironment(environment.rootfsName) { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false }
                if let failure {
                    self.error = failure.localizedDescription
                    if LRRuntimeBridge.rootNames().contains(environment.rootfsName) { return }
                }
                self.environments.removeAll { $0.id == environment.id }
                self.storage.removeValue(forKey: environment.id)
                do { try self.persist() } catch { self.error = "Environment files were deleted, but the catalog could not be saved: \(error.localizedDescription)" }
                self.refresh()
            }
        }
    }

    func wipeAll(completion: @escaping (Bool, String?) -> Void) {
        guard !busy else { completion(false, "Wait for the current operation to finish."); return }
        busy = true
        LRRuntimeBridge.wipeEnvironment { [weak self] needsRestart, failure in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false }
                if !needsRestart && failure == nil {
                    self.environments = []
                    self.storage = [:]
                    self.detected = []
                    try? self.persist()
                }
                self.refresh()
                completion(needsRestart, failure?.localizedDescription)
            }
        }
    }

    func size(_ environment: LinuxEnvironment) -> String {
        storage[environment.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…"
    }
}

private enum EnvironmentStorage {
    static func measure(_ items: [(UUID, URL, URL)]) -> [UUID: Int64]? {
        var sizes: [UUID: Int64] = [:]
        for (id, root, exchange) in items {
            guard let rootSize = StorageUsage.measuredBytes(root, isCancelled: { Task.isCancelled }),
                  let exchangeSize = StorageUsage.measuredBytes(exchange, isCancelled: { Task.isCancelled }) else { return nil }
            sizes[id] = rootSize + exchangeSize
        }
        return sizes
    }
}

@MainActor @objc(LinuxRunnerShell) final class LinuxRunnerShell: NSObject {
    @objc static func makeController(terminal: TerminalViewController) -> UIViewController {
        UIHostingController(rootView: ManagerView(terminal: terminal))
    }
    @objc(makeTaskManagerController) static func makeTaskManagerController() -> UIViewController {
        let host = UIHostingController(rootView: TaskManagerView())
        host.overrideUserInterfaceStyle = .dark
        return host
    }
}

// Password entry stays in the distribution's passwd PTY or chpasswd -e. Native
// state contains account names only; /etc/shadow and password bytes never enter SwiftUI.
private struct PasswordTarget: Identifiable { let name: String; var id: String { name } }

private struct SetPasswordSheet: View {
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working: String?
    @State private var problem: String?
    var body: some View {
        NavigationView {
            Form {
                SecureField("New password", text: $password).textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                if !confirmation.isEmpty && password != confirmation { Text("The passwords do not match.").foregroundStyle(.orange) }
                if let working { HStack(spacing: 10) { ProgressView(); Text(working) } }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("Password for \(name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working != nil) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    working = "Preparing"; problem = nil
                    LRRuntimeBridge.setLinuxPassword(name, password: password, progress: { working = $0 }) { error in
                        working = nil
                        if let error { problem = error.localizedDescription } else { dismiss() }
                    }
                }.disabled(password.isEmpty || password != confirmation || working != nil) }
            }
        }.navigationViewStyle(.stack)
    }
}

private struct LinuxUsersView: View {
    @State private var accounts: [[String: String]] = []
    @State private var selected = "root"
    @State private var username = ""
    @State private var session: TerminalPresentation?
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var removeName = ""
    @State private var newPassword = ""
    @State private var newConfirmation = ""
    @State private var newAdministrator = true
    @State private var newPasswordlessSudo = true
    @State private var creating: String?
    @State private var passwordFor: PasswordTarget?
    private var running: Bool { LRRuntimeBridge.isRunning() }
    private func createNative() {
        error = nil; creating = "Preparing"
        LRRuntimeBridge.createLinuxUser(username, password: newPassword, administrator: newAdministrator, passwordlessSudo: newAdministrator && newPasswordlessSudo, progress: { creating = $0 }) { failure in
            creating = nil
            if let failure { error = failure.localizedDescription; return }
            newPassword = ""; newConfirmation = ""; username = ""; refresh()
        }
    }

    var body: some View {
        List {
            Section("Active Debian Environment") {
                Text(LRRuntimeBridge.activeRootName().isEmpty ? "Not running" : LRRuntimeBridge.activeRootName()).font(.caption).foregroundColor(.secondary)
                Text("New ordinary terminals log in as the selected user using su. Existing terminals and administrative/package launches retain their identity.").font(.footnote)
                Text("Linux UID permissions apply inside DebianRunner. Accounts do not create separate iOS security identities.").font(.footnote).foregroundColor(.secondary)
            }
            Section("Default Linux Session User") {
                Picker("Login account", selection: $selected) {
                    ForEach(accounts, id: \.self) { account in
                        Text("\(account["name"] ?? "") · UID \(account["uid"] ?? "")").tag(account["name"] ?? "")
                    }
                    if !accounts.contains(where: { $0["name"] == selected }) {
                        Text(selected + " (not available)").tag(selected)
                    }
                }
                Button("Use for New Sessions") {
                    do { _ = try LRRuntimeBridge.setDefaultLinuxUser(selected) }
                    catch { self.error = error.localizedDescription }
                }.disabled(!running || !accounts.contains(where: { $0["name"] == selected }))
                Button("Open Login Terminal") {
                    do { session = TerminalPresentation(controller: try LRRuntimeBridge.terminal(forLinuxUser: selected)) }
                    catch { self.error = error.localizedDescription }
                }.disabled(!running || !accounts.contains(where: { $0["name"] == selected }))
            }
            Section("Create Linux User") {
                TextField("Username", text: $username).autocorrectionDisabled().textInputAutocapitalization(.never).textContentType(.username)
                SecureField("Password", text: $newPassword).textContentType(.newPassword)
                SecureField("Confirm password", text: $newConfirmation).textContentType(.newPassword)
                Toggle("Administrator (can use sudo)", isOn: $newAdministrator)
                if newAdministrator {
                    Toggle("Passwordless sudo (NOPASSWD)", isOn: $newPasswordlessSudo)
                }
                Button("Create Account") { createNative() }
                    .disabled(!running || creating != nil || username.isEmpty || newPassword.isEmpty || newPassword != newConfirmation)
                if let creating { HStack(spacing: 10) { ProgressView(); Text(creating) } }
                Text("Account tools (and sudo for administrators) are installed automatically if this environment lacks them. DebianRunner sends only Linux's own password hash and stores no password.").font(.caption).foregroundColor(.secondary)
            }
            Section("Manage Accounts") {
                ForEach(accounts, id: \.self) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account["name"] ?? "").font(.headline)
                        Text("UID \(account["uid"] ?? "") · GID \(account["gid"] ?? "") · \(account["home"] ?? "")").font(.caption)
                        Button("Set Password…") { passwordFor = PasswordTarget(name: account["name"] ?? "") }.disabled(!running)
                        if (Int(account["uid"] ?? "") ?? 0) >= 1000 {
                            Button("Remove Account — Keep Home…", role: .destructive) {
                                removeName = account["name"] ?? ""
                                confirmRemove = true
                            }.disabled(!running || account["name"] == LRRuntimeBridge.defaultLinuxUser())
                        }
                    }
                }
                Button("Refresh Accounts", action: refresh).disabled(!running)
                Text("System users without a login shell are omitted. Removing an account preserves its home and files; their numeric ownership remains. System accounts and the default login are protected.").font(.caption).foregroundColor(.secondary)
            }
            if let error { Section("Account Operation") { Text(error).foregroundColor(.red) } }
        }
        .navigationTitle("Linux Users")
        .onAppear(perform: refresh)
        .sheet(item: $passwordFor) { target in SetPasswordSheet(name: target.name) }
        .confirmationDialog("Remove \(removeName) and keep its home?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Account — Keep Home", role: .destructive) {
                do { session = TerminalPresentation(controller: try LRRuntimeBridge.removeLinuxUserKeepingHome(removeName)) }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Debian updates its account databases. Home directories and files remain, with their existing numeric ownership. Close this user's sessions first. No forced deletion is used.")
        }
        .sheet(item: $session, onDismiss: refresh) { item in
            TerminalScreen(controller: item.controller)
        }
    }
    private func refresh() {
        accounts = LRRuntimeBridge.linuxAccounts()
        selected = LRRuntimeBridge.defaultLinuxUser()
    }
}

private struct TerminalPresentation: Identifiable {
    let id = UUID()
    let controller: TerminalViewController
}

// MARK: - Built-in OpenSSH Server Controller & Screen
@MainActor final class SSHServiceController: ObservableObject {
    @Published var status: [String: String] = [:]
    @Published var installing = false
    @Published var installProgress: String?
    @Published var busy = false
    @Published var error: String?
    @Published var logTail = ""
    private var autoBootAttempted = false

    var isInstalled: Bool { status["ssh_installed"] == "1" || LRRuntimeBridge.sshBinaryInstalled() }
    var isRunning: Bool { LRRuntimeBridge.isRunning() && status["ssh"] == "running" }
    var port: String { status["ssh.port"] ?? "2222" }

    func refresh(queryGuest: Bool = true) {
        status = LRRuntimeBridge.sshStatus()
        logTail = LRRuntimeBridge.sshLogTail()
        guard queryGuest, LRRuntimeBridge.isRunning(), !installing, !busy else { return }
        LRRuntimeBridge.runSSHAction("status") { [weak self] updated in
            Task { @MainActor in
                guard let self else { return }
                self.status = updated
                self.logTail = LRRuntimeBridge.sshLogTail()
            }
        }
    }

    func ensureDefaultSSHIfNeeded() {
        guard !autoBootAttempted, !installing, !busy, LRRuntimeBridge.isRunning(), LRRuntimeBridge.sshAutoStart() else { return }
        let root = LRRuntimeBridge.activeRootName()
        if !root.isEmpty {
            let marker = LRRuntimeBridge.rootURL(root).appendingPathComponent("data/var/lib/linuxrunner/initialized").path
            if !FileManager.default.fileExists(atPath: marker) {
                // First-boot Debian initialization installs openssh-server itself; avoid racing dpkg/apt.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.ensureDefaultSSHIfNeeded()
                }
                return
            }
        }
        autoBootAttempted = true
        if LRRuntimeBridge.sshBinaryInstalled() {
            start()
        } else if !LRRuntimeBridge.installationRunning() {
            installAndStart()
        }
    }

    func start() {
        guard LRRuntimeBridge.isRunning(), !busy, !installing else { return }
        error = nil; busy = true
        LRRuntimeBridge.runSSHAction("start") { [weak self] updated in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.status = updated
                self.logTail = LRRuntimeBridge.sshLogTail()
                if updated["ssh"] != "running" {
                    self.error = "OpenSSH server did not start. Expand SSH Server Log below for details."
                }
            }
        }
    }

    func stop() {
        guard LRRuntimeBridge.isRunning(), !busy, !installing else { return }
        error = nil; busy = true
        LRRuntimeBridge.runSSHAction("stop") { [weak self] updated in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.status = updated
                self.logTail = LRRuntimeBridge.sshLogTail()
            }
        }
    }

    func restart() {
        guard LRRuntimeBridge.isRunning(), !busy, !installing else { return }
        error = nil; busy = true
        LRRuntimeBridge.runSSHAction("restart") { [weak self] updated in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.status = updated
                self.logTail = LRRuntimeBridge.sshLogTail()
                if updated["ssh"] != "running" {
                    self.error = "OpenSSH server did not restart. Expand SSH Server Log below for details."
                }
            }
        }
    }

    func installAndStart() {
        guard LRRuntimeBridge.isRunning(), !installing else { return }
        error = nil; installing = true; installProgress = "Preparing OpenSSH installation"
        LRRuntimeBridge.installSSH(progress: { [weak self] stage in
            Task { @MainActor in self?.installProgress = stage }
        }) { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                self.installing = false
                self.installProgress = nil
                if let failure {
                    self.error = failure.localizedDescription
                    self.refresh(queryGuest: false)
                    return
                }
                self.status = LRRuntimeBridge.sshStatus()
                if LRRuntimeBridge.sshAutoStart() {
                    self.start()
                } else {
                    self.refresh(queryGuest: true)
                }
            }
        }
    }

    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

private struct SSHServerView: View {
    @ObservedObject var ssh: SSHServiceController
    @State private var autoStart = LRRuntimeBridge.sshAutoStart()
    @State private var allowRootLogin = LRRuntimeBridge.sshAllowRootLogin()
    @AppStorage(BackgroundRunner.defaultsKey) private var keepRunningInBackground = false
    @State private var copied: String?
    @State private var runtimeRunning = LRRuntimeBridge.isRunning()
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var loginUser: String {
        let user = LRRuntimeBridge.defaultLinuxUser()
        if !user.isEmpty && (user != "root" || allowRootLogin) { return user }
        if let firstNonRoot = LRRuntimeBridge.linuxAccounts().first(where: { $0["name"] != "root" && ($0["uid"].flatMap(Int.init) ?? 0) >= 1000 })?["name"] {
            return firstNonRoot
        }
        return allowRootLogin ? "root" : "<user>"
    }

    private var needsNonRootUserNotice: Bool {
        runtimeRunning && !allowRootLogin && loginUser == "<user>"
    }

    private var statusPill: (String, Color) {
        if ssh.installing { return ("Installing", .orange) }
        if ssh.busy { return ("Updating", .orange) }
        if !runtimeRunning { return ("Debian Stopped", .secondary) }
        if ssh.isRunning { return ("Running", .green) }
        if ssh.isInstalled { return ("Stopped", .secondary) }
        return ("Not Installed", .orange)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                if !runtimeRunning {
                    notice("Start Debian Minimal from the Home or Debian tab to run the OpenSSH server.", symbol: "power", color: .orange)
                }
                if needsNonRootUserNotice {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Create a Linux user or enable Allow Root Login", systemImage: "person.badge.key.fill")
                            .font(.subheadline.weight(.semibold)).foregroundColor(.orange)
                        Text("Root SSH login is off by default. Create a user account with a password in Linux Users (or enable Allow Root Login below and set a root password).")
                            .font(.caption).foregroundColor(.secondary)
                        NavigationLink(destination: LinuxUsersView()) {
                            Label("Open Linux Users", systemImage: "person.2.fill").font(.caption.weight(.semibold))
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.12)))
                }
                if ssh.isRunning {
                    connectionCard
                }
                controlsCard
                optionsCard
                logCard
            }
            .padding(.horizontal, 20).padding(.vertical, 12).padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("SSH Server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            runtimeRunning = LRRuntimeBridge.isRunning()
            autoStart = LRRuntimeBridge.sshAutoStart()
            allowRootLogin = LRRuntimeBridge.sshAllowRootLogin()
            ssh.refresh(queryGuest: true)
        }
        .onReceive(timer) { _ in
            guard scenePhase == .active else { return }
            runtimeRunning = LRRuntimeBridge.isRunning()
            ssh.refresh(queryGuest: true)
        }
    }

    private var heroCard: some View {
        let pill = statusPill
        return HStack(spacing: 14) {
            LRIconTile(symbol: "network", colors: [.green, .teal], size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenSSH Server").font(.headline)
                Text("Remote shell, VS Code Remote, scp & SFTP on port \(ssh.port)")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                if ssh.isRunning { Circle().fill(Color.green).frame(width: 7, height: 7) }
                LRStatusPill(text: pill.0, color: pill.1)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var connectionCard: some View {
        let ip = SSHServiceController.wifiAddress() ?? "iPhone-IP"
        let cmd = "ssh -p \(ssh.port) \(loginUser)@\(ip)"
        let sftpCmd = "sftp -P \(ssh.port) \(loginUser)@\(ip)"
        return LRCard(title: "Connect", symbol: "terminal.fill", colors: [.green, .mint], value: ":\(ssh.port)") {
            VStack(spacing: 0) {
                copyRow("SSH", cmd)
                Divider().padding(.leading, 12)
                copyRow("SFTP", sftpCmd)
                Divider().padding(.leading, 12)
                copyRow("Wi-Fi IP", ip)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
            Text("Connect from any Mac, PC, or SSH client on the same Wi-Fi network using your Linux user's password or ~/.ssh/authorized_keys.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 58, alignment: .leading)
            Text(value).font(.system(.footnote, design: .monospaced).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = value
                withAnimation { copied = value }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == value { withAnimation { copied = nil } } }
            } label: {
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc").font(.caption.weight(.semibold))
            }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var controlsCard: some View {
        let disabled = !runtimeRunning || ssh.installing || ssh.busy
        return LRCard(title: "Server Control", symbol: "bolt.horizontal.circle.fill", colors: [.blue, .teal]) {
            if ssh.installing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(ssh.installProgress ?? "Installing OpenSSH server…").font(.footnote).foregroundColor(.secondary)
                }
            }
            if let err = ssh.error {
                notice(err, symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            HStack(spacing: 10) {
                if !ssh.isInstalled {
                    Button { ssh.installAndStart() } label: {
                        Label("Install & Start SSH", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(disabled)
                } else if ssh.isRunning {
                    Button { ssh.restart() } label: {
                        Label(ssh.busy ? "Restarting…" : "Restart", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).disabled(disabled)
                    Button(role: .destructive) { ssh.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(disabled)
                } else {
                    Button { ssh.start() } label: {
                        Label(ssh.busy ? "Starting…" : "Start SSH Server", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(disabled)
                }
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var optionsCard: some View {
        LRCard(title: "Settings", symbol: "gearshape.fill", colors: [.indigo, .purple]) {
            Toggle("Start SSH Automatically on Launch", isOn: $autoStart)
                .onChange(of: autoStart) { value in
                    LRRuntimeBridge.setSshAutoStart(value)
                }
            Divider()
            Toggle("Allow Root Login", isOn: $allowRootLogin)
                .onChange(of: allowRootLogin) { value in
                    LRRuntimeBridge.setSshAllowRootLogin(value)
                    if ssh.isRunning { ssh.restart() }
                }
            Divider()
            Toggle("Keep Linux Running in Background", isOn: $keepRunningInBackground)
                .onChange(of: keepRunningInBackground) { BackgroundRunner.shared.apply($0) }
            Text("Enable background execution so active SSH sessions stay alive when you lock your iPhone or switch apps. OpenSSH uses TCP keepalives and skips PAM/DNS lookups for responsive userspace logins.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var logCard: some View {
        LRCard(title: "Diagnostics", symbol: "doc.text.fill", colors: [.gray, Color(.darkGray)]) {
            LRMoreInfo(title: "SSH Server Log") {
                if ssh.logTail.isEmpty {
                    Text("No SSH log entries yet.").font(.caption).foregroundColor(.secondary)
                } else {
                    ScrollView {
                        Text(ssh.logTail).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }
            }
            HStack(spacing: 10) {
                Button { ssh.refresh(queryGuest: true) } label: { Label("Refresh Status", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!runtimeRunning || ssh.busy)
                if ssh.isInstalled {
                    Button { ssh.installAndStart() } label: { Label("Repair SSH", systemImage: "wrench") }
                        .buttonStyle(.bordered).controlSize(.small).disabled(!runtimeRunning || ssh.installing || ssh.busy)
                }
            }
        }
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.footnote).foregroundColor(color)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.12)))
    }
}

struct ManagerView: View {
    @StateObject private var manager = EnvironmentManager()
    @StateObject private var ssh = SSHServiceController()
    let terminal: TerminalViewController
    @State private var selectedTab = 0
    @State private var runtimeRunning = LRRuntimeBridge.isRunning()
    @State private var startingRuntime = false
    @State private var showTaskManager = false
    @State private var autoStartRuntime = LRRuntimeBridge.autoStart()
    @AppStorage("LinuxRunner.developerMode") private var developerMode = false
    @AppStorage("LinuxRunner.keepScreenAwake") private var keepScreenAwake = true
    @AppStorage(BackgroundRunner.defaultsKey) private var keepRunningInBackground = false
    @ObservedObject private var backgroundRunner = BackgroundRunner.shared
    @AppStorage("LinuxRunner.experimentalMemoryPCFusion") private var memoryPCFusion = true
    @AppStorage("LinuxRunner.appearance") private var appearance = "dark"
    @State private var terminalAfterSetup = false
    @State private var setup = false
    @AppStorage("LinuxRunnerSetup.step") private var setupStep = "welcome"
    @State private var diagnostics = false
    @State private var importer = false
    @State private var session: TerminalPresentation?
    @State private var share: ExportItem?
    @State private var importRoot: String?
    @State private var confirmWipe = false
    @State private var wipeScheduledAlert = false
    @State private var wipeScheduled = LRRuntimeBridge.isWipePending()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationView { home }.navigationViewStyle(.stack)
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
            NavigationView { debianEnvironmentView }.navigationViewStyle(.stack)
                .tabItem { Label("Debian", systemImage: "server.rack") }.tag(1)
            NavigationView { preferences }.navigationViewStyle(.stack)
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .overlay(alignment: .bottom) { InstallProgressCard() }
        .accentColor(Color(red: 0.36, green: 0.68, blue: 0.98))
        .preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
        .onAppear {
            LongTaskCenter.shared.start()
            runtimeRunning = LRRuntimeBridge.isRunning()
            wipeScheduled = LRRuntimeBridge.isWipePending()
            if runtimeRunning {
                ssh.ensureDefaultSSHIfNeeded()
                ssh.refresh(queryGuest: false)
            }
            // First launch without Debian minimal installed, or setup waiting for its relaunch/account step.
            if !SetupAutoPresentation.shown && !simulatorSuppressesSetup &&
                (manager.environments.isEmpty || (setupStep == "relaunch" && LRRuntimeBridge.isRunning() && LRRuntimeBridge.activeRootName() == UserDefaults.standard.string(forKey: "LinuxRunnerSetup.root"))) {
                SetupAutoPresentation.shown = true
                setup = true
            }
        }
        #if targetEnvironment(simulator)
        .onAppear {
            SimulatorWorkflow.start(manager: manager,
                                    terminal: { if let environment = activeEnvironment { openTerminal(environment) } },
                                    type: { terminal.sendSessionInput($0) },
                                    tab: { selectedTab = $0 })
        }
        #endif
        .fullScreenCover(isPresented: $setup, onDismiss: {
            runtimeRunning = LRRuntimeBridge.isRunning()
            manager.refresh()
            if runtimeRunning { ssh.ensureDefaultSSHIfNeeded() }
            if terminalAfterSetup {
                terminalAfterSetup = false
                if let environment = activeEnvironment { openTerminal(environment) }
            }
        }) {
            SetupWizardView(manager: manager, openTerminal: { terminalAfterSetup = true })
        }
        .alert("Wipe Debian Minimal?", isPresented: $confirmWipe) {
            Button("Cancel", role: .cancel) { }
            Button("Wipe Everything", role: .destructive) {
                manager.wipeAll { needsRestart, failure in
                    if let failure {
                        manager.error = failure
                    } else if needsRestart {
                        wipeScheduled = true
                        wipeScheduledAlert = true
                    } else {
                        runtimeRunning = LRRuntimeBridge.isRunning()
                        wipeScheduled = false
                        ssh.status = [:]
                    }
                }
            }
        } message: {
            Text("Permanently erase Debian Minimal, including all installed APT packages, Linux home files, SSH keys, and DebianRunner Shared files? Export anything you need first. You can reinstall a clean Debian Minimal environment afterwards.")
        }
        .alert("Restart to Complete Wipe", isPresented: $wipeScheduledAlert) {
            Button("Close DebianRunner Now", role: .destructive) { exit(0) }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Debian Minimal is currently mounted. Close DebianRunner now and reopen it — the old filesystem will be wiped cleanly before startup so you can install fresh.")
        }
        .sheet(isPresented: $diagnostics) { DeveloperDiagnosticsView() }
        .fullScreenCover(item: $session) { item in
            TerminalScreen(controller: item.controller)
        }
        .sheet(item: $share) { item in ShareView(item: item) }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard let root = importRoot else { return }
            transfer(result: result, root: root)
        }
        .alert("DebianRunner", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { DispatchQueue.main.async { manager.error = nil } } })) {
            Button("OK") { manager.error = nil }
        } message: { Text(manager.error ?? "") }
        .onChange(of: phase) { newPhase in
            guard newPhase == .active else { return }
            runtimeRunning = LRRuntimeBridge.isRunning()
            wipeScheduled = LRRuntimeBridge.isWipePending()
            manager.refresh()
            if runtimeRunning { ssh.refresh(queryGuest: true) }
        }
    }

    private var activeEnvironment: LinuxEnvironment? { manager.environments.first(where: manager.active) }

    private var runtimePhase: HomeStatus.Phase {
        if manager.environments.isEmpty { return .uninstalled }
        if runtimeRunning { return .running }
        if startingRuntime { return .starting }
        return .stopped
    }

    private var currentEnvironment: LinuxEnvironment? {
        activeEnvironment ?? manager.environments.first
    }

    private func startRuntime() {
        guard !startingRuntime, LRRuntimeBridge.canStartRuntime(), !manager.environments.isEmpty else { return }
        startingRuntime = true
        // Yield once so the native loading state can be drawn before the
        // existing serialized boot path initializes the runtime.
        DispatchQueue.main.async {
            let result = LRRuntimeBridge.startRuntime()
            runtimeRunning = LRRuntimeBridge.isRunning()
            if runtimeRunning {
                if terminal.sessionTerminalUUID == nil {
                    terminal.loadViewIfNeeded()
                    terminal.startNewSession()
                }
                ssh.ensureDefaultSSHIfNeeded()
            } else {
                manager.error = "Runtime initialization failed (\(result)). " + LRRuntimeBridge.runtimeStatus()
            }
            startingRuntime = false
            manager.refresh()
        }
    }

    private func primaryHomeAction() {
        if manager.environments.isEmpty {
            startSetup()
        } else if !runtimeRunning {
            startRuntime()
        } else if let environment = activeEnvironment {
            openTerminal(environment)
        } else {
            if terminal.sessionTerminalUUID == nil { terminal.loadViewIfNeeded(); terminal.startNewSession() }
            session = TerminalPresentation(controller: terminal)
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DebianRunner").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(activeEnvironment.map { "\($0.name) \($0.rootfsVersion) · ARM64" } ?? (manager.environments.isEmpty ? "Debian minimal not installed" : "Debian minimal stopped"))
                            .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    HomeStatus(phase: runtimePhase, open: primaryHomeAction)
                }
                primaryAction
                HStack(spacing: 14) {
                    NavigationLink(destination: AppStoreView(manager: manager, run: run)) {
                        HomeTile(title: "Packages", symbol: "shippingbox.fill", colors: [.blue, .indigo], large: true)
                    }
                    .buttonStyle(HomeTileStyle()).disabled(activeEnvironment == nil).accessibilityIdentifier("Packages")
                    NavigationLink(destination: SSHServerView(ssh: ssh)) {
                        HomeTile(title: "SSH Server", symbol: "network", colors: [.green, .teal], large: true, badge: ssh.isRunning)
                    }
                    .buttonStyle(HomeTileStyle()).accessibilityIdentifier("SSH Server")
                }
                HStack(spacing: 14) {
                    NavigationLink(destination: SystemResourcesView()) {
                        HomeTile(title: "CPU & Memory", symbol: "memorychip.fill", colors: [.purple, .indigo], large: true)
                    }
                    .buttonStyle(HomeTileStyle()).accessibilityIdentifier("CPU & Memory")
                    homeTile("Task Manager", "chart.line.uptrend.xyaxis", [.yellow, .orange], large: true, enabled: runtimeRunning) { showTaskManager = true }
                }
                .fullScreenCover(isPresented: $showTaskManager) { TaskManagerView() }
                HStack(alignment: .top, spacing: 14) {
                    if let environment = currentEnvironment {
                        NavigationLink(destination: FileSharingView(environment: environment, manager: manager, share: $share)) { HomeTile(title: "Files", symbol: "folder.fill", colors: [.cyan, .blue]) }.buttonStyle(HomeTileStyle())
                    } else { HomeTile(title: "Files", symbol: "folder.fill", colors: [.cyan, .blue]).opacity(0.4) }
                    NavigationLink(destination: LinuxUsersView()) { HomeTile(title: "Users", symbol: "person.2.fill", colors: [.green, .teal]) }.buttonStyle(HomeTileStyle())
                    NavigationLink(destination: DevicesView()) { HomeTile(title: "Devices", symbol: "cable.connector", colors: [.orange, .red]) }.buttonStyle(HomeTileStyle())
                    NavigationLink(destination: GuestCrashListView()) { HomeTile(title: "Diagnostics", symbol: "stethoscope", colors: [.pink, .purple]) }.buttonStyle(HomeTileStyle())
                }
                HomeTasks(center: LongTaskCenter.shared)
                if !runtimeRunning && !startingRuntime && !manager.environments.isEmpty {
                    Text(LRRuntimeBridge.runtimeStatus()).font(.footnote).foregroundColor(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarHidden(true)
        .refreshable {
            runtimeRunning = LRRuntimeBridge.isRunning()
            manager.refresh()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        let uninstalled = manager.environments.isEmpty
        Button(action: primaryHomeAction) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.18)).frame(width: 44, height: 44)
                    if startingRuntime { ProgressView().tint(.white) }
                    else { Image(systemName: uninstalled ? "arrow.down.circle.fill" : runtimeRunning ? "terminal.fill" : "power").font(.title3.weight(.semibold)) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(uninstalled ? "Install Debian Minimal" : runtimeRunning ? "Open Terminal" : startingRuntime ? "Starting Debian…" : "Start Debian Minimal").font(.headline)
                    Text(uninstalled ? "Download & verify Debian 13 (trixie) ARM64" : runtimeRunning ? "Open an interactive Debian shell" : "Boot the ARM64 Linux runtime").font(.caption).opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.headline).opacity(0.7)
            }
            .foregroundColor(.white).padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(colors: [Color(red: 0.16, green: 0.42, blue: 0.85), Color(red: 0.36, green: 0.24, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        .buttonStyle(HomeTileStyle())
        .disabled(!uninstalled && !runtimeRunning && (startingRuntime || !LRRuntimeBridge.canStartRuntime()))
        .accessibilityIdentifier(uninstalled ? "Install Debian Minimal" : runtimeRunning ? "Open Terminal" : "Start Linux Runtime")
    }

    private func homeTile(_ title: String, _ symbol: String, _ colors: [Color], large: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { HomeTile(title: title, symbol: symbol, colors: colors, large: large) }
            .buttonStyle(HomeTileStyle()).disabled(!enabled).accessibilityIdentifier(title)
    }

    private func startSetup() {
        setupStep = SetupStep.install.rawValue
        setup = true
    }

    private var debianEnvironmentView: some View {
        Group {
            if let environment = currentEnvironment {
                let active = manager.active(environment)
                List {
                    Section {
                        HStack(spacing: 14) {
                            DistroBadge(size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Debian Minimal").font(.title3.weight(.semibold))
                                Text("\(environment.distribution) \(environment.rootfsVersion) · ARM64").font(.subheadline).foregroundColor(.secondary)
                                HStack(spacing: 6) {
                                    if wipeScheduled { StatusChip(text: "Wipe Pending", color: .orange) }
                                    else if active { StatusChip(text: "Running", color: .green) }
                                    else { StatusChip(text: "Stopped", color: .secondary) }
                                    Text(manager.size(environment)).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }.padding(.vertical, 4)
                        if active {
                            Button { openTerminal(environment) } label: { Label("Open Terminal", systemImage: "terminal") }
                        } else {
                            Button { startRuntime() } label: {
                                Label(startingRuntime ? "Starting Debian…" : "Start Debian Minimal", systemImage: "power")
                            }
                            .disabled(startingRuntime || !LRRuntimeBridge.canStartRuntime())
                        }
                    }

                    if wipeScheduled {
                        Section {
                            Label("Wipe scheduled for next launch. Close DebianRunner and reopen it to erase Debian Minimal cleanly.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundColor(.orange)
                            Button("Close DebianRunner Now", role: .destructive) { exit(0) }
                        }
                    }

                    Section("Environment") {
                        NavigationLink(destination: SSHServerView(ssh: ssh)) {
                            HStack {
                                Label("SSH Server", systemImage: "network")
                                Spacer()
                                Text(ssh.isRunning ? "Running · :\(ssh.port)" : ssh.installing ? "Installing…" : ssh.isInstalled ? "Stopped" : "Not Installed")
                                    .font(.caption).foregroundColor(ssh.isRunning ? .green : .secondary)
                            }
                        }
                        if active {
                            NavigationLink(destination: PackageView(environment: environment, manager: manager, run: run)) { Label("Packages (APT)", systemImage: "shippingbox") }
                            NavigationLink(destination: LinuxUsersView()) { Label("Linux Users", systemImage: "person.2") }
                        }
                        NavigationLink(destination: FileSharingView(environment: environment, manager: manager, share: $share)) { Label("Files & Apple Files", systemImage: "folder") }
                        NavigationLink(destination: StorageManagementView(environments: manager.environments)) { Label("Storage", systemImage: "internaldrive") }
                        if !active {
                            Text("Start Debian Minimal to manage APT packages and Linux users.").font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Section {
                        Button {
                            UserDefaults.standard.set(environment.rootfsName, forKey: "LinuxRunnerSetup.root")
                            LRRuntimeBridge.setNextRootName(environment.rootfsName)
                            setupStep = active ? SetupStep.account.rawValue : SetupStep.relaunch.rawValue
                            setup = true
                        } label: { Label("Continue Setup / Account", systemImage: "wrench.and.screwdriver") }
                    } footer: { Text("Re-runs Linux account setup without deleting files. APT checks and repairs are in Packages.") }

                    Section("Details & Launchers") {
                        DisclosureGroup("Installation Details") {
                            detailRow("Home", environment.homePath)
                            detailRow("Apple Files Mount", LRRuntimeBridge.fileProviderEnabled() ? "Enabled (\(LRRuntimeBridge.activeAppGroup()))" : "Shared folder only")
                            if let state = environment.installationState { detailRow("Installation", state) }
                            if let result = environment.lastBootResult { detailRow("Last boot result", result) }
                            detailRow("Created", environment.createdAt.formatted(date: .abbreviated, time: .shortened))
                            if let last = environment.lastBootedAt { detailRow("Last started", last.formatted(date: .abbreviated, time: .shortened)) }
                        }
                        DisclosureGroup("Command Launchers") {
                            ForEach(manager.environments.first(where: { $0.id == environment.id })?.applications ?? []) { app in
                                Button { run(app) } label: { VStack(alignment: .leading) { Text(app.name); Text(([app.command] + app.arguments).joined(separator: " ")).font(.caption).foregroundColor(.secondary) } }
                                    .disabled(!active).accessibilityIdentifier("run-\(app.name)")
                            }
                            NavigationLink("Create Command Launcher", destination: LauncherEditor { manager.add(application: $0, to: environment) })
                            if active && !manager.detected.isEmpty { ForEach(manager.detected) { app in Button(app.name) { run(app) } } }
                        }
                    }

                    Section {
                        Button(role: .destructive) { confirmWipe = true } label: {
                            Label(manager.busy ? "Wiping…" : "Wipe Debian Minimal…", systemImage: "trash")
                        }
                        .disabled(manager.busy)
                        .accessibilityIdentifier("Wipe Debian Minimal")
                    } header: { Text("Reset Environment") } footer: {
                        Text("Erases your Debian Minimal root filesystem, packages, Linux home files, SSH host keys, and Shared files so you can reinstall from scratch. Export any files you want to keep first.")
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Button { startSetup() } label: {
                            HStack(spacing: 14) {
                                DistroBadge(size: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Debian 13 (trixie) Minimal").font(.headline).foregroundColor(.primary)
                                    Text("Official ARM64 minimal userspace with APT, bash, built-in OpenSSH server, and Apple Files access.")
                                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.leading)
                                    Label("Install Debian Minimal", systemImage: "arrow.down.circle.fill")
                                        .font(.subheadline.weight(.semibold)).foregroundColor(.accentColor)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        }
                        .buttonStyle(HomeTileStyle()).disabled(manager.busy).accessibilityIdentifier("Install Debian Minimal")
                        if manager.busy { ProgressView("Preparing environment…") }
                    }
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 96)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
        }
        .navigationTitle("Debian Minimal")
        .toolbar {
            Button {
                runtimeRunning = LRRuntimeBridge.isRunning()
                manager.refresh()
                if runtimeRunning { ssh.refresh(queryGuest: true) }
            } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh Debian Minimal")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var preferences: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    DistroBadge(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DebianRunner").font(.title3.weight(.semibold))
                        Text(appVersion).font(.subheadline).foregroundColor(.secondary)
                        Text(activeEnvironment.map { "\($0.name) \($0.rootfsVersion) · ARM64" } ?? "Debian Minimal · ARM64").font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.vertical, 6)
            }
            Section {
                Picker(selection: $appearance) { Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system") } label: { SettingsLabel("Appearance", "circle.lefthalf.filled", .indigo) }
                Toggle(isOn: $keepScreenAwake) { SettingsLabel("Keep Screen Awake", "sun.max.fill", .orange) }
                Toggle(isOn: Binding(get: { LongTaskCenter.notificationsEnabled }, set: { LongTaskCenter.notificationsEnabled = $0 })) { SettingsLabel("Notify When Tasks Finish", "bell.badge.fill", .red) }
                Toggle(isOn: $keepRunningInBackground) { SettingsLabel("Keep Linux Running in Background", "infinity", .green) }
                    .onChange(of: keepRunningInBackground) { BackgroundRunner.shared.apply($0) }
            } header: { Text("General") } footer: {
                Text("Keep Linux Running in Background uses a background location session so SSH connections and long tasks stay alive when you switch apps.")
            }
            Section("Performance") {
                NavigationLink(destination: SystemResourcesView()) { SettingsLabel("CPU & Memory", "speedometer", .indigo) }
            }
            Section("Input & Controls") {
                NavigationLink(destination: TerminalSettingsView()) { SettingsLabel("Terminal & Keyboard", "keyboard.fill", .gray) }
            }
            Section("Linux Environment") {
                NavigationLink(destination: SSHServerView(ssh: ssh)) { SettingsLabel("SSH Server", "network", .green) }
                NavigationLink(destination: LinuxUsersView()) { SettingsLabel("Linux Users", "person.2.fill", .blue) }
                NavigationLink(destination: FileSharingView(environment: currentEnvironment, manager: manager, share: $share)) { SettingsLabel("File Sharing", "folder.fill", .cyan) }
                NavigationLink(destination: DevicesView()) { SettingsLabel("Devices", "cable.connector", .orange) }
                NavigationLink(destination: NetworkDiagnosticsView()) { SettingsLabel("Network", "wifi", .blue) }
            }
            Section("Storage & Maintenance") {
                NavigationLink(destination: StorageManagementView(environments: manager.environments)) { SettingsLabel("Storage", "internaldrive.fill", .gray) }
                Button {
                    Task.detached {
                        do {
                            let url = try LRRuntimeBridge.exportFullDiagnosticBundle()
                            await MainActor.run { share = ExportItem(url: url) }
                        } catch {
                            await MainActor.run { manager.error = error.localizedDescription }
                        }
                    }
                } label: { SettingsLabel("Export Diagnostics", "doc.text.magnifyingglass", .brown) }.foregroundColor(.primary)
            }
            Section {
                Toggle(isOn: $developerMode) { SettingsLabel("Developer Mode", "hammer.fill", .gray) }
                if developerMode {
                    Toggle(isOn: $autoStartRuntime) { SettingsLabel("Start Runtime on Launch", "power", .green) }.onChange(of: autoStartRuntime) { UserDefaults.standard.set($0, forKey: "LinuxRunnerRuntimeAutoStart") }
                    NavigationLink(destination: ExecutionEngineView()) { SettingsLabel("Execution Engine / StikDebug", "bolt.fill", .yellow) }
                    Toggle(isOn: $memoryPCFusion) { SettingsLabel("Memory Dispatch Fusion", "memorychip.fill", .teal) }
                    Button { diagnostics = true } label: { SettingsLabel("Runtime Diagnostics", "stethoscope", .pink) }.foregroundColor(.primary)
                }
            } header: { Text("Advanced") } footer: {
                if developerMode { Text("Memory Dispatch Fusion: on by default. Applies after fully closing and reopening DebianRunner. Uses the same Asbestos engine with fewer dispatch steps per memory access. Turn off to restore the previous memory dispatch path if a program misbehaves.") }
            }
            Section("About") {
                NavigationLink(destination: LinuxRunnerAboutView()) { SettingsLabel("About DebianRunner", "info.circle.fill", .blue) }
            }
        }.listStyle(.insetGrouped).navigationTitle("Settings")
    }

    private func openTerminal(_ environment: LinuxEnvironment) {
        guard manager.active(environment) else { return }
        if terminal.sessionTerminalUUID == nil { terminal.loadViewIfNeeded(); terminal.startNewSession() }
        session = TerminalPresentation(controller: terminal)
    }

    private func run(_ application: LinuxApplication) {
        do {
            try application.validate()
            guard LRRuntimeBridge.isRunning() else { manager.error = LRRuntimeBridge.runtimeStatus(); return }
            let controller = LRRuntimeBridge.terminal(forCommand: [application.command] + application.arguments, directory: application.workingDirectory)
            session = TerminalPresentation(controller: controller)
        } catch { manager.error = error.localizedDescription }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundColor(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.callout)
    }

    private func files(_ environment: LinuxEnvironment) -> some View {
        ExchangeFilesView(environment: environment, manager: manager, share: $share)
    }

    private func transfer(result: Result<[URL], Error>, root: String) {
        do {
            guard let source = try result.get().first else { return }
            manager.busy = true
            Task.detached {
                do { try LRRuntimeBridge.importSharedFile(source, relative: "", root: root, control: LRTransferControl()) }
                catch { await MainActor.run { manager.error = error.localizedDescription } }
                await MainActor.run { manager.busy = false; manager.refresh() }
            }
        } catch { manager.error = error.localizedDescription }
    }
}

/// Embeds a long-lived UIKit controller (the terminal) in SwiftUI so it can be
/// re-presented cleanly across full-screen covers.
struct NativeController: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { NativeContainer(embedding: controller) }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? NativeContainer)?.embedIfNeeded()
    }
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        (uiViewController as? NativeContainer)?.release()
    }
}

final class NativeContainer: UIViewController {
    private let child: UIViewController
    init(embedding child: UIViewController) { self.child = child; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        embedIfNeeded()
    }
    func embedIfNeeded() {
        guard isViewLoaded, child.parent !== self else { return }
        if child.parent != nil || child.view.superview != nil {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
    func release() {
        guard child.parent === self else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }
    override var childForStatusBarHidden: UIViewController? { child }
    override var childForStatusBarStyle: UIViewController? { child }
    override var childForHomeIndicatorAutoHidden: UIViewController? { child }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { child.supportedInterfaceOrientations }
}

struct TerminalScreen: View {
    let controller: TerminalViewController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        // Minimal chrome: true black and one blue Done (font size is in Settings).
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.font(.body.weight(.semibold)).foregroundColor(.accentColor)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            NativeController(controller: controller)
        }.background(Color.black.ignoresSafeArea())
         .onAppear { currentTerminalViewController = controller }
         .onDisappear {
             if currentTerminalViewController === controller { currentTerminalViewController = nil }
         }
    }
}

enum SetupAutoPresentation { static var shown = false }

struct LauncherEditor: View {
    var save: (LinuxApplication) -> Void
    @State private var name = ""
    @State private var command = "/usr/bin/python3"
    @State private var arguments = "[]"
    @State private var directory = "/root"
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Absolute executable", text: $command).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Arguments as a JSON array", text: $arguments).autocorrectionDisabled().textInputAutocapitalization(.never)
            Text("Example: [\"--version\"]. Each string is one argument; shell expansion is not applied.").font(.caption)
            TextField("Working directory", text: $directory).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Save Launcher") {
                do {
                    let args = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                    let app = LinuxApplication(name: name, command: command, arguments: args, workingDirectory: directory)
                    try app.validate(); save(app); dismiss()
                } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).foregroundColor(.red) }
        }.navigationTitle("Create Command Launcher")
    }
}

struct PackageView: View {
    let environment: LinuxEnvironment
    @ObservedObject var manager: EnvironmentManager
    var run: (LinuxApplication) -> Void
    @State private var query = ""
    @State private var packages: [LinuxPackageRecord] = []
    @State private var previousResult = ""
    @State private var resultReadID: UUID?
    @State private var resultsVisible = false
    @State private var details = ""
    @State private var log = ""
    @State private var status = "No package operation requested"
    @State private var pendingOperation: String?
    @State private var showConfirmation = false
    @State private var error: String?
    @State private var share: ExportItem?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var enabled: Bool { manager.active(environment) }
    private var support: URL { LRRuntimeBridge.exchangeURL(environment.rootfsName).appendingPathComponent(".linuxrunner/support") }
    var body: some View {
        Form {
            Section("Debian Environment") {
                Text(environment.distribution + " " + environment.rootfsVersion + " · " + environment.architecture)
                Text(enabled ? "Operations use Debian's real APT package manager." : "Select this environment for the next launch, then reopen DebianRunner.").font(.caption)
                Text(status).font(.caption).textSelection(.enabled)
            }
            Section("APT Operations") {
                Button("Installed Packages") { execute("installed") }
                Button("Refresh Repository Indexes") { execute("update") }
                Button("Available Updates") { execute("updates") }
                TextField("Package name or search term", text: $query).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Search") { execute("search") }.disabled(!PackageOperation.validName(query))
                Button("Package Details") { execute("details") }.disabled(!PackageOperation.validName(query))
                Button("Install Package") { confirm("install") }.disabled(!PackageOperation.validName(query))
                Button("Review Package Upgrade") { confirm("upgrade") }.disabled(!PackageOperation.validName(query))
                Button("Review Removal", role: .destructive) { confirm("remove") }.disabled(!PackageOperation.validName(query))
                Text("Output, dependency plans, and progress open in a Linux terminal. Removal asks for confirmation there. Close the terminal when finished, then refresh the installed list. Cancellation during configuration may require Repair Center.").font(.caption)
            }.disabled(!enabled)
            if !packages.isEmpty {
                Section("Package Results") {
                    ForEach(packages) { package in
                        Button { query = package.name; execute("details") } label: {
                            VStack(alignment: .leading) {
                                Text(package.name).font(.headline)
                                Text([package.version, package.architecture, package.status].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption)
                                if !package.summary.isEmpty { Text(package.summary).font(.caption) }
                            }
                        }.disabled(!enabled)
                    }
                }
            }
            if !details.isEmpty { Section("Package Details") { Text(details).font(.caption).textSelection(.enabled) } }
            Section("Repair Center") {
                Button("Diagnose Package State") { execute("diagnose") }
                Button("Check Dependencies") { execute("dependencies") }
                Button("Configure Interrupted Debian Packages") { confirm("configure") }
                Button("Check / Repair Package State") { confirm("repair") }
                Text("Repair runs native dpkg/APT maintainer scripts and keeps a package-database metadata checkpoint inside Linux. It is not a full snapshot or automatic rollback. APT dependency repair asks for confirmation before changing packages. Safe diagnostic mode: use Diagnose and Check Dependencies before repair.").font(.caption)
            }.disabled(!enabled)
            Section("Diagnostics") {
                if !log.isEmpty { Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Button("Export Diagnostic Report") {
                    do { share = ExportItem(url: try LRRuntimeBridge.exportFullDiagnosticBundle()) } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).foregroundColor(.red) }
        }.navigationTitle("APT Package Manager")
        .onAppear { resultsVisible = true; readResults(); manager.refresh() }.onReceive(timer) { _ in if UIApplication.shared.applicationState == .active { readResults() } }
        .onDisappear { resultsVisible = false; resultReadID = nil }
        .onChange(of: environment.rootfsName) { _ in
            resultReadID = nil; packages = []; details = ""; log = ""; previousResult = ""
            status = "No package operation requested"; readResults(); manager.refresh()
        }
        .confirmationDialog("Confirm Package Operation", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Continue in Linux Terminal") { if let operation = pendingOperation { execute(operation) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingOperation == "install"
                 ? "Install \(query) and its dependencies into \(environment.name) using APT?"
                 : pendingOperation == "upgrade"
                 ? "Review an APT upgrade of \(query) and its dependencies in \(environment.name)."
                 : pendingOperation == "remove"
                 ? "Review removal of \(query) in \(environment.name). The terminal will list affected packages and ask before removing them. No purge or autoremove is requested."
                 : "Run dpkg/APT configuration or repair in \(environment.name). Maintainer scripts may update system configuration. A metadata checkpoint is saved first; this does not restore arbitrary filesystem changes.")
        }
        .sheet(item: $share) { ShareView(item: $0) }
    }
    private func confirm(_ operation: String) { pendingOperation = operation; showConfirmation = true }
    private func execute(_ operation: String) {
        do {
            guard enabled, LRRuntimeBridge.activeRootName() == environment.rootfsName else { throw EnvironmentError.invalidMetadata }
            _ = try LRRuntimeBridge.prepareApplicationSupport()
            let command = try PackageOperation.command(operation, value: query)
            LRRuntimeBridge.logCategory("PACKAGE", event: "operation=\(operation) root=\(environment.rootfsName) requested")
            run(LinuxApplication(name: "Package " + operation, command: command[0], arguments: Array(command.dropFirst()), workingDirectory: "/root"))
        } catch { self.error = error.localizedDescription }
    }
    private func readResults() {
        guard resultsVisible && resultReadID == nil else { return }
        let request = UUID(), folder = support
        resultReadID = request
        DispatchQueue.global(qos: .utility).async {
            func read(_ name: String, _ bytes: UInt) -> String {
                LRRuntimeBridge.boundedDiagnosticTail(folder.appendingPathComponent(name), maxBytes: bytes)
            }
            let records = LinuxPackageRecord.parse(read("package-state.tsv", 262144))
            let detailText = read("package-details.txt", 16384)
            let logText = LRRuntimeBridge.redactDiagnosticText(read("package-operation.log", 8192), application: false)
            let code = read("package-result", 128).trimmingCharacters(in: .whitespacesAndNewlines)
            #if targetEnvironment(simulator)
            NotificationCenter.default.post(name: Notification.Name("LRSimulatorPackageResultRead"), object: nil, userInfo: ["mainThread": Thread.isMainThread, "records": records.count])
            #endif
            DispatchQueue.main.async {
                guard resultReadID == request else { return }
                resultReadID = nil; packages = records; details = detailText; log = logText
                if code != previousResult { previousResult = code; if code == "0" { manager.refresh() } }
                if code == "running" { status = "Operation running or interrupted; inspect terminal / Diagnose Package State." }
                else if !code.isEmpty { status = code == "0" ? "Last package operation completed (exit 0)" : "Last operation failed (exit \(code)); inspect logs and Repair Center." }
            }
        }
    }
}

struct ExportItem: Identifiable { let id = UUID(); let url: URL }
struct ShareView: UIViewControllerRepresentable {
    let item: ExportItem
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in LRRuntimeBridge.deleteExport(item.url) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// One entry point reuses both the guarded exchange and existing Files bookmarks.
private struct FileSharingView: View {
    let environment: LinuxEnvironment?
    @ObservedObject var manager: EnvironmentManager
    @Binding var share: ExportItem?
    @State private var folders: [[String: String]] = LRRuntimeBridge.sharedFolders()
    @State private var picking = false
    @State private var message: String?
    @State private var pendingRemoval: [String: String]?
    @State private var checks: [String: String] = [:]
    @State private var checking: String?
    @Environment(\.openURL) private var openURL
    private static let appFolderKey = "\u{1}app"

    private func verdict(_ summary: String) -> (ok: Bool, text: String) {
        if summary.contains("not running") { return (false, "Start Linux to check") }
        let failed = summary.contains("=failed") || summary.contains("=NO") || summary.contains("did not finish") || summary.contains("exists=0")
        return failed ? (false, "Problem found, see details") : (true, "Read, write and rename work both ways")
    }
    private func checkButton(_ key: String, run: @escaping (@escaping (String) -> Void) -> Void) -> some View {
        Button {
            checking = key
            run { summary in checks[key] = summary; checking = nil }
        } label: {
            Label(checking == key ? "Checking…" : "Check", systemImage: "checkmark.shield")
        }
        .disabled(checking != nil || !LRRuntimeBridge.isRunning())
    }
    @ViewBuilder private func result(_ key: String) -> some View {
        if let summary = checks[key] {
            let v = verdict(summary)
            Label(v.text, systemImage: v.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.footnote.weight(.medium)).foregroundColor(v.ok ? .green : .orange)
            if !v.ok { LRMoreInfo(title: "Details") { Text(summary).font(.caption.monospaced()).textSelection(.enabled) } }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let fpEnabled = LRRuntimeBridge.fileProviderEnabled()
                LRCard(title: "Apple Files (Full Linux /)", symbol: "externaldrive.fill.badge.checkmark", colors: [.indigo, .blue], value: fpEnabled ? "Mounted" : "App Group Required") {
                    if fpEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Label { Text("Files › Browse › Locations › DebianRunner › Debian Minimal").font(.caption).textSelection(.enabled) } icon: { Image(systemName: "folder.badge.gearshape") }
                            Text("Browse and edit the entire Debian Minimal root filesystem directly inside Apple's native Files app (enable DebianRunner under Locations › Edit in Files if hidden).")
                                .font(.caption)
                        }.foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                if let url = URL(string: "shareddocuments://") { openURL(url) }
                            } label: { Label("Open Files", systemImage: "arrow.up.forward.app").lineLimit(1) }
                            .buttonStyle(.borderedProminent)
                            Button {
                                LRRuntimeBridge.refreshFileProviderDomains()
                                message = "Refreshed Apple Files rootfs registration."
                            } label: { Label("Refresh Mount", systemImage: "arrow.clockwise") }
                            .buttonStyle(.bordered)
                        }.font(.subheadline.weight(.semibold)).controlSize(.small)
                    } else {
                        Text("To mount the full Debian root filesystem under Apple Files › Locations › DebianRunner, sign DebianRunner and its File Provider extension with an App Group entitlement (for example via AltStore, SideStore, Sideloadly, or Xcode). Until then, use DebianRunner Shared below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let environment {
                    let iosURL = LRRuntimeBridge.sharedExchangeURL(environment.rootfsName)
                    LRCard(title: "DebianRunner Shared", symbol: "folder.fill", colors: [.cyan, .blue], value: LRRuntimeBridge.isRunning() ? "Mounted" : "When Linux runs") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label { Text("/mnt/LinuxRunnerShared  ·  ~/Shared").font(.caption.monospaced()).textSelection(.enabled) } icon: { Image(systemName: "terminal") }
                            Label { Text("Files › On My iPhone › DebianRunner › Shared › \(environment.rootfsName)").font(.caption).textSelection(.enabled) } icon: { Image(systemName: "folder") }
                        }.foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                try? FileManager.default.createDirectory(at: iosURL, withIntermediateDirectories: true)
                                if let url = URL(string: "shareddocuments://" + iosURL.path) { openURL(url) }
                            } label: { Label("Files", systemImage: "arrow.up.forward.app").lineLimit(1) }
                            .accessibilityLabel("Open in Files")
                            .buttonStyle(.borderedProminent)
                            NavigationLink(destination: ExchangeFilesView(environment: environment, manager: manager, share: $share)) { Label("Browse", systemImage: "list.bullet") }
                                .buttonStyle(.bordered)
                            checkButton(Self.appFolderKey) { done in LRRuntimeBridge.checkAppSharedFolder(done) }.buttonStyle(.bordered)
                        }.font(.subheadline.weight(.semibold)).controlSize(.small)
                        result(Self.appFolderKey)
                    }
                } else {
                    LRCard(title: "DebianRunner Shared", symbol: "folder.fill", colors: [.cyan, .blue]) {
                        Text("Install or select a Debian environment first.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                LRCard(title: "Folders from Files", symbol: "externaldrive.fill.badge.plus", colors: [.orange, .pink], value: folders.isEmpty ? nil : "\(folders.count)") {
                    if folders.isEmpty {
                        Text("Link any folder from the Files app (iCloud Drive, a USB drive, a server). Linux sees it at /mnt/<name>.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(folders, id: \.self) { folder in
                        let name = folder["name"] ?? "", available = folder["available"] == "yes"
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: available ? "folder.fill" : "exclamationmark.triangle.fill").foregroundColor(available ? .accentColor : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder["displayName"] ?? name).font(.subheadline.weight(.semibold))
                                    Text(folder["mountPoint"] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                LRStatusPill(text: available ? "Linked" : "Unavailable", color: available ? .green : .orange)
                            }
                            if !available { Text("Moved, disconnected or access revoked. Reconnect it, or remove and add it again.").font(.caption).foregroundStyle(.orange) }
                            HStack(spacing: 10) {
                                checkButton(name) { done in LRRuntimeBridge.checkSharedFolder(name, completion: done) }
                                Button(role: .destructive) { pendingRemoval = folder } label: { Label("Remove", systemImage: "minus.circle") }
                            }.buttonStyle(.bordered).controlSize(.small).font(.caption.weight(.semibold))
                            result(name)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
                    }
                    Button { picking = true } label: { Label("Add Folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(!LRRuntimeBridge.isRunning())
                    if !LRRuntimeBridge.isRunning() { Text("Start Linux to add folders.").font(.caption).foregroundStyle(.secondary) }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    LRMoreInfo { Text("Linux programs read and write the folder where Files allows it; new files belong to the default Linux user. iCloud files download when opened. Removing a link never deletes the files.") }
                }

                if let environment {
                    LRCard(title: "Import & Export", symbol: "arrow.up.arrow.down", colors: [.green, .mint]) {
                        VStack(spacing: 6) {
                            NavigationLink(destination: ExchangeFilesView(environment: environment, manager: manager, share: $share)) {
                                LRNavRow(title: "Import Files", subtitle: "Copy files from iOS into Linux", symbol: "square.and.arrow.down", colors: [.blue, .cyan])
                            }
                            Divider()
                            NavigationLink(destination: ExchangeFilesView(environment: environment, manager: manager, share: $share)) {
                                LRNavRow(title: "Export Files", subtitle: "Save Linux files or folders (ZIP) to Files", symbol: "square.and.arrow.up", colors: [.purple, .indigo])
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12).padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("File Sharing").navigationBarTitleDisplayMode(.inline)
        .onAppear { folders = LRRuntimeBridge.sharedFolders() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { try LRRuntimeBridge.addSharedFolder(url); folders = LRRuntimeBridge.sharedFolders(); message = "Linked at " + (folders.first { $0["path"] == url.path }?["mountPoint"] ?? "/mnt") + "." }
                catch { message = error.localizedDescription }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .alert("Remove Linked Folder?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) { if let name = pendingRemoval?["name"] { LRRuntimeBridge.removeSharedFolder(name) }; pendingRemoval = nil; folders = LRRuntimeBridge.sharedFolders() }
        } message: { Text("Linux programs lose access to \(pendingRemoval?["mountPoint"] ?? "this folder"). The files themselves are not deleted.") }
    }
}

private struct SharedFileEntry: Identifiable {
    let name: String
    let directory: Bool
    let bytes: Int64
    var id: String { name }
}

private struct SaveToFilesPicker: UIViewControllerRepresentable {
    let url: URL
    let complete: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let complete: () -> Void
        init(_ complete: @escaping () -> Void) { self.complete = complete }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { complete() }
    }
}

struct ExchangeFilesView: View {
    let environment: LinuxEnvironment
    @ObservedObject var manager: EnvironmentManager
    @Binding var share: ExportItem?
    let relative: String
    @State private var entries: [SharedFileEntry] = []
    @State private var importer = false
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var failure: String?
    @State private var operation: LRTransferControl?
    @State private var progress: [String: NSNumber] = [:]
    @State private var save: ExportItem?
    @State private var snapshot: URL?
    @State private var selected: SharedFileEntry?
    private let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    init(environment: LinuxEnvironment, manager: EnvironmentManager, share: Binding<ExportItem?>, relative: String = "") {
        self.environment = environment; self.manager = manager; _share = share; self.relative = relative
    }
    private var guestPath: String { "/mnt/LinuxRunnerShared" + (relative.isEmpty ? "" : "/" + relative) }
    private func refresh() {
        Task.detached {
            do {
                let records = try LRRuntimeBridge.sharedEntries(relative, root: environment.rootfsName)
                let values = records.compactMap { item -> SharedFileEntry? in
                    guard let record = item as? [String: Any], let name = record["name"] as? String else { return nil }
                    return SharedFileEntry(name: name, directory: record["directory"] as? Bool == true, bytes: (record["bytes"] as? NSNumber)?.int64Value ?? 0)
                }
                await MainActor.run { entries = values }
            } catch { await MainActor.run { failure = error.localizedDescription } }
        }
    }
    private func export(_ entry: SharedFileEntry) {
        guard !manager.busy else { return }; let control = LRTransferControl(); operation = control; manager.busy = true; failure = nil
        Task.detached {
            do {
                let url = try LRRuntimeBridge.exportSharedItem(entry.name, relative: relative, root: environment.rootfsName, control: control)
                await MainActor.run { snapshot = url; save = ExportItem(url: url) }
            } catch { await MainActor.run { failure = error.localizedDescription } }
            await MainActor.run { operation = nil; manager.busy = false; refresh() }
        }
    }
    private func imported(_ result: Result<URL, Error>) {
        do {
            let source = try result.get(); let control = LRTransferControl(); operation = control; manager.busy = true; failure = nil
            Task.detached {
                do { try LRRuntimeBridge.importSharedFile(source, relative: relative, root: environment.rootfsName, control: control) }
                catch { await MainActor.run { failure = error.localizedDescription } }
                await MainActor.run { operation = nil; manager.busy = false; refresh() }
            }
        } catch { failure = error.localizedDescription }
    }
    var body: some View {
        List {
            Section("Destination in Linux") {
                Text(guestPath).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                Text("The selected Linux user also gets ~/Shared when that name is free. In iOS Files: On My iPhone/iPad → DebianRunner → Shared → \(environment.rootfsName). Each environment has its own folder.").font(.caption).foregroundColor(.secondary)
                Button("Import File Here") { importer = true }.disabled(manager.busy)
                Button("New Folder") { folderName = ""; creatingFolder = true }.disabled(manager.busy)
                if let operation {
                    let bytes = progress["bytes"]?.int64Value ?? 0, total = progress["total"]?.int64Value ?? 0
                    if total > 0 { ProgressView(value: Double(bytes), total: Double(total)) }
                    Text("Transferred \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(.caption)
                    Button("Cancel Transfer", role: .cancel) { operation.cancel() }
                }
                if let failure { Text(failure).font(.footnote).foregroundColor(.orange).textSelection(.enabled) }
            }
            Section("Files") {
                ForEach(entries) { entry in
                    if entry.directory {
                        NavigationLink(destination: ExchangeFilesView(environment: environment, manager: manager, share: $share, relative: relative.isEmpty ? entry.name : relative + "/" + entry.name)) {
                            Label(entry.name, systemImage: "folder")
                        }.contextMenu { Button("Export Folder as ZIP") { export(entry) } }
                    } else {
                        Button { selected = entry } label: {
                            HStack { Label(entry.name, systemImage: "doc"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundColor(.secondary) }
                        }.disabled(manager.busy)
                    }
                }
                if entries.isEmpty { Text("No visible files in this folder.").foregroundColor(.secondary) }
            }
            if !relative.isEmpty { Section { Button("Export This Folder as ZIP") { let leaf = (relative as NSString).lastPathComponent; exportParent(leaf) }.disabled(manager.busy) } }
            if relative.isEmpty {
                Section("Existing Files") { NavigationLink("Previous Downloads Exchange", destination: LegacyExchangeFilesView(environment: environment, manager: manager, share: $share)) }
            }
            Section { Text("Transfers stream data up to 512 MiB. Existing names are preserved. Exporting a directory creates a ZIP; links and special files are refused. Save changes before exporting a file that another app is editing.").font(.caption).foregroundColor(.secondary) }
        }.navigationTitle(relative.isEmpty ? "Shared Files" : (relative as NSString).lastPathComponent)
            .onAppear(perform: refresh).toolbar { Button("Refresh", action: refresh) }
            .onReceive(tick) { _ in if let operation { progress = operation.snapshot() as? [String: NSNumber] ?? [:] } }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.data], onCompletion: imported)
            .sheet(item: $save, onDismiss: { if let snapshot { LRRuntimeBridge.deleteExport(snapshot) }; snapshot = nil }) { item in SaveToFilesPicker(url: item.url) { save = nil } }
            .confirmationDialog("Export File", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { Button("Save to Files…") { export(selected); self.selected = nil } }
                Button("Cancel", role: .cancel) { selected = nil }
            }
            .alert("New Folder", isPresented: $creatingFolder) {
                TextField("Folder name", text: $folderName).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { }
                Button("Create") { do { try LRRuntimeBridge.createSharedDirectory(folderName, relative: relative, root: environment.rootfsName); refresh() } catch { failure = error.localizedDescription } }
            }
    }
    private func exportParent(_ leaf: String) {
        guard !manager.busy else { return }; let parent = (relative as NSString).deletingLastPathComponent
        let control = LRTransferControl(); operation = control; manager.busy = true; failure = nil
        Task.detached {
            do { let url = try LRRuntimeBridge.exportSharedItem(leaf, relative: parent == "." ? "" : parent, root: environment.rootfsName, control: control); await MainActor.run { snapshot = url; save = ExportItem(url: url) } }
            catch { await MainActor.run { failure = error.localizedDescription } }
            await MainActor.run { operation = nil; manager.busy = false }
        }
    }
}

private struct LegacyExchangeFilesView: View {
    let environment: LinuxEnvironment
    @ObservedObject var manager: EnvironmentManager
    @Binding var share: ExportItem?
    @State private var leaves: [String] = []
    @State private var importer = false
    var body: some View {
        List {
            Section {
                Text("Shared folder: /home/mobile/Downloads").font(.subheadline).textSelection(.enabled)
                Text("Copy files here in Linux to export them. Import supports regular files up to 512 MiB and preserves existing names.").font(.caption)
                Button("Import File") { importer = true }.disabled(manager.busy)
            }
            Section("Files — tap to export") {
                ForEach(leaves, id: \.self) { leaf in
                    Button(leaf) {
                        manager.busy = true
                        Task.detached {
                            do {
                                let url = try LRRuntimeBridge.exportFile(leaf, root: environment.rootfsName)
                                await MainActor.run { share = ExportItem(url: url) }
                            } catch { await MainActor.run { manager.error = error.localizedDescription } }
                            await MainActor.run { manager.busy = false }
                        }
                    }.disabled(manager.busy)
                }
                if leaves.isEmpty { Text("No files in the shared folder.").foregroundColor(.secondary) }
            }
        }.navigationTitle("Files")
         .onAppear(perform: refresh)
         .toolbar { Button("Refresh", action: refresh) }
         .fileImporter(isPresented: $importer, allowedContentTypes: [.data]) { result in
             do {
                 let source = try result.get()
                 manager.busy = true
                 Task.detached {
                     do { try LRRuntimeBridge.importFile(source, root: environment.rootfsName) }
                     catch { await MainActor.run { manager.error = error.localizedDescription } }
                     await MainActor.run { manager.busy = false; refresh(); manager.refresh() }
                 }
             } catch { manager.error = error.localizedDescription }
         }
    }
    private func refresh() {
        leaves = ((try? FileManager.default.contentsOfDirectory(at: LRRuntimeBridge.exchangeURL(environment.rootfsName), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []).filter {
            guard !$0.lastPathComponent.hasPrefix("."), let info = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return info.isRegularFile == true && info.isSymbolicLink != true
        }.map(\.lastPathComponent).sorted()
    }
}

struct DeveloperDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [[String: Any]] = []
    @State private var health: [String: Any] = [:]
    @State private var search = ""
    @State private var category = "All"
    @State private var severity = "All"
    @State private var pid = ""
    @State private var syscall = ""
    @State private var level = UserDefaults.standard.object(forKey: "DiagnosticLevel") == nil ? 2 : UserDefaults.standard.integer(forKey: "DiagnosticLevel")
    @State private var retention = UserDefaults.standard.object(forKey: "DiagnosticRetention") == nil ? 4 : UserDefaults.standard.integer(forKey: "DiagnosticRetention")
    @State private var share: ExportItem?
    @State private var failure: String?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var filtered: [[String: Any]] { entries.filter { entry in
        (category == "All" || entry["category"] as? String == category) &&
        (severity == "All" || entry["level"] as? String == severity) &&
        (pid.isEmpty || (entry["pid"] as? Int) == Int(pid) || (entry["tid"] as? Int) == Int(pid)) &&
        (search.isEmpty || String(describing: entry["message"] ?? "").localizedCaseInsensitiveContains(search))
    } }
    var body: some View {
        NavigationView {
            List {
                Section("Runtime health") { ForEach(health.keys.sorted(), id: \.self) { key in HStack { Text(key); Spacer(); Text(String(describing: health[key] ?? "unavailable")).foregroundColor(.secondary).textSelection(.enabled) } } }
                Section("Logging") {
                    Picker("Level", selection: $level) { ForEach(DiagnosticLevel.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                    Text("TRACE records successful calls and has substantial overhead. Logs rotate at 1 MiB.").font(.caption)
                    Stepper("Previous log files: \(retention)", value: $retention, in: 1...16).onChange(of: retention) { value in DiagnosticCenter.setRetention(value) }
                    TextField("Guest PID/TID (optional)", text: $pid).keyboardType(.numberPad)
                    TextField("Syscall number (optional)", text: $syscall).keyboardType(.numberPad)
                    Button("Apply tracing filters") { LRRuntimeBridge.configureDiagnostics(Int32(level), process: Int32(pid) ?? -1, syscall: Int32(syscall) ?? -1, errorsOnly: level < 4) }
                }
                Section("Live logs") {
                    Picker("Category", selection: $category) { Text("All").tag("All"); ForEach(Array(Set(entries.compactMap { $0["category"] as? String })).sorted(), id: \.self) { Text($0).tag($0) } }
                    Picker("Severity", selection: $severity) { Text("All").tag("All"); ForEach(DiagnosticLevel.allCases, id: \.rawValue) { Text($0.label).tag($0.label) } }
                    TextField("Search messages", text: $search)
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading) {
                            Text("\(entry["level"] ?? "") · \(entry["category"] ?? "") · PID \(entry["pid"] ?? 0)").font(.caption).foregroundColor(.secondary)
                            Text(entry["message"] as? String ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Button("Copy Filtered Logs") { UIPasteboard.general.string = filtered.map { String(describing: $0["message"] ?? "") }.joined(separator: "\n") }
                    Button("Export Full Diagnostic Bundle") {
                        Task.detached {
                            do { let url = try LRRuntimeBridge.exportFullDiagnosticBundle(); await MainActor.run { share = ExportItem(url: url) } }
                            catch { await MainActor.run { failure = error.localizedDescription } }
                        }
                    }
                    Text("Export includes redacted diagnostic records and recent package/installer logs. Keys, cookies, input payloads, and arbitrary user program output are excluded.").font(.caption)
                    if let failure { Text(failure).foregroundColor(.red) }
                }
            }.navigationTitle("Developer Diagnostics").toolbar { Button("Done") { dismiss() } }
        }.navigationViewStyle(.stack).onAppear(perform: refresh).onReceive(tick) { _ in if UIApplication.shared.applicationState == .active { refresh() } }.sheet(item: $share) { ShareView(item: $0) }
    }
    private func refresh() { entries = LRRuntimeBridge.diagnosticEntries().compactMap { $0 as? [String: Any] }; health = LRRuntimeBridge.healthSummary() as? [String: Any] ?? [:] }
}

struct StorageManagementView: View {
    let environments: [LinuxEnvironment]
    @State private var usage: [String: Int64] = [:]
    @State private var free: Int64?
    @State private var cleaning = false
    var body: some View {
        List {
            Section("Persistent storage") { ForEach(usage.keys.sorted(), id: \.self) { key in HStack { Text(key); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usage[key] ?? 0, countStyle: .file)) } } }
            Section { if let free { Text("Host available: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))") }
                Button("Clean Temporary Files") { cleaning = true }
                Text("Removes only LinuxRunner's inactive installation staging files. User files, Debian environments, and APT packages are preserved.").font(.caption)
            }
        }.navigationTitle("Storage").onAppear(perform: measure)
        .confirmationDialog("Remove inactive temporary installation files?", isPresented: $cleaning) { Button("Clean Temporary Files") {
            let staging = LRRuntimeBridge.managedStorageURL().appendingPathComponent("installer-temporary")
            if !UserDefaults.standard.bool(forKey: "InstallerActive") { try? FileManager.default.removeItem(at: staging) }
            measure()
        } }
    }
    private func measure() {
        let items = environments
        Task.detached(priority: .utility) {
            var values: [String: Int64] = [:]
            for e in items { values["\(e.name) rootfs"] = StorageUsage.bytes(LRRuntimeBridge.rootURL(e.rootfsName)); values["\(e.name) shared files"] = StorageUsage.bytes(LRRuntimeBridge.exchangeURL(e.rootfsName)); values["\(e.name) package cache (part of rootfs)"] = StorageUsage.bytes(LRRuntimeBridge.rootURL(e.rootfsName).appendingPathComponent("data/var/cache")) }
            let base = LRRuntimeBridge.managedStorageURL()
            values["Diagnostics"] = StorageUsage.bytes(base.deletingLastPathComponent().appendingPathComponent("LinuxRunnerDiagnostics"))
            values["Installation downloads"] = StorageUsage.bytes(base.appendingPathComponent("downloads"))
            values["Installation staging"] = StorageUsage.bytes(base.appendingPathComponent("installer-temporary"))
            values["Total persistent container"] = StorageUsage.bytes(base)
            values["Bundled application"] = StorageUsage.bytes(Bundle.main.bundleURL)
            let available = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            await MainActor.run { usage = values; free = available }
        }
    }
}

struct ExecutionEngineView: View {
    @State private var confirmJITRetry = false
    @State private var status = LRRuntimeBridge.executionBackendStatus() as? [String: Any] ?? [:]
    @State private var report = LRRuntimeBridge.jitStatusReport() as? [String: Any] ?? [:]
    @State private var mode = LRRuntimeBridge.executionMode()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var requested = false
    @State private var message: String?
    private var compiled: Bool { status["compiled"] as? Bool ?? false }
    private var active: Bool { (status["active"] as? String) == "jit" }
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: jitStateIcon).foregroundColor(jitStateColor)
                    Text(report["state"] as? String ?? "Interpreter Active").bold()
                }
                Text(report["detail"] as? String ?? "").font(.footnote).foregroundColor(.secondary)
                if compiled {
                    LabeledRow("Running", active ? "ARM64 JIT (with interpreter for untranslated code)" : "ARM64 Interpreter")
                    LabeledRow("Debugger attached", (report["debugger"] as? Bool ?? false) ? "Yes" : "No")
                    LabeledRow("Guest blocks translated", "\((report["blocks"] as? NSNumber)?.uint64Value ?? 0)")
                    LabeledRow("Native code", "\((report["code_kb"] as? NSNumber)?.uint64Value ?? 0) KB")
                    LabeledRow("iOS", report["os"] as? String ?? "")
                }
            } header: { Text("JIT Status") } footer: {
                Text("JIT Active is shown only after LinuxRunner ran test code in its JIT region and installed translated guest code that the runtime now executes. StikDebug reporting that JIT was assigned is not enough on its own.")
            }
            if compiled {
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Interpreter").tag("interpreter")
                        Text("Automatic").tag("automatic")
                        Text("JIT").tag("jit")
                    }.onChange(of: mode) { LRRuntimeBridge.setExecutionMode($0) }
                } footer: {
                    Text("Interpreter always works. Automatic and JIT start the JIT only after iOS allows it — LinuxRunner launched or attached by StikDebug — and otherwise keep the interpreter. The active backend above is what actually runs.")
                }
                if !active && (mode != "interpreter" || (report["debugger"] as? Bool ?? false)) {
                    Section {
                        Button("Attach with StikDebug") { requestAttachment() }
                        Button("Activate JIT Now") {
                            if report["activationQuarantined"] as? Bool == true { confirmJITRetry = true }
                            else { activate() }
                        }
                        if let message { Text(message).font(.footnote).foregroundColor(.orange) }
                    } footer: {
                        Text(LRRuntimeBridge.requiresPreparedJITRegion()
                             ? "This device needs StikDebug's universal.js script. Tap Attach with StikDebug (it asks for the script), return here, and LinuxRunner prepares its code region while StikDebug stays attached; Activate JIT Now retries safely at any time."
                             : "StikDebug attaches and detaches; return here and LinuxRunner checks whether iOS now allows its code region.")
                    }
                }
            } else {
                Section { Text("This build is interpreter-only. The JIT-capable LinuxRunner build adds the JIT option here; the interpreter remains the default there too.").font(.footnote) }
            }
        }.navigationTitle("Execution Engine")
        .alert("Retry JIT Activation?", isPresented: $confirmJITRetry) {
            Button("Cancel", role: .cancel) { }
            Button("Retry JIT") { activate(retryQuarantined: true) }
        } message: {
            Text("An earlier activation ended before verification. Save your Linux work first: another attempt may close LinuxRunner. This retries the method for this iOS version once; automatic retries remain blocked if it fails again.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if requested { requested = false; activate() } else { refresh() }
        }
        .onReceive(ticker) { _ in if UIApplication.shared.applicationState == .active { refresh() } }
    }
    private var jitStateIcon: String {
        switch report["state"] as? String {
        case "JIT Active": return "bolt.fill"
        case "JIT Initializing", "JIT Available": return "bolt"
        case "JIT Failed", "JIT Unavailable": return "exclamationmark.triangle"
        case "Waiting for JIT Authorization": return "hourglass"
        default: return "cpu"
        }
    }
    private var jitStateColor: Color {
        switch report["state"] as? String {
        case "JIT Active": return .green
        case "JIT Failed", "JIT Unavailable": return .orange
        default: return .secondary
        }
    }
    private func refresh() {
        status = LRRuntimeBridge.executionBackendStatus() as? [String: Any] ?? [:]
        report = LRRuntimeBridge.jitStatusReport() as? [String: Any] ?? [:]
    }
    private func activate(retryQuarantined: Bool = false) {
        var detail: NSString?
        if mode == "interpreter" { mode = "automatic"; LRRuntimeBridge.setExecutionMode(mode) }
        let ok = retryQuarantined ? LRRuntimeBridge.retryJIT(afterFailure: &detail) : LRRuntimeBridge.activateJIT(&detail)
        message = ok ? nil : detail as String?
        refresh()
    }
    private func requestAttachment() {
        guard let url = LRRuntimeBridge.stikDebugRequestURL(), UIApplication.shared.canOpenURL(url) else {
            message = "StikDebug is not installed or not set up. Install it, pair this device, then try again."
            return
        }
        requested = true
        LRRuntimeBridge.logCategory("JIT", event: "StikDebug attachment requested")
        UIApplication.shared.open(url, options: [:]) { opened in if !opened { requested = false; message = "StikDebug could not be opened." } }
    }
}

private struct LabeledRow: View {
    let label: String, value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View { HStack { Text(label).foregroundColor(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.footnote) }
}

// Public host information only: no SSID entitlement, scan, probe or namespace.
@MainActor private final class HostNetworkStatus: ObservableObject {
    @Published var status = "Waiting for system path"
    @Published var connection = "Unknown"
    @Published var details = ""
    @Published var addresses: [String] = []
    @Published var availableInterfaces: [String] = []
    private var monitor: NWPathMonitor?
    private var generation: UInt64 = 0
    func start() {
        guard monitor == nil else { refreshAddresses(); return }
        generation &+= 1; let generation = self.generation
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let names: [(NWInterface.InterfaceType, String)] = [(.wifi,"Wi-Fi"),(.cellular,"Cellular"),(.wiredEthernet,"Ethernet"),(.loopback,"Loopback"),(.other,"Other / VPN")]
            let used = names.filter { path.usesInterfaceType($0.0) }.map { $0.1 }.joined(separator: ", ")
            let state = path.status == .satisfied ? "Available" : path.status == .requiresConnection ? "Connection required" : "Unavailable"
            let interfaces = path.availableInterfaces.map { interface in "\(interface.name) · index \(interface.index) · \(names.first(where: { $0.0 == interface.type })?.1 ?? "Other")" }.sorted()
            let details = "IPv4: \(path.supportsIPv4 ? "yes" : "no") · IPv6: \(path.supportsIPv6 ? "yes" : "no") · DNS: \(path.supportsDNS ? "yes" : "no")" + (path.isExpensive ? " · Metered" : "") + (path.isConstrained ? " · Low Data Mode" : "")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.monitor != nil, self.generation == generation else { return }
                self.status = state; self.connection = used.isEmpty ? "No selected interface" : used
                self.details = details; self.availableInterfaces = interfaces; self.refreshAddresses()
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.linuxrunner.network-status"))
        refreshAddresses()
    }
    func stop() { generation &+= 1; monitor?.cancel(); monitor = nil }
    deinit { monitor?.cancel() }
    func refreshAddresses() {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { addresses = ["Interface snapshot unavailable"]; return }
        defer { freeifaddrs(list) }
        var result = Set<String>(), cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let name = entry.pointee.ifa_name, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert("\(String(cString: name)): \(String(cString: host))")
            }
        }
        addresses = result.sorted()
    }
}

private struct NetworkDiagnosticsView: View {
    @StateObject private var network = HostNetworkStatus()
    var body: some View {
        List {
            Section {
                HStack { Text("System path"); Spacer(); Text(network.status).foregroundStyle(.secondary) }
                HStack { Text("Connection"); Spacer(); Text(network.connection).foregroundStyle(.secondary) }
                Text(network.details).font(.caption)
            } header: { Text("iOS Network Path") } footer: { Text("Path availability is not a test of a particular server or of local-network permission. Changes are reported by iOS while this screen is open.") }
            Section {
                ForEach(network.addresses, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                Button("Refresh Addresses", action: network.refreshAddresses)
            } header: { Text("Host Interface Addresses") } footer: { Text("These are real host addresses, shared with iOS and other apps; LinuxRunner has no separate network namespace. Review addresses before sharing a screenshot. No network requests are sent by this screen.") }
            Section("Interfaces Available to iOS") {
                ForEach(network.availableInterfaces, id: \.self) { Text($0).font(.caption.monospaced()) }
                Text("An Ethernet adapter recognized by iOS can carry LinuxRunner connections through the host route. This list does not identify its USB chipset or grant Linux direct adapter ownership. The active connection type appears above.").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Text("Linux TCP and UDP sockets use host sockets. Linux interface queries expose a read-only compatibility view. Host routing and local-network permission remain controlled by iOS.")
                Text("Nearby Wi-Fi scanning and raw interface control are unavailable through ordinary public iOS APIs. This screen does not request location access or a Wi-Fi entitlement.")
            } header: { Text("Capabilities") }
        }.navigationTitle("Network").onAppear { network.start() }.onDisappear { network.stop() }
    }
}

// What external devices reach Debian minimal, detected live through public iOS APIs.
// iOS gives apps no raw USB access, so each category says which path it uses.
private struct DevicesView: View {
    private struct Row: Identifiable { let id = UUID(); let name: String; let symbol: String; let detected: String; let linux: String; let works: Bool; let connected: Bool }
    @State private var rows: [Row] = []
    @State private var selected: Row?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private func tile(_ row: Row) -> some View {
        Button { selected = row } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    LRIconTile(symbol: row.symbol, colors: row.works ? [.blue, .cyan] : [.gray, Color(.darkGray)], size: 34)
                    Spacer()
                    if row.connected { Circle().fill(Color.green).frame(width: 8, height: 8) }
                }
                Text(row.name).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    LRStatusPill(text: row.works ? "Works" : "Not yet", color: row.works ? .green : .secondary)
                    Text(row.detected).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }.buttonStyle(HomeTileStyle())
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
                VStack(spacing: 12) {
                    ForEach(pairs.indices, id: \.self) { index in
                        HStack(spacing: 12) {
                            ForEach(pairs[index]) { tile($0) }
                            if pairs[index].count == 1 { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }

                LRCard(title: "Development Boards", symbol: "memorychip", colors: [.orange, .red]) {
                    VStack(spacing: 6) {
                        NavigationLink(destination: BluetoothSerialView()) { LRNavRow(title: "Bluetooth Serial", subtitle: "ESP32, Arduino BLE → /dev/ttyBLE", symbol: "dot.radiowaves.left.and.right", colors: [.blue, .indigo]) }
                        Divider()
                        NavigationLink(destination: USBSerialView()) { LRNavRow(title: "USB Serial Adapter", subtitle: "Pico, ESP32-S3, Leonardo → /dev/ttyMIDI", symbol: "cable.connector", colors: [.teal, .green]) }
                        Divider()
                        NavigationLink(destination: EmbeddedCompatibilityView()) { LRNavRow(title: "What Works", subtitle: "Embedded development on iPhone", symbol: "checklist", colors: [.purple, .pink]) }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12).padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Devices").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh).onReceive(timer) { _ in if UIApplication.shared.applicationState == .active { refresh() } }
        .alert(selected?.name ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            Button("OK", role: .cancel) { selected = nil }
        } message: { Text(selected.map { "\($0.detected)\n\n\($0.linux)" } ?? "") }
    }
    private func refresh() {
        let folders = LRRuntimeBridge.sharedFolders()
        let available = folders.filter { $0["available"] == "yes" }.count
        let keyboard = GCKeyboard.coalesced != nil
        let bleLinks = LRBLESerial.shared().links.count
        let midiLinks = LRMIDISerial.shared().links.count
        rows = [
            Row(name: "Keyboard", symbol: "keyboard", detected: keyboard ? "Connected" : "None", linux: "Key presses from USB and Bluetooth keyboards go directly to the Linux terminal.", works: true, connected: keyboard),
            Row(name: "Drives & Folders", symbol: "externaldrive", detected: folders.isEmpty ? "None shared" : "\(available) of \(folders.count)", linux: "Folders you share in File Sharing (on a drive, iCloud, or On My iPhone) appear in Linux at /mnt/<name>.", works: true, connected: available > 0),
            Row(name: "Serial Links", symbol: "dot.radiowaves.left.and.right", detected: (bleLinks + midiLinks) == 0 ? "None" : "\(bleLinks + midiLinks) active", linux: "Bluetooth LE serial boards (/dev/ttyBLE0-3) and USB-MIDI serial adapters (/dev/ttyMIDI0-3) are exposed to Linux.", works: true, connected: (bleLinks + midiLinks) > 0),
            Row(name: "USB Serial & Raw USB", symbol: "cable.connector", detected: "—", linux: "iOS gives apps no USB host access to CH340, CP210x, or FTDI chips. Use a USB Serial Adapter (USB MIDI), Bluetooth Serial, or Wi-Fi instead.", works: false, connected: false),
        ]
    }
}

// Native screens opened from Objective-C (the terminal's settings button and
// Command-comma).
@objc(LRNativeScreens) final class LRNativeScreens: NSObject {
    @objc static func terminalSettings() -> UIViewController {
        let host = UIHostingController(rootView: NavigationView { TerminalSettingsView() }.navigationViewStyle(.stack))
        host.modalPresentationStyle = .formSheet
        return host
    }
}

// Open-source components and their licenses. Bundled notice files are shown verbatim.
private struct NoticesView: View {
    @Environment(\.dismiss) private var dismiss
    private let components: [(String, String)] = [
        ("DebianRunner (Eray Arslan / erayarslan)", "Headless Debian minimal ARM64 fork of LinuxRunner. GNU GPL version 3."),
        ("LinuxRunner (Leminos / mxhm11cr)", "Direct upstream project introducing ARM64 userspace and Debian support on iOS. GNU GPL version 3."),
        ("ios-linuxkit (Rui Carmo)", "Upstream runtime derived from iSH. Same license terms as iSH."),
        ("iSH (Theodore Dubois)", "Foundational userspace Linux runtime for iOS. GNU GPL version 3 (contributions after 0e3a4144 also GPL version 2), with the iSH App Store terms in LICENSE.IOS."),
        ("Linux kernel headers", "GNU GPL version 2 with the Linux syscall note."),
        ("xterm.js, hterm, ghostty-web", "Terminal frontends: MIT (xterm.js), BSD 3-Clause (hterm, The Chromium OS Authors), ghostty-web (see project notices)."),
        ("Fira Code and JetBrains Mono (Nerd Fonts)", "SIL Open Font License 1.1."),
        ("libarchive", "BSD 2-Clause License."),
        ("Debian GNU/Linux packages", "Downloaded and installed from Debian's official repositories under each package's own license (/usr/share/doc/<package>/copyright in Linux)."),
    ]
    private var bundled: [(String, String)] {
        guard let support = Bundle.main.url(forResource: "Support", withExtension: "bundle") else { return [] }
        return ["terminal-notices.txt"].compactMap { name in
            (try? String(contentsOf: support.appendingPathComponent(name))).map { (name, $0) }
        }
    }
    var body: some View {
        NavigationView {
            List {
                Section { ForEach(components, id: \.0) { item in VStack(alignment: .leading, spacing: 4) { Text(item.0).font(.headline); Text(item.1).font(.footnote).foregroundStyle(.secondary) } } }
                ForEach(bundled, id: \.0) { item in Section(item.0) { Text(item.1).font(.caption.monospaced()).textSelection(.enabled) } }
            }
            .navigationTitle("Notices & Credits")
            .toolbar { Button("Done") { dismiss() } }
        }.navigationViewStyle(.stack)
    }
}

private struct TerminalSettingsView: View {
    private let prefs = UserPreferences.shared()
    @State private var fontSize = 12.0
    @State private var cursor = 0
    @State private var blink = true
    @State private var scheme = 0
    @State private var capsLock = 0
    @State private var optionEscape = false
    @State private var backtickEscape = false
    @State private var controlSpace = false
    @State private var hideExtraKeys = false
    @AppStorage("LinuxRunnerTerminal.sharpness") private var sharpness = "sharp"
    var body: some View {
        Form {
            Section {
                Picker("Text Sharpness", selection: $sharpness) { Text("Sharp").tag("sharp"); Text("Balanced").tag("balanced"); Text("Battery Saver").tag("battery") }
                    .onChange(of: sharpness) { _ in prefs.fontSize = prefs.fontSize }
            } footer: { Text("Sharp draws terminal text at the screen's full resolution. Battery Saver uses one pixel per point: lighter, but softer on Retina screens.") }
            Section("Appearance") {
                Stepper(value: $fontSize, in: 8...32, step: 1) { HStack { Text("Font Size"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary) } }
                    .onChange(of: fontSize) { prefs.fontSize = NSNumber(value: $0) }
                Picker("Cursor", selection: $cursor) { Text("Block").tag(0); Text("Bar").tag(1); Text("Underline").tag(2) }
                    .onChange(of: cursor) { if let v = CursorStyle(rawValue: $0) { prefs.cursorStyle = v } }
                Toggle("Blinking Cursor", isOn: $blink).onChange(of: blink) { prefs.blinkCursor = $0 }
                Picker("Colors", selection: $scheme) { Text("Match System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
                    .onChange(of: scheme) { prefs.colorScheme = .init(rawValue: $0) ?? prefs.colorScheme }
            }
            Section {
                Picker("Caps Lock", selection: $capsLock) { Text("Caps Lock").tag(0); Text("Control").tag(1); Text("Escape").tag(2) }
                    .onChange(of: capsLock) { if let v = CapsLockMapping(rawValue: $0) { prefs.capsLockMapping = v } }
                Toggle("Option Sends Escape", isOn: $optionEscape).onChange(of: optionEscape) { prefs.optionMapping = $0 ? OptionMapEsc : OptionMapNone }
                Toggle("Backtick Sends Escape", isOn: $backtickEscape).onChange(of: backtickEscape) { prefs.backtickMapEscape = $0 }
                Toggle("Ctrl-Space Goes to Linux", isOn: $controlSpace).onChange(of: controlSpace) { prefs.overrideControlSpace = $0 }
                Toggle("Hide Extra Keys with Hardware Keyboard", isOn: $hideExtraKeys).onChange(of: hideExtraKeys) { prefs.hideExtraKeysWithExternalKeyboard = $0 }
            } header: { Text("Keyboard") } footer: { Text("The terminal's key bar provides Esc, Tab, Ctrl, Alt, and arrow keys on screen. Changes apply to open terminals.") }
        }
        .navigationTitle("Terminal & Keyboard")
        .onAppear {
            fontSize = prefs.fontSize.doubleValue; cursor = prefs.cursorStyle.rawValue; blink = prefs.blinkCursor; scheme = prefs.colorScheme.rawValue
            capsLock = prefs.capsLockMapping.rawValue; optionEscape = prefs.optionMapping == OptionMapEsc; backtickEscape = prefs.backtickMapEscape
            controlSpace = prefs.overrideControlSpace; hideExtraKeys = prefs.hideExtraKeysWithExternalKeyboard
        }
    }
}

private struct LinuxRunnerAboutView: View {
    @State private var notices = false
    var body: some View { List {
        Section { Text("DebianRunner").font(.system(size: 30, weight: .bold, design: .rounded)); Text("Headless Debian minimal ARM64 userspace for iPhone and iPad.").foregroundColor(.secondary) }
        Section("Developer Build") {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))")
            Text("Source: " + (Bundle.main.object(forInfoDictionaryKey: "LinuxRunnerSourceCommit") as? String ?? "unknown")).font(.caption).textSelection(.enabled)
            Text("Debian 13 minimal → ARM64 userspace runtime → Linux ABI compatibility → iOS/XNU").font(.caption)
        }
        Section { Button("Third-Party Notices & Credits") { notices = true }; Text("DebianRunner includes open-source components. Their licenses and attribution remain available; no kernel or virtual machine is booted.").font(.caption).foregroundColor(.secondary) }
    }.navigationTitle("About").sheet(isPresented: $notices) { NoticesView() } }
}

struct GuestCrashListView: View {
    @State private var reports: [GuestCrashReport] = []
    var body: some View {
        List {
            if reports.isEmpty { Text("No guest application failures recorded.").foregroundColor(.secondary) }
            ForEach(reports) { report in
                NavigationLink(destination: GuestCrashDetailView(report: report)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.summary).font(.subheadline)
                        Text(report.timestamp, style: .date).font(.caption).foregroundColor(.secondary)
                        Text("PID \(report.metadata["pid"] ?? "?") · TID \(report.metadata["tid"] ?? "?")").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Section { Text(GuestCrashCenter.storageStatus()).font(.footnote).foregroundColor(.secondary); Text("Keeps the latest 20 failures across restarts. Handled guest signals are not crashes. Nonzero exits are labeled separately. Reports omit arbitrary application output.").font(.footnote).foregroundColor(.secondary) }
        }.navigationTitle("Application Crashes")
            .onAppear { reports = GuestCrashCenter.reports() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LRGuestCrashRecorded"))) { _ in reports = GuestCrashCenter.reports() }
    }
}

struct GuestCrashDetailView: View {
    let report: GuestCrashReport
    var dismissible = false
    @Environment(\.dismiss) private var dismiss
    @State private var share: ExportItem?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text(report.summary).font(.headline).textSelection(.enabled)
                Button("Copy Error") { UIPasteboard.general.string = report.summary }
                Button("Copy Full Report") { UIPasteboard.general.string = report.fullText }
                Button("Share Report") { do { share = ExportItem(url: try GuestCrashCenter.export(report)) } catch { self.error = error.localizedDescription } }
                if let error = error { Text(error).foregroundColor(.red) }
            }
            Section("Full Report") { Text(report.fullText).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.navigationTitle("Crash Details")
            .toolbar { if dismissible { Button("Done") { dismiss() } } }
            .sheet(item: $share) { ShareView(item: $0) }
    }
}

/// Simulator layout runs (LR_SIM_NO_SETUP=1) open the tabs directly instead
/// of the first-run setup sheet. Always false on devices.
var simulatorSuppressesSetup: Bool {
    #if targetEnvironment(simulator)
    return ProcessInfo.processInfo.environment["LR_SIM_NO_SETUP"] == "1"
    #else
    return false
    #endif
}

#if targetEnvironment(simulator)
/// Simulator-only workflow driver for reproducing user sequences without
/// touches: LR_SIM_SCRIPT="wait:5;install-debian;wait:60;terminal;…".
/// Calls the same functions as the buttons; never compiled for devices.
enum SimulatorWorkflow {
    private static var started = false
    private static var installer: DebianInstaller?

    @MainActor private static func packageDiscoveryContract(_ manager: EnvironmentManager) async {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let environment = manager.environments.first(where: { manager.active($0) }) else { return }
        let root = LRRuntimeBridge.activeRootName()
        manager.refresh()
        for _ in 0..<300 {
            if !manager.discovering && !manager.detected.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let context = LRRuntimeBridge.applicationDiscoveryContextContract()
        let sample = fm.temporaryDirectory.appendingPathComponent("lr-package-tail-" + UUID().uuidString)
        let link = sample.appendingPathExtension("link")
        var bounded: [String: Bool] = [:]
        do {
            guard !fm.fileExists(atPath: sample.path), fm.createFile(atPath: sample.path, contents: nil) else { throw EnvironmentError.invalidMetadata }
            defer { try? fm.removeItem(at: sample); try? fm.removeItem(at: link) }
            let handle = try FileHandle(forWritingTo: sample)
            let marker = Data("☃PACKAGE_TAIL_OK\n".utf8), size: UInt64 = 64 * 1024 * 1024
            try handle.truncate(atOffset: size); try handle.seek(toOffset: size - UInt64(marker.count))
            try handle.write(contentsOf: marker); try handle.close()
            bounded["large_log_tail"] = LRRuntimeBridge.boundedDiagnosticTail(sample, maxBytes: 18) == "PACKAGE_TAIL_OK\n"
            bounded["allocation_cap"] = LRRuntimeBridge.boundedDiagnosticTail(sample, maxBytes: UInt.max).utf8.count <= 262144
            try fm.createSymbolicLink(at: link, withDestinationURL: sample)
            bounded["symlink_refused"] = LRRuntimeBridge.boundedDiagnosticTail(link, maxBytes: 18).isEmpty
            bounded["directory_refused"] = LRRuntimeBridge.boundedDiagnosticTail(fm.temporaryDirectory, maxBytes: 18).isEmpty
        } catch { bounded["fixture_error"] = false }
        var scans: [[String: Any]] = []
        var reads: [[String: Any]] = []
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("LRSimulatorApplicationDiscovery"), object: nil, queue: .main) { note in
            if let values = note.userInfo as? [String: Any] { scans.append(values) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let readObserver = NotificationCenter.default.addObserver(forName: Notification.Name("LRSimulatorPackageResultRead"), object: nil, queue: .main) { note in
            if let values = note.userInfo as? [String: Any] { reads.append(values) }
        }
        defer { NotificationCenter.default.removeObserver(readObserver) }
        var gaps: [Double] = []
        var previous = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now - previous) * 1000); previous = now
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let page = PackageView(environment: environment, manager: manager, run: { _ in })
        let host = UIHostingController(rootView: NavigationView { page }.navigationViewStyle(.stack))
        host.overrideUserInterfaceStyle = .dark
        top?.present(host, animated: false)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while (scans.isEmpty || reads.isEmpty) && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let mainScans = scans.filter { $0["mainThread"] as? Bool == true }
        let contextsRestored = context["terminal_context_restored"] as? Bool == true
        let readsOffMain = !reads.isEmpty && reads.allSatisfy { $0["mainThread"] as? Bool == false }
        let pass = mainScans.isEmpty && !scans.isEmpty && !manager.detected.isEmpty && root == LRRuntimeBridge.activeRootName() && contextsRestored && readsOffMain && bounded.count == 4 && bounded.values.allSatisfy({ $0 })
        let value: [String: Any] = ["status": pass ? "PASS" : "FAIL", "context": context, "bounded_log": bounded, "result_reads": reads, "scope": "Actual native Package Manager presentation and guest VFS discovery on Simulator", "root": root, "detected_commands": manager.detected.count, "scans": scans, "main_thread_scans": mainScans.count, "main_runloop_max_gap_ms": gaps.max() ?? 0, "main_runloop_samples": gaps.count, "physical_device": false]
        let path = docs.appendingPathComponent("Diagnostics/package-discovery-contract.json")
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) { try? data.write(to: path, options: .atomic) }
        host.dismiss(animated: false)
    }

    static func start(manager: EnvironmentManager,
                      terminal: @escaping () -> Void = {}, type: @escaping (String) -> Void = { _ in }, tab: @escaping (Int) -> Void = { _ in }) {
        guard !started, let script = ProcessInfo.processInfo.environment["LR_SIM_SCRIPT"] else { return }
        started = true
        var delay = 0.0
        for step in script.split(separator: ";").map(String.init) {
            if step.hasPrefix("wait:") { delay += Double(step.dropFirst(5)) ?? 0; continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                LRRuntimeBridge.logCategory("SIMULATOR", event: "workflow step \(step)")
                if step.hasPrefix("tab:") { tab(Int(step.dropFirst(4)) ?? 0); return }
                if step.hasPrefix("type:") { type(String(step.dropFirst(5)) + "\n"); return }
                switch step {
                case "network-contract":
                    let model = HostNetworkStatus(); model.start()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        var result: [String: Any] = ["environment": "iOS Simulator native public Network/getifaddrs APIs", "status": model.status == "Waiting for system path" || model.addresses.isEmpty ? "FAIL" : "PASS", "path": model.status, "connection": model.connection, "address_count": model.addresses.count, "available_interface_count": model.availableInterfaces.count, "details": model.details, "physical_device": false]
                        let abi = LRRuntimeBridge.networkABIContract(); result["linuxABI"] = abi
                        if abi["status"] as? String != "PASS" { result["status"] = "FAIL" }
                        model.stop()
                        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                           let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
                            let url = documents.appendingPathComponent("Diagnostics/network-contract.json")
                            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? data.write(to: url, options: .atomic)
                        }
                    }
                case "terminal": terminal()
                case "taskmanager":
                    var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
                    while let next = top?.presentedViewController { top = next }
                    top?.present(LinuxRunnerShell.makeTaskManagerController(), animated: true)
                case "jit-status":
                    var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
                    while let next = top?.presentedViewController { top = next }
                    let host = UIHostingController(rootView: NavigationView { ExecutionEngineView() }.navigationViewStyle(.stack))
                    host.overrideUserInterfaceStyle = .dark
                    top?.present(host, animated: true)
                case "package-discovery-contract":
                    Task { @MainActor in await packageDiscoveryContract(manager) }
                case "install-debian":
                    let debian = DebianInstaller(); installer = debian
                    debian.install { environment in
                        manager.acceptInstalled(environment); LRRuntimeBridge.setNextRootName(environment.rootfsName)
                        LRRuntimeBridge.logCategory("SIMULATOR", event: "debian installed root=\(environment.rootfsName)")
                    }
                case "share":
                    if let path = ProcessInfo.processInfo.environment["LR_SIM_SHARE_PATH"] {
                        do { try LRRuntimeBridge.addSharedFolder(URL(fileURLWithPath: path, isDirectory: true)); LRRuntimeBridge.logCategory("SIMULATOR", event: "shared \(path)") }
                        catch { LRRuntimeBridge.logCategory("SIMULATOR", event: "share failed: \(error.localizedDescription)") }
                    }
                case "user":
                    let name = ProcessInfo.processInfo.environment["LR_SIM_USER"] ?? "lrsim"
                    LRRuntimeBridge.createLinuxUser(name, password: "lrsim-password", administrator: false, progress: { _ in }) { error in
                        if let error { LRRuntimeBridge.logCategory("SIMULATOR", event: "user failed: \(error.localizedDescription)"); return }
                        try? LRRuntimeBridge.setDefaultLinuxUser(name); LRRuntimeBridge.logCategory("SIMULATOR", event: "default user \(name)")
                    }
                case "checkshare":
                    for folder in LRRuntimeBridge.sharedFolders() {
                        let name = folder["name"] ?? ""
                        LRRuntimeBridge.checkSharedFolder(name) { summary in
                            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                            let line = "\(folder["mountPoint"] ?? "") available=\(folder["available"] ?? "?")\n\(summary)\n"
                            let file = documents.appendingPathComponent("Diagnostics/share-check-\(name).txt")
                            try? line.write(to: file, atomically: true, encoding: .utf8)
                            LRRuntimeBridge.logCategory("SIMULATOR", event: "share check \(name) done")
                        }
                    }
                default: break
                }
            }
            delay += 0.5
        }
    }
}
#endif

// MARK: - Installation progress (account tools, mode packages)
// LRRuntimeBridge posts LRInstallProgressNotification from the real installer
// state: stage lines, Debian's configured/total packages, apt's own percentages.
// The card shows a percentage only when the installer measured one.
final class InstallMonitor: ObservableObject {
    struct State {
        var title: String, stage: String, detail: String, fraction: Double, elapsed: Double, phase: String, error: String?, log: String?
        var steps: [String] = [], kind: String = ""
    }
    static let shared = InstallMonitor()
    @Published var state: State?
    private var hide: DispatchWorkItem?
    private init() {
        NotificationCenter.default.addObserver(forName: Notification.Name("LRInstallProgressNotification"), object: nil, queue: .main) { [weak self] note in
            guard let self, let info = note.userInfo else { return }
            let state = State(title: info["title"] as? String ?? "Installing", stage: info["stage"] as? String ?? "",
                              detail: info["detail"] as? String ?? "", fraction: (info["fraction"] as? NSNumber)?.doubleValue ?? -1,
                              elapsed: (info["elapsed"] as? NSNumber)?.doubleValue ?? 0, phase: info["phase"] as? String ?? "running",
                              error: info["error"] as? String, log: info["log"] as? String,
                              steps: info["steps"] as? [String] ?? [], kind: info["kind"] as? String ?? "")
            self.hide?.cancel()
            self.state = state
            if state.phase == "succeeded" {
                let work = DispatchWorkItem { [weak self] in if self?.state?.phase == "succeeded" { self?.state = nil } }
                self.hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
    }
    func dismiss() { state = nil }
}

struct InstallProgressCard: View {
    @ObservedObject private var monitor = InstallMonitor.shared
    @State private var expanded = false
    @State private var showLog = false
    @State private var sweep = false
    private func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    private func tint(_ state: InstallMonitor.State) -> Color { state.phase == "failed" ? .orange : state.phase == "succeeded" ? .green : .accentColor }

    @ViewBuilder private func ring(_ state: InstallMonitor.State) -> some View {
        ZStack {
            Circle().stroke(tint(state).opacity(0.18), lineWidth: 4)
            if state.phase == "succeeded" {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.green)
            } else if state.phase == "failed" {
                Image(systemName: "exclamationmark").font(.system(size: 15, weight: .bold)).foregroundColor(.orange)
            } else if state.fraction >= 0 {
                Circle().trim(from: 0, to: max(0.02, state.fraction)).stroke(tint(state), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.4), value: state.fraction)
                Text("\(Int(state.fraction * 100))").font(.system(size: 11, weight: .semibold).monospacedDigit())
            } else {
                Circle().trim(from: 0, to: 0.28).stroke(tint(state), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: sweep)
                    .onAppear { sweep = true }
            }
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder private func bar(_ state: InstallMonitor.State) -> some View {
        let downloading = state.kind == "download", installing = state.kind == "install"
        HStack(spacing: 4) {
            segment(fill: installing ? 1 : downloading ? state.fraction : -1, label: "Download", active: downloading, done: installing)
            segment(fill: installing ? state.fraction : downloading ? 0 : -1, label: "Install", active: installing, done: false)
        }
    }
    @ViewBuilder private func segment(fill: Double, label: String, active: Bool, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if fill >= 0 {
                        Capsule().fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(fill > 0 ? 6 : 0, geo.size.width * fill)).animation(.easeOut(duration: 0.4), value: fill)
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 3) {
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(label)
            }
            .font(.caption2.weight(active ? .semibold : .regular)).foregroundColor(active || done ? .primary : .secondary)
        }
    }

    var body: some View {
        if let state = monitor.state {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ring(state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(state.phase == "succeeded" ? "Installation complete" : state.phase == "failed" ? "Stopped: \(state.stage)"
                             : (state.stage == state.title && !state.detail.isEmpty) ? state.detail : state.stage)
                            .font(.caption).foregroundColor(.secondary).lineLimit(expanded ? 3 : 1)
                    }
                    Spacer(minLength: 4)
                    Text(clock(state.elapsed)).font(.caption.monospacedDigit()).foregroundColor(.secondary).accessibilityLabel("Elapsed \(Int(state.elapsed)) seconds")
                    if state.phase != "succeeded" {
                        Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() } }

                if state.phase == "running" && expanded {
                    if state.fraction >= 0 && !state.kind.isEmpty { bar(state) }
                    if !state.detail.isEmpty {
                        Label(state.detail, systemImage: state.kind == "download" ? "arrow.down.circle" : "shippingbox")
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary).lineLimit(2)
                    }
                    let finished = state.steps.dropLast()
                    if !finished.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(finished.suffix(4).enumerated()), id: \.offset) { _, step in
                                Label(step, systemImage: "checkmark.circle.fill").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                    .labelStyle(TintedIconLabel(tint: .green))
                            }
                        }
                    }
                    Label("Keep DebianRunner open until it finishes", systemImage: "iphone").font(.caption2).foregroundColor(.secondary)
                }
                if let error = state.error {
                    Text(error).font(.footnote).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        if let log = state.log, !log.isEmpty { Button(showLog ? "Hide Details" : "Show Details") { showLog.toggle() } }
                        Button("Dismiss") { monitor.dismiss() }
                    }.font(.footnote.weight(.semibold))
                    if showLog, let log = state.log { ScrollView { Text(log).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(.horizontal, 14).padding(.bottom, 92)
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onChange(of: state.phase) { phase in if phase == "failed" { expanded = true } }
        }
    }
}

private struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.foregroundColor(tint); configuration.title }
    }
}

// MARK: - Task Manager
private enum TaskStyle {
    static let base = Color.black
    static let panel = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    static let line = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255)
    static let text = Color.white
    static let dim = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)
    static let frost = Color(red: 0.36, green: 0.68, blue: 0.98)
    static let blue = Color(red: 0.12, green: 0.30, blue: 0.52)
    static let green = Color(red: 0x30 / 255, green: 0xd1 / 255, blue: 0x58 / 255)
    static let yellow = Color(red: 0xff / 255, green: 0xd6 / 255, blue: 0x0a / 255)
    static let red = Color(red: 0xff / 255, green: 0x45 / 255, blue: 0x3a / 255)
}

private struct GuestProcess: Identifiable {
    let id: Int, ppid: Int, uid: Int, name: String, state: String, threads: Int
    let cpuMs: Int, cpuUs: Int, privateKB: Int, sharedKB: Int, mappedKB: Int
    var cpuPercent: Double = 0
    /// Private mapped memory (anonymous heap/stack + private file/ELF mappings, excluding MAP_SHARED).
    var residentKB: Int { max(mappedKB - sharedKB, privateKB) }
    init(_ d: [String: Any]) {
        id = d["pid"] as? Int ?? 0; ppid = d["ppid"] as? Int ?? 0; uid = d["uid"] as? Int ?? 0
        name = d["name"] as? String ?? "?"; state = d["state"] as? String ?? "?"; threads = d["threads"] as? Int ?? 0
        cpuMs = d["cpu_ms"] as? Int ?? 0
        cpuUs = d["cpu_us"] as? Int ?? (cpuMs * 1000)
        privateKB = d["anonymous_kb"] as? Int ?? 0
        sharedKB = d["shared_kb"] as? Int ?? 0; mappedKB = d["mapped_kb"] as? Int ?? 0
    }
    var stateName: String { ["R": "Running", "S": "Sleeping", "T": "Stopped", "Z": "Zombie"][state] ?? state }
}

@MainActor private final class TaskSampler: ObservableObject {
    @Published var processes: [GuestProcess] = []
    @Published var cpuHistory: [Double] = []
    @Published var appMemoryHistory: [Double] = []
    @Published var guestMemoryHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var netInHistory: [Double] = []   // KB/s
    @Published var netOutHistory: [Double] = []  // KB/s
    @Published var netInBytesPerSec: Double = 0
    @Published var netOutBytesPerSec: Double = 0
    @Published var netInTotalBytes: UInt64 = 0
    @Published var netOutTotalBytes: UInt64 = 0
    @Published var footprint: UInt64 = 0
    @Published var iosAllowanceBytes: UInt64 = 0
    private var previousUs: [Int: Int] = [:]
    private var previousRxBytes: UInt64 = 0
    private var previousTxBytes: UInt64 = 0
    private var previousTime = Date.distantPast
    private var hasBaseline = false
    static let interval = 2.0
    func sample() {
        let now = Date()
        let elapsedUs = hasBaseline ? now.timeIntervalSince(previousTime) * 1_000_000 : 0
        let resetBaseline = !hasBaseline || elapsedUs <= 50_000 || elapsedUs > 10_000_000
        var list = LRRuntimeBridge.taskSnapshot().map(GuestProcess.init)
        if !resetBaseline {
            for i in list.indices {
                let deltaUs: Int
                if let before = previousUs[list[i].id] {
                    deltaUs = max(0, list[i].cpuUs - before)
                } else {
                    deltaUs = max(0, list[i].cpuUs)
                }
                let maxPct = Double(max(1, list[i].threads)) * 100.0
                list[i].cpuPercent = min(maxPct, Double(deltaUs) / elapsedUs * 100.0)
            }
        }
        previousUs = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.cpuUs) })

        let net = LRRuntimeBridge.networkIOBytes()
        let rxNow = net["rx_bytes"]?.uint64Value ?? 0
        let txNow = net["tx_bytes"]?.uint64Value ?? 0
        let elapsedSec = elapsedUs / 1_000_000.0
        if !resetBaseline && elapsedSec > 0 {
            let rxDelta = rxNow >= previousRxBytes ? (rxNow - previousRxBytes) : 0
            let txDelta = txNow >= previousTxBytes ? (txNow - previousTxBytes) : 0
            netInBytesPerSec = Double(rxDelta) / elapsedSec
            netOutBytesPerSec = Double(txDelta) / elapsedSec
        } else {
            netInBytesPerSec = 0
            netOutBytesPerSec = 0
        }
        previousRxBytes = rxNow
        previousTxBytes = txNow
        netInTotalBytes = rxNow
        netOutTotalBytes = txNow

        previousTime = now
        let wasFirst = !hasBaseline
        hasBaseline = true
        processes = list
        footprint = LRRuntimeBridge.appFootprintBytes()
        let available = UInt64(os_proc_available_memory())
        iosAllowanceBytes = available > 0 ? (footprint + available) : 0
        let totalCPU = list.reduce(0) { $0 + $1.cpuPercent }
        let appMB = Double(footprint) / 1_048_576.0
        let guestMappedMB = Double(list.reduce(0) { $0 + $1.residentKB }) / 1024.0
        let guestAnonMB = Double(list.reduce(0) { $0 + $1.privateKB }) / 1024.0
        if !resetBaseline || cpuHistory.isEmpty {
            cpuHistory = Array((cpuHistory + [totalCPU]).suffix(60))
            netInHistory = Array((netInHistory + [netInBytesPerSec / 1024.0]).suffix(60))
            netOutHistory = Array((netOutHistory + [netOutBytesPerSec / 1024.0]).suffix(60))
        }
        appMemoryHistory = Array((appMemoryHistory + [appMB]).suffix(60))
        guestMemoryHistory = Array((guestMemoryHistory + [guestMappedMB]).suffix(60))
        memoryHistory = Array((memoryHistory + [guestAnonMB]).suffix(60))
        if wasFirst {
            // Take a quick follow-up sample so CPU % and Network rates populate immediately instead of waiting 2 seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, UIApplication.shared.applicationState == .active else { return }
                self.sample()
            }
        }
    }
}

private struct DualAreaChart: View {
    let primary: [Double]; let primaryColor: Color
    let secondary: [Double]; let secondaryColor: Color
    var body: some View {
        GeometryReader { geo in
            let maxPrimary = primary.max() ?? 0
            let maxSecondary = secondary.max() ?? 0
            let top = max(max(maxPrimary, maxSecondary), 1)
            let count = max(primary.count, secondary.count)
            let makePoints: ([Double]) -> [CGPoint] = { vals in
                vals.enumerated().map { i, v in
                    CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(count - 1, 1)), y: geo.size.height * (1 - CGFloat(v / top)))
                }
            }
            let p1 = makePoints(primary)
            let p2 = makePoints(secondary)
            ZStack {
                Path { p in for f in [0.25, 0.5, 0.75] { p.move(to: CGPoint(x: 0, y: geo.size.height * f)); p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * f)) } }
                    .stroke(TaskStyle.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                if p1.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: p1[0].x, y: geo.size.height)); p1.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: p1[p1.count - 1].x, y: geo.size.height)); p.closeSubpath()
                    }.fill(LinearGradient(colors: [primaryColor.opacity(0.28), primaryColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: p1[0]); p1.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(primaryColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(primaryColor).frame(width: 6, height: 6).position(p1[p1.count - 1])
                }
                if p2.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: p2[0].x, y: geo.size.height)); p2.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: p2[p2.count - 1].x, y: geo.size.height)); p.closeSubpath()
                    }.fill(LinearGradient(colors: [secondaryColor.opacity(0.24), secondaryColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: p2[0]); p2.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(secondaryColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(secondaryColor).frame(width: 6, height: 6).position(p2[p2.count - 1])
                }
            }
        }
    }
}

private struct AreaChart: View {
    let values: [Double]; let color: Color
    var body: some View {
        GeometryReader { geo in
            let top = max(values.max() ?? 1, 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: geo.size.height * (1 - CGFloat(v / top)) )
            }
            ZStack {
                Path { p in for f in [0.25, 0.5, 0.75] { p.move(to: CGPoint(x: 0, y: geo.size.height * f)); p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * f)) } }
                    .stroke(TaskStyle.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height)); points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height)); p.closeSubpath()
                    }.fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: points[0]); points.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(color).frame(width: 7, height: 7).position(points[points.count - 1])
                }
            }
        }
    }
}

private struct RingGauge: View {
    let fraction: Double; let value: String; let label: String; let colors: [Color]
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(TaskStyle.line, lineWidth: 10)
                Circle().trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                    .stroke(AngularGradient(colors: colors + [colors[0]], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                Text(value).font(.system(.title3, design: .rounded).weight(.bold)).foregroundColor(TaskStyle.text).minimumScaleFactor(0.6).padding(12)
            }
            .frame(width: 104, height: 104)
            Text(label).font(.caption).foregroundColor(TaskStyle.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProcessGlyph: View {
    let name: String
    private var symbol: String? {
        let n = name.lowercased()
        if ["bash", "sh", "zsh", "dash", "fish", "login", "su", "sudo"].contains(n) { return "terminal.fill" }
        if n == "sshd" || n == "ssh" { return "network" }
        if n.hasPrefix("python") || n.hasPrefix("node") || n.hasPrefix("ruby") || n.hasPrefix("perl") || n == "java" { return "chevron.left.forwardslash.chevron.right" }
        if n.contains("dbus") || n.contains("systemd") || n.contains("logind") { return "gearshape.2.fill" }
        if n == "apt" || n == "apt-get" || n == "dpkg" { return "shippingbox.fill" }
        return nil
    }
    private var color: Color {
        let palette: [Color] = [TaskStyle.frost, TaskStyle.green, Color(red: 0.75, green: 0.45, blue: 1), Color(red: 1, green: 0.6, blue: 0.25), Color(red: 1, green: 0.4, blue: 0.55), Color(red: 0.3, green: 0.8, blue: 0.85)]
        return palette[name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % palette.count]
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(0.18))
            .frame(width: 38, height: 38)
            .overlay(Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
                else { Text(String(name.prefix(1)).uppercased()).font(.system(size: 17, weight: .bold, design: .rounded)) }
            }.foregroundColor(color))
    }
}

struct TaskManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sampler = TaskSampler()
    @State private var tab = 0
    @State private var search = ""
    @State private var sort = 0   // 0 CPU, 1 memory, 2 PID, 3 name
    @State private var selected: GuestProcess?
    private let timer = Timer.publish(every: TaskSampler.interval, on: .main, in: .common).autoconnect()
    private let cores = Double(max(Int(ProcessInfo.processInfo.environment["LINUXRUNNER_CPU_CORES"] ?? "") ?? 4, 1))

    private var shown: [GuestProcess] {
        let filtered = search.isEmpty ? sampler.processes : sampler.processes.filter { $0.name.localizedCaseInsensitiveContains(search) || String($0.id) == search }
        switch sort {
        case 1: return filtered.sorted { $0.residentKB > $1.residentKB }
        case 2: return filtered.sorted { $0.id < $1.id }
        case 3: return filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
        default: return filtered.sorted { $0.cpuPercent > $1.cpuPercent }
        }
    }
    private var totalCPU: Double { sampler.cpuHistory.last ?? 0 }
    private var privateKB: Double { Double(sampler.processes.reduce(0) { $0 + $1.privateKB }) }
    private var guestMappedKB: Double { Double(sampler.processes.reduce(0) { $0 + $1.residentKB }) }
    private var appFootprintKB: Double { Double(sampler.footprint) / 1024.0 }
    private var memoryLimitKB: Double {
        if sampler.iosAllowanceBytes > 0 { return Double(sampler.iosAllowanceBytes) / 1024.0 }
        let configured = Double(ProcessInfo.processInfo.environment["LINUXRUNNER_MEMORY_MB"] ?? "") ?? 0
        return (configured > 0 ? configured : 4096) * 1024
    }

    var body: some View {
        NavigationView {
            ZStack {
                TaskStyle.base.ignoresSafeArea()
                VStack(spacing: 12) {
                    tabBar
                    switch tab {
                    case 1: processList
                    case 2: performance
                    default: overview
                    }
                }.padding(.top, 8)
            }
            .navigationTitle("Task Manager").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear { sampler.sample() }
        .onReceive(timer) { _ in if UIApplication.shared.applicationState == .active { sampler.sample() } }
        .sheet(item: $selected) { ProcessDetailView(process: $0, sampler: sampler) }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Overview", "Processes", "Performance"].enumerated()), id: \.offset) { index, title in
                Button { withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: {
                    Text(title).font(.subheadline.weight(.semibold))
                        .foregroundColor(tab == index ? .white : TaskStyle.dim)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Capsule().fill(tab == index ? TaskStyle.frost.opacity(0.35) : Color.clear))
                }.buttonStyle(.plain)
            }
        }
        .padding(4).background(Capsule().fill(TaskStyle.panel)).padding(.horizontal)
    }

    private func card<Content: View>(_ title: String, systemImage: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.bold)).foregroundColor(TaskStyle.frost) }
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundColor(TaskStyle.dim)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TaskStyle.panel))
    }
    private func tile(_ value: String, _ label: String, _ systemImage: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)).foregroundColor(color)
                .frame(width: 30, height: 30).background(Circle().fill(color.opacity(0.16)))
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).foregroundColor(TaskStyle.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundColor(TaskStyle.dim).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(TaskStyle.panel))
    }
    private static func bytes(_ kb: Double) -> String {
        if kb >= 1024 * 1024 { return String(format: "%.2f GB", kb / 1048576) }
        if kb >= 1024 * 100 { return String(format: "%.0f MB", kb / 1024) }
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        return String(format: "%.0f KB", kb)
    }
    private static func byteCount(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
        return "\(bytes) B"
    }
    private static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 { return String(format: "%.2f MB/s", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 * 100 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        if bytesPerSec >= 1024 { return String(format: "%.1f KB/s", bytesPerSec / 1024) }
        return String(format: "%.0f B/s", max(0, bytesPerSec))
    }

    private var overview: some View {
        let execution = LRRuntimeBridge.executionBackendStatus()
        let jit = (execution["active"] as? String) == "jit"
        let rootName = LRRuntimeBridge.activeRootName()
        let ringMemKB = sampler.footprint > 0 ? appFootprintKB : guestMappedKB
        return ScrollView { VStack(spacing: 12) {
            card("Debian minimal right now", systemImage: "waveform.path.ecg") {
                HStack {
                    RingGauge(fraction: totalCPU / (cores * 100), value: String(format: totalCPU < 10 && totalCPU > 0 ? "%.1f%%" : "%.0f%%", totalCPU), label: String(format: "CPU · %.0f cores = %.0f%%", cores, cores * 100), colors: [TaskStyle.frost, Color(red: 0.55, green: 0.45, blue: 1)])
                    RingGauge(fraction: ringMemKB / max(memoryLimitKB, 1), value: Self.bytes(ringMemKB), label: "App RAM · of \(Self.bytes(memoryLimitKB))", colors: [TaskStyle.green, Color(red: 0.3, green: 0.8, blue: 0.85)])
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                tile("\(sampler.processes.count)", "Processes", "square.stack.3d.up.fill", TaskStyle.frost)
                tile("\(sampler.processes.reduce(0) { $0 + $1.threads })", "Threads", "point.3.connected.trianglepath.dotted", Color(red: 0.75, green: 0.45, blue: 1))
                tile(Self.bytes(guestMappedKB), "Linux mapped", "memorychip", TaskStyle.yellow)
                tile(jit ? "JIT" : "Interpreter", "Execution", jit ? "bolt.fill" : "cpu", jit ? TaskStyle.green : TaskStyle.frost)
            }
            card("Network I/O", systemImage: "arrow.up.arrow.down") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("In", systemImage: "arrow.down.circle.fill").font(.caption.weight(.semibold)).foregroundColor(TaskStyle.frost)
                        Text(Self.rate(sampler.netInBytesPerSec)).font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit()).foregroundColor(TaskStyle.text).lineLimit(1).minimumScaleFactor(0.7)
                        Text("Total \(Self.byteCount(sampler.netInTotalBytes))").font(.caption).foregroundColor(TaskStyle.dim).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Out", systemImage: "arrow.up.circle.fill").font(.caption.weight(.semibold)).foregroundColor(TaskStyle.yellow)
                        Text(Self.rate(sampler.netOutBytesPerSec)).font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit()).foregroundColor(TaskStyle.text).lineLimit(1).minimumScaleFactor(0.7)
                        Text("Total \(Self.byteCount(sampler.netOutTotalBytes))").font(.caption).foregroundColor(TaskStyle.dim).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            card("Top processes", systemImage: "flame.fill") {
                ForEach(sampler.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(4)) { p in
                    Button { selected = p } label: { processRow(p, compact: true) }.buttonStyle(.plain)
                }
                if sampler.processes.isEmpty { Text("Debian minimal is not running.").font(.callout).foregroundColor(TaskStyle.dim) }
            }
            card("DebianRunner", systemImage: "cpu") {
                row("Distribution", "Debian GNU/Linux (minimal)")
                row("Environment", rootName.isEmpty ? "None" : rootName)
                row("Execution", (LRRuntimeBridge.jitStatusReport() as? [String: Any])?["state"] as? String ?? (jit ? "JIT" : "Interpreter"))
            }
        }.padding(.horizontal).padding(.bottom, 16) }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundColor(TaskStyle.dim); Spacer(); Text(value).foregroundColor(TaskStyle.text).lineLimit(1) }.font(.callout)
    }

    private func processRow(_ p: GuestProcess, compact: Bool = false) -> some View {
        HStack(spacing: 12) {
            ProcessGlyph(name: p.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).foregroundColor(TaskStyle.text).font(.body.weight(.medium)).lineLimit(1)
                if !compact { Text("PID \(p.id) · \(p.stateName) · \(p.threads) thread\(p.threads == 1 ? "" : "s")").font(.caption).foregroundColor(TaskStyle.dim) }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TaskStyle.line)
                        Capsule().fill(p.cpuPercent > 50 ? TaskStyle.yellow : TaskStyle.frost)
                            .frame(width: geo.size.width * CGFloat(min(p.cpuPercent / 100, 1)))
                    }
                }.frame(height: 4)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1f%%", p.cpuPercent)).foregroundColor(p.cpuPercent > 50 ? TaskStyle.yellow : TaskStyle.frost).font(.callout.monospacedDigit().weight(.semibold))
                Text(Self.bytes(Double(p.residentKB))).font(.caption.monospacedDigit()).foregroundColor(TaskStyle.dim)
            }
        }
        .padding(.vertical, compact ? 2 : 4)
        .contentShape(Rectangle())
    }

    private var processList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(TaskStyle.dim)
                TextField("Search name or PID", text: $search).foregroundColor(TaskStyle.text).autocapitalization(.none).disableAutocorrection(true)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(TaskStyle.dim) } }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TaskStyle.panel)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(["CPU", "Memory", "PID", "Name"].enumerated()), id: \.offset) { index, title in
                        Button { sort = index } label: {
                            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundColor(sort == index ? .black : TaskStyle.text)
                                .background(Capsule().fill(sort == index ? TaskStyle.frost : TaskStyle.panel))
                        }.buttonStyle(.plain)
                    }
                    Text("\(shown.count) of \(sampler.processes.count)").font(.caption).foregroundColor(TaskStyle.dim).padding(.leading, 4)
                }.padding(.horizontal)
            }
            List(shown) { p in
                Button { selected = p } label: { processRow(p) }
                    .listRowBackground(TaskStyle.panel)
            }
            .listStyle(.insetGrouped)
        }
    }

    private var performance: some View {
        let useFootprint = sampler.footprint > 0
        let activeMemHistory = useFootprint ? sampler.appMemoryHistory : sampler.guestMemoryHistory
        let currentMemMB = activeMemHistory.last ?? 0
        let peakMemMB = activeMemHistory.max() ?? 0
        return ScrollView { VStack(spacing: 12) {
            card("CPU · last 2 minutes", systemImage: "cpu") {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: totalCPU < 10 && totalCPU > 0 ? "%.1f%%" : "%.0f%%", totalCPU)).font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundColor(TaskStyle.frost)
                    Spacer()
                    Text(String(format: "peak %.1f%%", sampler.cpuHistory.max() ?? 0)).font(.caption).foregroundColor(TaskStyle.dim)
                }
                AreaChart(values: sampler.cpuHistory, color: TaskStyle.frost).frame(height: 120)
                Text(String(format: "100%% = one core · %.0f guest cores (live thread CPU deltas)", cores)).font(.caption).foregroundColor(TaskStyle.dim)
            }
            card("Memory · last 2 minutes", systemImage: "memorychip") {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.bytes(currentMemMB * 1024)).font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundColor(TaskStyle.green)
                    Spacer()
                    Text("peak \(Self.bytes(peakMemMB * 1024))").font(.caption).foregroundColor(TaskStyle.dim)
                }
                AreaChart(values: activeMemHistory, color: TaskStyle.green).frame(height: 120)
                Text("iOS app footprint: \(sampler.footprint > 0 ? Self.bytes(appFootprintKB) : "—") · Linux mapped: \(Self.bytes(guestMappedKB)) · Anonymous heap/stack: \(Self.bytes(privateKB))")
                    .font(.caption).foregroundColor(TaskStyle.dim)
            }
            card("Network · last 2 minutes", systemImage: "arrow.up.arrow.down") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("In", systemImage: "arrow.down.circle.fill").font(.caption.weight(.semibold)).foregroundColor(TaskStyle.frost)
                        Text(Self.rate(sampler.netInBytesPerSec)).font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit()).foregroundColor(TaskStyle.frost).lineLimit(1).minimumScaleFactor(0.7)
                        Text("peak \(Self.rate((sampler.netInHistory.max() ?? 0) * 1024))").font(.caption2).foregroundColor(TaskStyle.dim).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Out", systemImage: "arrow.up.circle.fill").font(.caption.weight(.semibold)).foregroundColor(TaskStyle.yellow)
                        Text(Self.rate(sampler.netOutBytesPerSec)).font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit()).foregroundColor(TaskStyle.yellow).lineLimit(1).minimumScaleFactor(0.7)
                        Text("peak \(Self.rate((sampler.netOutHistory.max() ?? 0) * 1024))").font(.caption2).foregroundColor(TaskStyle.dim).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DualAreaChart(primary: sampler.netInHistory, primaryColor: TaskStyle.frost, secondary: sampler.netOutHistory, secondaryColor: TaskStyle.yellow).frame(height: 120)
                Text("Session total: In \(Self.byteCount(sampler.netInTotalBytes)) · Out \(Self.byteCount(sampler.netOutTotalBytes)) (Linux IPv4/IPv6 sockets)")
                    .font(.caption).foregroundColor(TaskStyle.dim).monospacedDigit()
            }
            card("Notes", systemImage: "info.circle") {
                Text("CPU tracks host Mach thread execution deltas across all guest threads. Memory plots iOS physical footprint (phys_footprint) alongside Linux mapped pages and private anonymous heap/stack. Network tracks live IPv4/IPv6 socket bytes sent and received by Linux processes.").font(.caption).foregroundColor(TaskStyle.dim)
            }
        }.padding(.horizontal).padding(.bottom, 16) }
    }
}

private struct DetailRow: View {   // LabeledContent needs iOS 16
    let label: String, value: String
    init(_ label: String, value: String) { self.label = label; self.value = value }
    var body: some View { HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) } }
}

private struct ProcessDetailView: View {
    let process: GuestProcess
    @ObservedObject var sampler: TaskSampler
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: Bool?   // false: terminate, true: force
    @State private var result: String?
    private static func formatKB(_ kb: Int) -> String {
        let d = Double(kb)
        if d >= 1024 * 1024 { return String(format: "%.2f GB", d / 1048576) }
        if d >= 1024 { return String(format: "%.1f MB", d / 1024) }
        return "\(kb) KB"
    }
    var body: some View {
        NavigationView {
            List {
                Section("Process") {
                    DetailRow("Name", value: process.name); DetailRow("PID", value: "\(process.id)")
                    DetailRow("Parent PID", value: "\(process.ppid)"); DetailRow("User ID", value: "\(process.uid)")
                    DetailRow("State", value: process.stateName); DetailRow("Threads", value: "\(process.threads)")
                }
                Section("Resources") {
                    DetailRow("CPU now", value: String(format: "%.1f%% of a core", process.cpuPercent))
                    DetailRow("CPU time", value: String(format: "%.2f s", Double(process.cpuUs) / 1_000_000))
                    DetailRow("Private mapped (incl. libs)", value: Self.formatKB(process.residentKB))
                    DetailRow("Anonymous heap/stack", value: Self.formatKB(process.privateKB))
                    DetailRow("Shared mappings", value: Self.formatKB(process.sharedKB))
                    DetailRow("Total mapped address space", value: Self.formatKB(process.mappedKB))
                }
                Section {
                    Button("End Process (SIGTERM)") { confirm = false }.disabled(process.id <= 1)
                    Button("Force Kill (SIGKILL)", role: .destructive) { confirm = true }.disabled(process.id <= 1)
                    if let result { Text(result).font(.caption).foregroundColor(.secondary) }
                } footer: { Text(process.id <= 1 ? "PID 1 runs the Debian minimal session and cannot be ended here." : "SIGTERM asks the process to quit cleanly; SIGKILL stops it immediately.") }
            }
            .navigationTitle(process.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(confirm == true ? "Force kill \(process.name)?" : "End \(process.name)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                Button(confirm == true ? "Force Kill" : "End Process", role: .destructive) {
                    let force = confirm == true
                    result = LRRuntimeBridge.terminateProcess(Int32(process.id), force: force) ? (force ? "SIGKILL sent." : "SIGTERM sent.") : "The process has already exited."
                    sampler.sample()
                }
            } message: { Text(confirm == true ? "The process stops immediately without saving." : "The process is asked to quit and may save its state.") }
        }
    }
}
