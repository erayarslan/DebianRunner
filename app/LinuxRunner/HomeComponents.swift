import SwiftUI
import os

/// Compact Linux runtime status pill for the Home header.
struct HomeStatus: View {
    enum Phase: Equatable { case uninstalled, stopped, starting, running }
    let phase: Phase
    var open: (() -> Void)?
    private var color: Color {
        switch phase {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .gray
        case .uninstalled: return .secondary
        }
    }
    private var title: String {
        switch phase {
        case .running: return "Running"
        case .starting: return "Starting"
        case .stopped: return "Stopped"
        case .uninstalled: return "Setup"
        }
    }
    private var symbol: String {
        switch phase {
        case .running: return "arrow.up.forward.app.fill"
        case .starting: return "power"
        case .stopped: return "power"
        case .uninstalled: return "arrow.down.circle"
        }
    }
    var body: some View {
        Button { open?() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.18)).frame(width: 28, height: 28)
                    if phase == .starting { ProgressView().scaleEffect(0.6).tint(color) }
                    else { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(color) }
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                Circle().fill(color).frame(width: 7, height: 7)
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .accessibilityLabel("Debian status: \(title)")
        .animation(.easeInOut(duration: 0.25), value: phase)
    }
}

/// Rounded-square tile with a label underneath (or wide card when large).
struct HomeTile: View {
    let title: String
    let symbol: String
    let colors: [Color]
    var large = false
    var badge = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        if !large && sizeClass == .regular {
            // iPad: the four small tiles become wide cards that fill the row
            // instead of small icons separated by large gaps.
            HStack(spacing: 12) {
                icon(size: 44)
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        } else if large {
            HStack(spacing: 12) {
                icon(size: 46)
                Text(title).font(.headline).foregroundColor(.primary).lineLimit(title.count > 10 ? 2 : 1).minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        } else {
            VStack(spacing: 7) {
                icon(size: 60)
                Text(title).font(.caption.weight(.medium)).foregroundColor(.primary).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity)
        }
    }
    private func icon(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundColor(.white))
            .overlay(alignment: .topTrailing) {
                if badge { Circle().fill(Color.green).frame(width: 12, height: 12).overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2)).offset(x: 3, y: -3) }
            }
            .shadow(color: colors.last?.opacity(0.25) ?? .clear, radius: 6, y: 3)
    }
}

struct HomeTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Running and recent long tasks with their real state and elapsed time.
struct HomeTasks: View {
    @ObservedObject var center: LongTaskCenter
    var body: some View {
        if !center.entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tasks").font(.headline)
                    Spacer()
                    if center.hasClearableEntries {
                        Button("Clear") {
                            withAnimation(.easeOut(duration: 0.2)) { center.clearFinished() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("Clear Tasks")
                    }
                }
                ForEach(center.entries.prefix(6)) { entry in
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color(entry).opacity(0.18)).frame(width: 34, height: 34)
                                if entry.ended == nil && entry.state != .pausedByIOS { ProgressView().scaleEffect(0.7).tint(color(entry)) }
                                else { Image(systemName: symbol(entry)).foregroundColor(color(entry)).font(.system(size: 15, weight: .semibold)) }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(entry.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                                if let fraction = entry.fraction, entry.ended == nil { ProgressView(value: fraction).tint(color(entry)) }
                            }
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.state.rawValue).font(.caption2.weight(.semibold)).foregroundColor(color(entry))
                                Text(elapsed(entry, now: context.date)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                            }
                            if entry.ended != nil || entry.state == .pausedByIOS {
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) { center.removeEntry(entry.id) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(entry.title)")
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }
                }
            }
        }
    }
    private func color(_ e: LongTaskCenter.Entry) -> Color {
        switch e.state { case .completed: return .green; case .failed: return .red; case .pausedByIOS: return .orange; case .backgroundGranted: return .indigo; case .running: return .blue }
    }
    private func symbol(_ e: LongTaskCenter.Entry) -> String {
        switch e.state { case .completed: return "checkmark"; case .failed: return "xmark"; case .pausedByIOS: return "pause.fill"; default: return "hourglass" }
    }
    private func elapsed(_ e: LongTaskCenter.Entry, now: Date) -> String {
        let seconds = Int((e.ended ?? now).timeIntervalSince(e.started))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Debian Environment Cards

/// Debian logo from DistroLogos.bundle on a light tile.
struct DistroBadge: View {
    var distributionID: String? = "debian"
    var size: CGFloat = 46
    private static var cachedLogo: UIImage?
    private var logo: UIImage? {
        if let image = Self.cachedLogo { return image }
        guard let bundle = Bundle.main.url(forResource: "DistroLogos", withExtension: "bundle"),
              let image = UIImage(contentsOfFile: bundle.appendingPathComponent("debian.png").path) else { return nil }
        Self.cachedLogo = image
        return image
    }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(white: 0.96))
            .frame(width: size, height: size)
            .overlay {
                if let logo { Image(uiImage: logo).resizable().interpolation(.high).scaledToFit().padding(size * 0.14) }
                else { Image(systemName: "terminal.fill").foregroundColor(.gray) }
            }
            .accessibilityHidden(true)
    }
}

