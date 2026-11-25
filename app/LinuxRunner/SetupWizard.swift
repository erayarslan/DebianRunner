import SwiftUI

// Guided setup: Welcome → Install Debian Minimal → (boot or restart into it) →
// Account (optional) → Ready. Uses the authenticated Debian 13
// minimal package installer and native account setup (password hashed in the
// app; tools installed if absent). Opens automatically only when no Debian
// environment exists or when a restart into a newly installed environment is
// pending.
enum SetupStep: String { case welcome, install, relaunch, account, done }

struct SetupWizardView: View {
    @ObservedObject var manager: EnvironmentManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("LinuxRunnerSetup.step") private var stepRaw = SetupStep.welcome.rawValue
    @AppStorage("LinuxRunnerSetup.root") private var setupRoot = ""
    @StateObject private var debian = DebianInstaller()
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var administrator = true
    @State private var passwordlessSudo = true
    @State private var working: String?
    @State private var problem: String?
    @State private var snapshots: [EnvironmentSnapshot] = []
    @State private var pendingRestore: EnvironmentSnapshot?
    @State private var restoringSnapshot: EnvironmentSnapshot?
    @State private var restoreProgress: Double = 0
    @State private var restoreMessage = ""
    @State private var restoreCancel = SnapshotCancellation()
    @State private var restoredFromSnapshotName: String?
    private var step: SetupStep { SetupStep(rawValue: stepRaw) ?? .welcome }
    private var isBusy: Bool { working != nil || debian.running || manager.busy || restoringSnapshot != nil }

