import SwiftUI

// Guided setup: Welcome → Install Debian Minimal → (boot or restart into it) →
// Account (optional) → Ready → Open Terminal. Uses the authenticated Debian 13
// minimal package installer and native account setup (password hashed in the
// app; tools installed if absent). Opens automatically only when no Debian
// environment exists or when a restart into a newly installed environment is
// pending.
enum SetupStep: String { case welcome, install, relaunch, account, done }

struct SetupWizardView: View {
    @ObservedObject var manager: EnvironmentManager
    var openTerminal: () -> Void
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
    private var step: SetupStep { SetupStep(rawValue: stepRaw) ?? .welcome }

    var body: some View {
        NavigationView {
            Form { content }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(step == .done ? "Close" : "Later") { dismiss() }
                            .disabled(working != nil || debian.running || manager.busy)
                    }
                }
        }
        .navigationViewStyle(.stack)
        .overlay(alignment: .bottom) { InstallProgressCard() }
        .interactiveDismissDisabled(working != nil || debian.running || manager.busy)
        .onAppear(perform: resume)
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
            Section {
                Label("Debian minimal is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Install command-line packages any time from Packages, connect remotely using the built-in SSH Server, or browse Debian files directly from the Apple Files app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    stepRaw = SetupStep.welcome.rawValue
                    setupRoot = ""
                    dismiss()
                    openTerminal()
                } label: {
                    Label("Open Terminal", systemImage: "terminal.fill").font(.headline)
                }
                .disabled(!LRRuntimeBridge.isRunning())
            }
        }
        if let working { Section { HStack(spacing: 12) { ProgressView(); Text(working) } } }
        if let problem { Section { Text(problem).foregroundStyle(.red) } }
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
                    .disabled(working != nil || free < max(Int64(1 << 30), download + installed))
            }
            if let failure = debian.failure {
                Text(failure).foregroundStyle(.red)
                Button("Try Again") { startInstall() }
            }
        } footer: {
            Text("Downloads official Debian minimal packages verified against Debian's signed InRelease and SHA-256 package index. No desktop or GUI packages are installed.")
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
        guard !debian.running, !manager.busy, working == nil else { return }
        problem = nil
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

    private func bootInstalledRoot(_ root: String) {
        working = "Starting Debian minimal…"
        DispatchQueue.main.async {
            let result = LRRuntimeBridge.startRuntime()
            working = nil
            manager.refresh()
            if LRRuntimeBridge.isRunning() && LRRuntimeBridge.activeRootName() == root {
                stepRaw = SetupStep.account.rawValue
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