struct StatusChip: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct InstalledDistributionCard: View {
    let name: String, version: String, size: String
    let active: Bool, nextLaunch: Bool
    var body: some View {
        HStack(spacing: 14) {
            DistroBadge()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.headline).foregroundColor(.primary).lineLimit(1)
                    if active { StatusChip(text: "Active", color: .green) }
                    else if nextLaunch { StatusChip(text: "Next launch", color: .accentColor) }
                }
                Text([version, size].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Label("Debian minimal · ARM64", systemImage: "terminal").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary.opacity(0.6))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(active ? Color.green.opacity(0.55) : Color.clear, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }
}

/// Settings row label: an iOS-style coloured icon tile and a title.
struct SettingsLabel: View {
    let title: String, symbol: String, color: Color
    init(_ title: String, _ symbol: String, _ color: Color) { self.title = title; self.symbol = symbol; self.color = color }
    var body: some View {
        Label {
            Text(title)
        } icon: {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color)
                .frame(width: 29, height: 29)
                .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundColor(.white))
        }
    }
}

// MARK: - CPU & Memory (Settings › Performance)

/// What Linux programs are told about CPU cores and memory. Programs size their
/// worker threads (make -j, compilers, Node.js, Java) and heaps from these, and
/// guest threads run on separate CPU cores. Applied at the next launch.
struct SystemResourcesView: View {
    @AppStorage(LRSystemCPUCoresKey) private var cores = 0
    @AppStorage(LRSystemMemoryMBKey) private var memoryMB = 0
    private let hostCores = max(1, min(16, ProcessInfo.processInfo.activeProcessorCount))
    /// Advertised RAM tier: iOS reports a little less than the marketed amount
    /// (a 12 GB iPhone can report under 11.5 GiB), so classify instead of rounding.
    private let deviceGB: Int = {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        switch gib {
        case 14...: return 16
        case 10...: return 12
        case 7...: return 8
        case 5...: return 6
        case 3.5...: return 4
        default: return max(1, Int(gib.rounded()))
        }
    }()
    private let appliedCores = ProcessInfo.processInfo.environment["LINUXRUNNER_CPU_CORES"].flatMap(Int.init) ?? 0
    private let appliedMemoryMB = ProcessInfo.processInfo.environment["LINUXRUNNER_MEMORY_MB"].flatMap(Int.init) ?? 0