    var body: some View {
        NavigationView {
            Form { content }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(step == .done ? "Close" : "Later") { dismiss() }
                            .disabled(isBusy)
                    }
                }
        }
        .navigationViewStyle(.stack)
        .overlay(alignment: .bottom) { InstallProgressCard() }
        .interactiveDismissDisabled(isBusy)
        .onAppear(perform: resume)
        .confirmationDialog(
            "Restore Snapshot?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            if let snap = pendingRestore {
                Button("Restore \"\(snap.name)\"") {
                    pendingRestore = nil
                    startSnapshotRestore(snap)
                }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            if let snap = pendingRestore {
                Text("Restore Debian Minimal from \"\(snap.name)\" (\(snap.formattedSize), saved \(snap.formattedDate))? Your packages, files, SSH keys, and Linux accounts from that snapshot will be ready immediately.")
            }
        }
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome"
        case .install: return "Install Debian Minimal"
        case .relaunch: return "Restart DebianRunner"
        case .account: return "Your Account"
        case .done: return "Ready"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            Section {
                Text("DebianRunner runs Debian GNU/Linux 13 (trixie) minimal ARM64 on this iPhone with its own userspace runtime — no virtual machine.")
                Text("Setup downloads and verifies official Debian minimal packages, installs OpenSSH server by default, and optionally creates your Linux account. Everything can be changed later in Debian or Settings.")
                    .foregroundStyle(.secondary)
            }
            if let existing = manager.environments.first {
                Section("Debian Minimal") {
                    Button("Configure " + existing.name) { configureExisting(existing) }
                    Text("Uses your existing Debian Minimal installation, accounts, and files. To start fresh, wipe Debian Minimal from the Debian tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if !snapshots.isEmpty {
                snapshotRestoreSection(title: "Restore from Snapshot")
                Section("Or Start Fresh") {
                    Button {
                        stepRaw = SetupStep.install.rawValue
                    } label: {
                        Label("Install Fresh Debian Minimal", systemImage: "arrow.down.circle")
                    }
                    .disabled(isBusy)
                }
            } else {
                Section {
                    Button("Continue") {
                        stepRaw = SetupStep.install.rawValue
                    }
                }
            }
        case .install: install
        case .relaunch:
            Section {
                Text("Debian minimal is installed. Close DebianRunner completely (swipe it away in the app switcher) and open it again — setup continues with your account.")
            }
            Section {
                Text("iOS allows one Linux runtime per app launch, so this restart is needed once after installing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .account: account
        case .done:
            let loginUser = LRRuntimeBridge.defaultLinuxUser().isEmpty ? "root" : LRRuntimeBridge.defaultLinuxUser()
            Section {
                if let restored = restoredFromSnapshotName {
                    Label("Restored from \"\(restored)\"", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Your Debian Minimal snapshot is booted and ready with its saved packages, files, and Linux accounts.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Label("Debian minimal is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connect over SSH from Termius or any SSH client (127.0.0.1:2222 as \(loginUser)), install packages from Packages, or browse Debian files in Apple Files.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    stepRaw = SetupStep.welcome.rawValue
                    setupRoot = ""
                    restoredFromSnapshotName = nil
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill").font(.headline)
                }
            } footer: {
                Text("Open SSH Server on Home to view local (127.0.0.1:2222) and Wi-Fi LAN SSH details or enable background keep-alive while using another SSH client.")
            }
        }
        if let working { Section { HStack(spacing: 12) { ProgressView(); Text(working) } } }
        if let problem { Section { Text(problem).foregroundStyle(.red) } }
    }

    @ViewBuilder private func snapshotRestoreSection(title: String) -> some View {
        Section {
            if let active = restoringSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restoring \"\(active.name)\"").font(.headline)
                    Text(restoreMessage.isEmpty ? "Verifying and importing snapshot…" : restoreMessage)
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: restoreProgress)
                    Button("Cancel Restore", role: .destructive) {
                        restoreCancel.cancel()
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(snapshots) { snap in
                    Button {
                        pendingRestore = snap
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snap.name).font(.headline).foregroundColor(.primary)
                                Text("\(snap.formattedDate) · \(snap.formattedSize) · \(snap.defaultUser)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("Restore")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(isBusy)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text("Saved snapshots are kept across wipes and verified by SHA-256 checksum before restoring.")
        }
    }

    @ViewBuilder private var install: some View {
        let free = (try? LRRuntimeBridge.managedStorageURL().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let manifest = try? DebianManifest.load()
        let download = manifest?.downloadBytes ?? 0
        let installed = manifest?.installedBytes ?? 0
        Section("Debian 13 (trixie) Minimal · ARM64") {
            row("Download", ByteCountFormatter.string(fromByteCount: download, countStyle: .file))
            row("Installed size", ByteCountFormatter.string(fromByteCount: installed, countStyle: .file))
            row("Available", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        }
        Section {
            if debian.running {
                Text(debian.message)
                ProgressView(value: debian.fraction)
                Button("Cancel", role: .destructive) { debian.cancel() }
            } else {
                Button("Install Debian Minimal") { startInstall() }
                    .disabled(isBusy || free < max(Int64(1 << 30), download + installed))
            }
            if let failure = debian.failure {
                Text(failure).foregroundStyle(.red)
                Button("Try Again") { startInstall() }
            }
        } footer: {
            Text("Downloads official Debian minimal packages verified against Debian's signed InRelease and SHA-256 package index. No desktop or GUI packages are installed.")
        }
        if manager.environments.isEmpty && !snapshots.isEmpty && !debian.running {
            snapshotRestoreSection(title: "Or Restore from Snapshot")
        }
    }

    @ViewBuilder private var account: some View {
        if !LRRuntimeBridge.isRunning() || (!setupRoot.isEmpty && LRRuntimeBridge.activeRootName() != setupRoot) {
            Section { Text("Close DebianRunner completely and open it again to continue.") }
        } else {
            let existing = LRRuntimeBridge.linuxAccounts().filter { $0["name"] != "root" && ($0["uid"].flatMap(Int.init) ?? 0) >= 1000 }
            if !existing.isEmpty {
                Section("Use an existing account") {
                    ForEach(existing, id: \.self) { account in
                        Button(account["name"] ?? "") { useAccount(account["name"] ?? "") }.disabled(working != nil)
                    }
                }
            }
            Section(existing.isEmpty ? "Create your account" : "Or create a new account") {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                SecureField("Password", text: $password).textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                Toggle("Administrator (can use sudo)", isOn: $administrator)
                if administrator {
                    Toggle("Passwordless sudo (NOPASSWD)", isOn: $passwordlessSudo)
                }
                Button("Create Account") { createAccount() }
                    .disabled(working != nil || username.isEmpty || password.isEmpty || password != confirmation)
                if !confirmation.isEmpty && password != confirmation {
                    Text("The passwords do not match.").font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                Button("Continue as root (Skip)") {
                    problem = nil
                    stepRaw = SetupStep.done.rawValue
                }.disabled(working != nil)
            } footer: {
                Text("Lowercase letters, digits, - and _. DebianRunner stores only Linux's own password hash, never the password. You can add users later in Settings › Linux Users.")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func resume() {
        snapshots = EnvironmentSnapshot.loadAll()
        if step == .relaunch, LRRuntimeBridge.isRunning(), LRRuntimeBridge.activeRootName() == setupRoot {
            stepRaw = SetupStep.account.rawValue
        }
    }

    private func configureExisting(_ environment: LinuxEnvironment) {
        problem = nil
        setupRoot = environment.rootfsName
        LRRuntimeBridge.setNextRootName(environment.rootfsName)
        if manager.active(environment) {
            stepRaw = SetupStep.account.rawValue
        } else if !LRRuntimeBridge.isRunning() && LRRuntimeBridge.canStartRuntime() {
            bootInstalledRoot(environment.rootfsName)
        } else {
            stepRaw = SetupStep.relaunch.rawValue
        }
    }

    private func startInstall() {
        guard !isBusy else { return }
        problem = nil
        restoredFromSnapshotName = nil
        debian.install { environment in
            manager.acceptInstalled(environment)
            setupRoot = environment.rootfsName
            LRRuntimeBridge.setNextRootName(environment.rootfsName)
            if LRRuntimeBridge.isRunning() && LRRuntimeBridge.activeRootName() == environment.rootfsName {
                stepRaw = SetupStep.account.rawValue
            } else if !LRRuntimeBridge.isRunning() && LRRuntimeBridge.canStartRuntime() {
                bootInstalledRoot(environment.rootfsName)
            } else {
                stepRaw = SetupStep.relaunch.rawValue
            }
        }
    }

    private func startSnapshotRestore(_ snap: EnvironmentSnapshot) {
        guard !isBusy else { return }
        problem = nil
        restoringSnapshot = snap
        restoreProgress = 0
        restoreMessage = "Verifying and importing snapshot…"
        let token = SnapshotCancellation()
        restoreCancel = token
        LRRuntimeBridge.restoreSnapshot(id: snap.id, progress: { fraction, message in
            restoreProgress = fraction
            restoreMessage = message
        }, cancel: {
            token.isCancelled()
        }, completion: { rootName, err in
            restoringSnapshot = nil
            restoreProgress = 0
            restoreMessage = ""
            if let err {
                if (err as NSError).code == CocoaError.userCancelled.rawValue {
                    problem = "Snapshot restore cancelled."
                } else {
                    problem = err.localizedDescription
                }
                return
            }
            guard let rootName else {
                problem = "Snapshot restore returned no environment."
                return
            }
            var environment = LinuxEnvironment(name: "Debian Minimal", rootfsName: rootName)
            environment.distribution = snap.distribution
            environment.distributionID = "debian"
            environment.packageManager = "apt"
            environment.rootfsVersion = snap.version
            environment.defaultShell = "/bin/bash"
            environment.installationState = "Restored from snapshot \"\(snap.name)\""
            manager.acceptInstalled(environment)
            setupRoot = rootName
            restoredFromSnapshotName = snap.name
            LRRuntimeBridge.setNextRootName(rootName)
            if LRRuntimeBridge.isRunning() && LRRuntimeBridge.activeRootName() == rootName {
                stepRaw = SetupStep.done.rawValue
            } else if !LRRuntimeBridge.isRunning() && LRRuntimeBridge.canStartRuntime() {
                bootInstalledRoot(rootName, skipAccount: true)
            } else {
                stepRaw = SetupStep.relaunch.rawValue
            }
        })
    }

    private func bootInstalledRoot(_ root: String, skipAccount: Bool = false) {
        working = "Starting Debian minimal…"
        DispatchQueue.main.async {
            let result = LRRuntimeBridge.startRuntime()
            working = nil
            manager.refresh()
            if LRRuntimeBridge.isRunning() && LRRuntimeBridge.activeRootName() == root {
                stepRaw = skipAccount ? SetupStep.done.rawValue : SetupStep.account.rawValue
            } else {
                if result != 0 {
                    problem = "Debian minimal was installed, but starting the runtime failed (\(result)). " + LRRuntimeBridge.runtimeStatus()
                }
                stepRaw = SetupStep.relaunch.rawValue
            }
        }
    }

    private func createAccount() {
        problem = nil
        working = "Preparing"
        LRRuntimeBridge.createLinuxUser(username, password: password, administrator: administrator, passwordlessSudo: administrator && passwordlessSudo, progress: { working = $0 }) { error in
            working = nil
            if let error { problem = error.localizedDescription; return }
            password = ""; confirmation = ""
            useAccount(username)
        }
    }

    private func useAccount(_ name: String) {
        do {
            try LRRuntimeBridge.setDefaultLinuxUser(name)
            problem = nil
            stepRaw = SetupStep.done.rawValue
        } catch {
            problem = error.localizedDescription
        }
    }
}
