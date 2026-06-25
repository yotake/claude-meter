import AppKit
import SwiftUI

@main
struct ClaudeMeterApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var settings = AppSettings()

    init() {
        // Hide from Dock even when launched as a bare executable.
        NSApplication.shared.setActivationPolicy(.accessory)
        // Debug: render the popover with sample data to a PNG and exit.
        if let path = ProcessInfo.processInfo.environment["CLAUDEMETER_RENDER"] {
            Self.renderPreview(to: path)
            exit(0)
        }
    }

    /// Render `UsagePopoverView` with representative sample data to a PNG (for
    /// previewing the UI). Triggered only by the CLAUDEMETER_RENDER env var.
    @MainActor
    static func renderPreview(to path: String) {
        let model = UsageModel()
        model.hasStoredCredentials = true
        model.needsLogin = false
        model.subscriptionType = "team"
        model.accounts = [
            AccountInfo(id: "a", label: "Team", subscriptionType: "team", kind: .subscription),
            AccountInfo(id: "b", label: "Personal", subscriptionType: "pro", kind: .subscription),
        ]
        model.selectedAccountId = "a"
        let week = Date().addingTimeInterval(3 * 86400)
        model.accountUsages = [
            "a": Usage(
                fiveHour: UsageWindow(utilization: 42, resetsAt: Date().addingTimeInterval(2 * 3600 + 12 * 60)),
                sevenDay: UsageWindow(utilization: 63, resetsAt: week),
                sevenDaySonnet: UsageWindow(utilization: 21, resetsAt: week),
                // Opus weekly is absent for most plans (the API omits seven_day_opus),
                // so leave it nil to match what real accounts actually show.
                sevenDayOpus: nil,
                fetchedAt: Date()
            ),
            "b": Usage(
                fiveHour: UsageWindow(utilization: 8, resetsAt: Date().addingTimeInterval(3 * 3600)),
                sevenDay: UsageWindow(utilization: 31, resetsAt: week),
                sevenDaySonnet: UsageWindow(utilization: 12, resetsAt: week),
                sevenDayOpus: nil,
                fetchedAt: Date()
            ),
        ]
        model.codex = CodexUsage(
            primary: UsageWindow(utilization: 12, resetsAt: Date().addingTimeInterval(4 * 3600)),
            secondary: UsageWindow(utilization: 2, resetsAt: Date().addingTimeInterval(5 * 86400)),
            asOf: Date().addingTimeInterval(-6 * 86400),
            planType: "plus"
        )
        let settings = AppSettings()
        let view = VStack(alignment: .leading, spacing: 8) {
            MenuBarLabel(model: model, settings: settings)   // the menu bar label
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            UsagePopoverView(model: model, settings: settings, previewMode: true)
        }
        .padding(12)
        // Opaque white so the PNG stays readable on GitHub's dark theme
        // (the popover content is otherwise transparent).
        .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model, settings: settings)
        } label: {
            // The label appears at launch; the popover content only when opened.
            MenuBarLabel(model: model, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar label: gauge + selected-account session % (tinted by burn-rate
/// status), plus a terminal glyph + Codex session % when Codex is present.
struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let status = model.menuBarStatus(warnPct: settings.barWarnPct, critPct: settings.barCritPct)
        // A MenuBarExtra status item reliably renders only ONE image + ONE text, so
        // the Codex session % is folded into the text rather than a second glyph.
        // (The burn-rate forecast can't be a status-item tooltip — SwiftUI
        // rasterizes this label to a template image — so it lives in the popover.)
        HStack(spacing: 3) {
            Image(systemName: status.symbolName)
            Text(menuText)
                .monospacedDigit()
        }
        .foregroundStyle(status.color)
        .onAppear { model.start() }
    }

    private var menuText: String {
        var parts: [String] = []
        if settings.showClaudeInMenuBar {
            parts.append(model.menuBarText)              // selected Claude session % (or $ / –)
        }
        if settings.showCodexInMenuBar, let primary = model.codex?.primary {
            parts.append("\(Int(primary.utilization.rounded()))%")   // Codex session %
        }
        return parts.joined(separator: " · ")            // empty → icon only
    }
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @State private var editingToken: Bool = false
    @State private var tokenInput: String = ""
    @State private var labelInput: String = ""
    @State private var commandCopied: Bool = false
    // Collapsed in the real app; the screenshot renderer can start it open via
    // CLAUDEMETER_RENDER_SETTINGS so the Settings panel appears in the capture.
    @State private var showingSettings: Bool =
        ProcessInfo.processInfo.environment["CLAUDEMETER_RENDER_SETTINGS"] != nil
    /// When true (screenshot rendering only), interactive controls are drawn as
    /// their labels instead of live Buttons — ImageRenderer can't render Buttons.
    /// Defaults to false, so the real app is unaffected.
    var previewMode: Bool = false

    /// A borderless action: a real Button at runtime, just its label when
    /// rendering a screenshot (previewMode).
    @ViewBuilder
    private func actionButton<Label: View>(_ action: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
        if previewMode { label() } else { Button(action: action, label: label) }
    }

    // The command that prints the official CLI's keychain token (with user:profile)
    // to the clipboard, ready to paste into the SecureField below.
    static let copyTokenCommand = "security find-generic-password -s \"Claude Code-credentials\" -w | pbcopy"

    // Donation link opened by the Support button (free-app tip jar).
    static let supportURL = URL(string: "https://github.com/sponsors/yotake")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                if let plan = model.subscriptionType {
                    Text(plan.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !previewMode {
                    Button {
                        model.refresh()
                    } label: {
                        if model.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isLoading)
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Every added account's limits, shown compactly. A divider separates
            // consecutive accounts; the sections below add their own leading
            // dividers, so there is exactly one divider between each section.
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider() }
                accountBlock(account)
            }

            if settings.showCodex, let codex = model.codex {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L.codexTitle)
                            .font(.subheadline.weight(.semibold))
                        if let plan = codex.planType {
                            Text(plan.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if let primary = codex.primary {
                        // 5h session: reset time only (no weekday).
                        CompactUsageRow(title: L.codexSession, window: primary,
                                        warnPct: settings.barWarnPct, critPct: settings.barCritPct,
                                        resetText: primary.resetsAt.map { L.resetsAt(Self.timeOnly($0)) },
                                        showResetTime: settings.showResetTime)
                    }
                    if let secondary = codex.secondary {
                        CompactUsageRow(title: L.codexWeekly, window: secondary,
                                        warnPct: settings.barWarnPct, critPct: settings.barCritPct,
                                        resetText: secondary.resetsAt.map { L.resetsAt(Self.weekday($0)) },
                                        showResetTime: settings.showResetTime)
                    }
                    // Flag staleness: once the snapshot is older than the primary
                    // (5h) window, the shown % may have rolled over since.
                    Text(L.codexAsOf(codex.asOf.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(Date().timeIntervalSince(codex.asOf) > 5 * 3600 ? Color.orange : Color.secondary)
                }
            }

            Divider()

            // Credentials section — paste the official CLI's keychain token (has
            // user:profile, which /api/oauth/usage requires). The app then auto-refreshes it.
            if !model.hasStoredCredentials || model.needsLogin || editingToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.runInTerminal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(Self.copyTokenCommand)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            copyCommand()
                        } label: {
                            Image(systemName: commandCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(commandCopied ? Color.green : Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help(L.copyCommand)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Text(L.adminKeyHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(L.accountLabel, text: $labelInput)
                        .textFieldStyle(.roundedBorder)
                    SecureField(L.pasteToken, text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if !model.accounts.isEmpty {
                            Button(L.cancel) {
                                editingToken = false
                                tokenInput = ""
                                labelInput = ""
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L.add) {
                            model.addAccount(tokenInput, label: labelInput)
                            tokenInput = ""
                            labelInput = ""
                            editingToken = false
                        }
                        .buttonStyle(.borderless)
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                actionButton({ editingToken = true }) {
                    Label(L.addAccount, systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            Divider()
            settingsSection

            Divider()
            HStack {
                actionButton({ NSWorkspace.shared.open(Self.supportURL) }) {
                    Label(L.support, systemImage: "heart")
                }
                .buttonStyle(.borderless)
                Spacer()
                actionButton({ NSApplication.shared.terminate(nil) }) {
                    Text(L.quit)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// One account: a compact header (select / label / plan / remove) plus its
    /// limit bars (subscription) or spend (API). Tap the header to select.
    private func accountBlock(_ account: AccountInfo) -> some View {
        let selected = account.id == model.selectedAccountId
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(account.label).font(.callout.weight(.semibold))
                if let sub = account.subscriptionType {
                    Text(sub.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                actionButton({ model.removeAccount(account.id) }) {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(L.remove)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectAccount(account.id) }

            accountBody(account)
        }
    }

    @ViewBuilder private func accountBody(_ account: AccountInfo) -> some View {
        if let err = model.accountErrors[account.id] {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if account.kind == .api {
            if let api = model.accountApiUsage[account.id] {
                HStack { Text(L.apiSpend); Spacer(); Text(Self.money(api.monthCostUSD)).monospacedDigit() }
                    .font(.callout)
                HStack {
                    Text(L.apiTokensInOut)
                    Spacer()
                    Text("\(Self.compact(api.totalInput)) / \(Self.compact(api.totalOutput))").monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if let u = model.accountUsages[account.id] {
            if settings.showSession, let s = u.fiveHour {
                sessionRow(s)
            }
            if settings.showWeeklyAll, let w = u.sevenDay {
                CompactUsageRow(title: L.limWeekly, window: w, warnPct: settings.barWarnPct, critPct: settings.barCritPct,
                                resetText: w.resetsAt.map { L.resetsAt(Self.weekday($0)) },
                                showResetTime: settings.showResetTime)
            }
            if settings.showSonnet, let s = u.sevenDaySonnet {
                CompactUsageRow(title: L.limSonnet, window: s, warnPct: settings.barWarnPct, critPct: settings.barCritPct,
                                resetText: s.resetsAt.map { L.resetsAt(Self.weekday($0)) },
                                showResetTime: settings.showResetTime)
            }
            if settings.showOpus, let o = u.sevenDayOpus {
                CompactUsageRow(title: L.limOpus, window: o, warnPct: settings.barWarnPct, critPct: settings.barCritPct,
                                resetText: o.resetsAt.map { L.resetsAt(Self.weekday($0)) },
                                showResetTime: settings.showResetTime)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var settingsSection: some View {
        DisclosureGroup(isExpanded: $showingSettings) {
            VStack(alignment: .leading, spacing: 6) {
                languagePicker()
                Divider()
                settingsToggle(L.showSession, $settings.showSession)
                settingsToggle(L.showWeeklyAll, $settings.showWeeklyAll)
                settingsToggle(L.showSonnet, $settings.showSonnet)
                // A separate weekly Opus limit only exists on some plans (the API
                // omits seven_day_opus otherwise), so only offer the toggle when an
                // account actually reports one — else it's a no-op control.
                if model.accountUsages.values.contains(where: { $0.sevenDayOpus != nil }) {
                    settingsToggle(L.showOpus, $settings.showOpus)
                }
                settingsToggle(L.showResetTime, $settings.showResetTime)
                settingsToggle(L.showCodex, $settings.showCodex)
                settingsToggle(L.showClaudeInMenuBar, $settings.showClaudeInMenuBar)
                settingsToggle(L.showCodexInMenuBar, $settings.showCodexInMenuBar)
                if settings.showCodex {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.codexSessionsPath).font(.caption)
                        if previewMode {
                            // Static stand-in: ImageRenderer can't draw a TextField.
                            Text(settings.codexSessionsPath.isEmpty ? L.codexSessionsPathPlaceholder : settings.codexSessionsPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        } else {
                            TextField(L.codexSessionsPathPlaceholder, text: $settings.codexSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.refreshCodex() }
                        }
                        Text(L.codexSessionsPathHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 18)
                }
                Divider()
                Text(L.barColorThresholds)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                thresholdSlider(L.warnLabel, value: $settings.barWarnPct, range: 10...95)
                thresholdSlider(L.critLabel, value: $settings.barCritPct, range: 15...100)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
        } label: {
            // DisclosureGroup only toggles on the chevron by default. Make the
            // whole label row (full width, icon + text) a hit target so tapping
            // anywhere in the row opens/closes the section.
            Label(L.settings, systemImage: "gearshape")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showingSettings.toggle() } }
        }
    }

    /// The 5h session row, preceded by a burn-rate forecast caption when the
    /// trajectory is noteworthy (warning/critical). The caption sits ABOVE the
    /// row so it reads as an alert for the session it describes.
    @ViewBuilder
    private func sessionRow(_ window: UsageWindow) -> some View {
        let forecast = SessionForecast.compute(window: window, warnPct: settings.barWarnPct, critPct: settings.barCritPct)
        if forecast.status != .ok {
            Text(forecast.describe())
                .font(.caption2)
                .foregroundStyle(forecast.status.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 5h session: reset time only (no weekday — it resets the same day).
        CompactUsageRow(title: L.limSession, window: window, warnPct: settings.barWarnPct, critPct: settings.barCritPct,
                        resetText: window.resetsAt.map { L.resetsAt(Self.timeOnly($0)) },
                        showResetTime: settings.showResetTime)
    }

    /// UI-language selector: a live Picker at runtime, a static label when
    /// rendering a screenshot (ImageRenderer can't draw a Picker).
    @ViewBuilder
    private func languagePicker() -> some View {
        HStack {
            Text(L.language).font(.caption)
            Spacer()
            if previewMode {
                Text(settings.language.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            } else {
                Picker(L.language, selection: $settings.language) {
                    Text(L.langSystem).tag(LanguagePref.system)
                    Text("日本語").tag(LanguagePref.ja)
                    Text("English").tag(LanguagePref.en)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    /// A settings checkbox: a live Toggle at runtime, a static checkbox glyph +
    /// label when rendering a screenshot (ImageRenderer can't draw a Toggle).
    @ViewBuilder
    private func settingsToggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        if previewMode {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                Text(title)
            }
        } else {
            Toggle(title, isOn: isOn)
        }
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption)
            if previewMode {
                // Static slider stand-in (ImageRenderer can't draw a live Slider).
                GeometryReader { geo in
                    let frac = (value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 3)
                        Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                            .offset(x: max(0, min(geo.size.width - 12, (geo.size.width - 12) * frac)))
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 12)
            } else {
                Slider(value: value, in: range, step: 5)
            }
            Text("\(Int(value.wrappedValue))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.copyTokenCommand, forType: .string)
        commandCopied = true
        // Revert the checkmark to the copy icon after a brief moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            commandCopied = false
        }
    }

    /// USD formatting kept in dollars regardless of locale (API pricing is USD).
    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Compact token count, e.g. 1.2M / 34.5K / 980.
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.1fK", v / 1_000) }
        return "\(n)"
    }

    /// Weekday + 24h time (e.g. "Thu 14:00"), localized — used for the weekly windows.
    static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: date)
    }

    /// Time only (e.g. "14:54"), localized — used for the 5h session windows
    /// where the weekday is redundant (they reset the same day).
    static func timeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Compact one-line limit bar: "Title …… 42%" + a thin colored bar. The reset
/// time is always on hover (`.help`); when `showResetTime` is on it also shows
/// as a visible caption line beneath the bar.
struct CompactUsageRow: View {
    let title: String
    let window: UsageWindow
    var warnPct: Double = 60
    var critPct: Double = 85
    var resetText: String?
    var showResetTime: Bool = false

    private var fraction: Double { min(max(window.utilization / 100, 0), 1) }

    private var barColor: Color {
        // Tolerate crit < warn (sliders are independent): use a sorted pair.
        let lo = min(warnPct, critPct)
        let hi = max(warnPct, critPct)
        switch window.utilization {
        case ..<lo: return .blue
        case ..<hi: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(L.percentUsed(Int(window.utilization.rounded())))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            // Custom thin bar rather than ProgressView: gives exact control over
            // thickness and renders reliably in ImageRenderer screenshots (the
            // AppKit-backed ProgressView shows a placeholder there).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(barColor)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
            if showResetTime, let resetText, !resetText.isEmpty {
                // Right-aligned so the changing value lines up under the "% used"
                // column — easier to scan than a left-aligned caption.
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .help(resetText ?? "")
    }
}