    /// 12 GB → 8, 16 → 8 (runtime maximum), 8 → 4, 6 → 3, 4 → 2: the rest stays for iOS and the app.
    private var maximumGB: Int {
        let limit = deviceGB >= 12 ? deviceGB - 4 : deviceGB >= 8 ? deviceGB / 2 : deviceGB >= 6 ? 3 : max(1, deviceGB / 2)
        return min(8, max(1, limit))
    }
    /// What iOS lets LinuxRunner use right now (footprint plus what is still
    /// available); nil where iOS reports no app limit (Simulator, Mac).
    private var iosAllowanceGB: Double? {
        let available = os_proc_available_memory()
        guard available > 0 else { return nil }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let footprint = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        } == KERN_SUCCESS ? Double(info.phys_footprint) : 0
        return (footprint + Double(available)) / 1_073_741_824
    }
    /// Matches `guest_memory_total()` + `PLATFORM_GUEST_MEMORY_DEFAULT_CAP`:
    /// half of what iOS allows DebianRunner (or host RAM on Simulator), capped at 4 GiB.
    private var automaticMemoryGB: Double {
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let limitGB: Double
        if let allowance = iosAllowanceGB, allowance > 0, allowance < physicalGB {
            limitGB = allowance
        } else {
            limitGB = physicalGB
        }
        return min(4.0, limitGB / 2.0)
    }
    private var automaticMemoryText: String {
        let gb = automaticMemoryGB
        if gb >= 1.0 {
            let rounded = (gb * 10).rounded() / 10
            return rounded.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f GB", rounded)
                : String(format: "%.1f GB", rounded)
        }
        return "\(Int((gb * 1024).rounded())) MB"
    }
    private var pendingRestart: Bool { cores != appliedCores || memoryMB != appliedMemoryMB }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                card(title: "CPU Cores", symbol: "cpu.fill", colors: [.indigo, .purple],
                     value: cores == 0 ? "Automatic · 4" : "\(cores) of \(hostCores)",
                     detail: "Linux programs start this many worker threads, and each runs on its own core. More cores speed up compiling and parallel workloads; Automatic keeps 4, which suits most tools.") {
                    chips(options: [0] + Array(1...hostCores), selection: $cores) { $0 == 0 ? "Auto" : "\($0)" }
                }
                card(title: "Linux Memory", symbol: "memorychip.fill", colors: [.teal, .blue],
                     value: memoryMB == 0 ? "Automatic · \(automaticMemoryText)" : "\(memoryMB / 1024) GB",
                     detail: "The memory Linux programs see. Compilers, Java, and Node.js size their heaps from it. Automatic chooses \(automaticMemoryText) (half of iOS's allowance, up to 4 GB); manual allows up to \(maximumGB) GB on this \(deviceGB) GB device.") {
                    chips(options: [0] + Array(1...maximumGB).map { $0 * 1024 }, selection: $memoryMB) { $0 == 0 ? "Auto" : "\($0 / 1024) GB" }
                    if memoryMB > 0, let allowance = iosAllowanceGB, Double(memoryMB) / 1024 > allowance {
                        Label(String(format: "iOS currently allows DebianRunner about %.1f GB. Programs that use more than that can be closed by iOS.", allowance), systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if pendingRestart {
                    Label("Applies the next time DebianRunner starts. Close it from the app switcher and open it again.", systemImage: "arrow.clockwise.circle.fill")
                        .font(.footnote.weight(.medium)).foregroundStyle(.blue)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.blue.opacity(0.12)))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12).padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("CPU & Memory")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: "speedometer").font(.system(size: 24, weight: .semibold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(UIDevice.current.model).font(.headline)
                Text("\(hostCores) CPU cores · \(deviceGB) GB memory").font(.subheadline).foregroundStyle(.secondary)
                if let allowance = iosAllowanceGB {
                    Text(String(format: "iOS allows DebianRunner about %.1f GB now", allowance)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func card<Content: View>(title: String, symbol: String, colors: [Color], value: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundColor(.white))
                Text(title).font(.headline)
                Spacer()
                Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
            Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func chips(options: [Int], selection: Binding<Int>, label: @escaping (Int) -> String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
            ForEach(options, id: \.self) { option in
                let selected = selection.wrappedValue == option
                Button { withAnimation(.easeOut(duration: 0.2)) { selection.wrappedValue = option } } label: {
                    Text(label(option))
                        .font(.subheadline.weight(selected ? .semibold : .regular).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundColor(selected ? .white : .primary)
                        .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemGroupedBackground))))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Shared settings design (Devices, File Sharing)
// Cards in the style of CPU & Memory: gradient icon tile, headline, short
// value, content, and long explanations folded into "More info".
struct LRIconTile: View {
    let symbol: String; let colors: [Color]; var size: CGFloat = 34
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.47, weight: .semibold)).foregroundColor(.white))
    }
}

struct LRCard<Content: View>: View {
    let title: String; let symbol: String; let colors: [Color]; var value: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LRIconTile(symbol: symbol, colors: colors)
                Text(title).font(.headline)
                Spacer()
                if let value { Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct LRChoice: Identifiable { let id: String; let title: String; let subtitle: String; let symbol: String }

struct LRChoiceList: View {
    let choices: [LRChoice]; @Binding var selection: String
    var body: some View {
        VStack(spacing: 8) {
            ForEach(choices) { choice in
                let selected = selection == choice.id
                Button { withAnimation(.easeOut(duration: 0.2)) { selection = choice.id } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: choice.symbol).font(.system(size: 16, weight: .semibold))
                            .foregroundColor(selected ? .white : .accentColor)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.14))))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                            Text(choice.subtitle).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundColor(selected ? .accentColor : Color(.tertiaryLabel))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct LRStatusPill: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundColor(color).background(Capsule().fill(color.opacity(0.15)))
    }
}

struct LRMoreInfo<Content: View>: View {
    var title = "More info"
    @ViewBuilder let content: () -> Content
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(title).font(.footnote.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).rotationEffect(.degrees(open ? 180 : 0))
                }.foregroundColor(.accentColor)
            }.buttonStyle(.plain)
            if open { content().font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct LRNavRow: View {
    let title: String; let subtitle: String?; let symbol: String; let colors: [Color]
    var body: some View {
        HStack(spacing: 12) {
            LRIconTile(symbol: symbol, colors: colors, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.vertical, 4).contentShape(Rectangle())
    }
}
