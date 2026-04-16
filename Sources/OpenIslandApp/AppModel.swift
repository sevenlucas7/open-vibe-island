import AppKit
import Foundation
import Observation
import OpenIslandCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    struct AgentIdentity: Equatable {
        var displayName: String
        var shortLabel: String
        var ownerColor: Color
        var avatarPresetKey: String
        var animationProfileKey: String
    }

    private static let soundMutedDefaultsKey = "overlay.sound.muted"
    private static let showDockIconDefaultsKey = "app.showDockIcon"
    private static let syntheticClaudeSessionPrefix = "claude-process:"
    private static let liveSessionStalenessWindow: TimeInterval = 15 * 60
    private static let jumpOverlayDismissLeadTime: Duration = .milliseconds(20)
    private static let prioritizedOwnerDisplayName = "Seven"
    private static let canonicalOwnerDisplayNames: [String: String] = [
        "seven": "Seven",
        "claw seven": "Seven",
        "luvian": "Luvian",
        "claw luvian": "Luvian",
        "fanshu": "Fanshu",
        "claw fanshu": "Fanshu",
        "pipi": "Pipi",
        "claw pipi": "Pipi",
        "momo": "Momo",
        "claw momo": "Momo",
        "hermes": "Hermes",
        "claw hermes": "Hermes",
    ]
    private static let defaultOwnerDisplayNamesByTool: [AgentTool: String] = [
        .codex: "Seven",
        .claudeCode: "Luvian",
        .qoder: "Fanshu",
        .openCode: "Fanshu",
        .factory: "Pipi",
        .cursor: "Pipi",
        .codebuddy: "Momo",
        .geminiCLI: "Momo",
    ]
    private static let canonicalAgentIdentities: [String: AgentIdentity] = [
        "seven": AgentIdentity(displayName: "Seven", shortLabel: "SEV", ownerColor: Color(red: 0.37, green: 0.92, blue: 0.83), avatarPresetKey: "scout", animationProfileKey: "pulse"),
        "luvian": AgentIdentity(displayName: "Luvian", shortLabel: "LUV", ownerColor: Color(red: 0.31, green: 0.79, blue: 0.71), avatarPresetKey: "orb", animationProfileKey: "drift"),
        "fanshu": AgentIdentity(displayName: "Fanshu", shortLabel: "FAN", ownerColor: Color(red: 0.96, green: 0.45, blue: 0.71), avatarPresetKey: "flare", animationProfileKey: "flicker"),
        "pipi": AgentIdentity(displayName: "Pipi", shortLabel: "PIP", ownerColor: Color(red: 0.38, green: 0.65, blue: 0.98), avatarPresetKey: "array", animationProfileKey: "scan"),
        "momo": AgentIdentity(displayName: "Momo", shortLabel: "MOM", ownerColor: Color(red: 0.65, green: 0.55, blue: 0.98), avatarPresetKey: "halo", animationProfileKey: "glow"),
        "hermes": AgentIdentity(displayName: "Hermes", shortLabel: "HRM", ownerColor: Color(red: 0.96, green: 0.73, blue: 0.31), avatarPresetKey: "halo", animationProfileKey: "glow"),
    ]
    static let hoverOpenDelay: TimeInterval = 0.15

    struct AcceptanceStep: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
    }

    let lang = LanguageManager.shared

    var state = SessionState() {
        didSet {
            _cachedSessionBuckets = nil
            bridgeServer.updateStateSnapshot(state)
        }
    }
    @ObservationIgnored private var _cachedSessionBuckets: (primary: [AgentSession], overflow: [AgentSession])?
    var selectedSessionID: String?
    let hooks = HookInstallationCoordinator()
    let overlay = OverlayUICoordinator()
    let discovery = SessionDiscoveryCoordinator()
    let monitoring = ProcessMonitoringCoordinator()
    let updateChecker = UpdateChecker()

    var notchStatus: NotchStatus {
        get { overlay.notchStatus }
        set { overlay.notchStatus = newValue }
    }
    var notchOpenReason: NotchOpenReason? {
        get { overlay.notchOpenReason }
        set { overlay.notchOpenReason = newValue }
    }
    var islandSurface: IslandSurface {
        get { overlay.islandSurface }
        set { overlay.islandSurface = newValue }
    }
    var isOverlayVisible: Bool { overlay.isOverlayVisible }
    var isOverlayCloseTransitionPending: Bool { overlay.isCloseTransitionPending }
    var isCodexSetupBusy: Bool { hooks.isCodexSetupBusy }
    var isClaudeHookSetupBusy: Bool { hooks.isClaudeHookSetupBusy }
    var isClaudeUsageSetupBusy: Bool { hooks.isClaudeUsageSetupBusy }
    var codexHookStatus: CodexHookInstallationStatus? { hooks.codexHookStatus }
    var claudeHookStatus: ClaudeHookInstallationStatus? { hooks.claudeHookStatus }
    var claudeStatusLineStatus: ClaudeStatusLineInstallationStatus? { hooks.claudeStatusLineStatus }
    var claudeUsageSnapshot: ClaudeUsageSnapshot? { hooks.claudeUsageSnapshot }
    var codexUsageSnapshot: CodexUsageSnapshot? { hooks.codexUsageSnapshot }
    var hooksBinaryURL: URL? { hooks.hooksBinaryURL }
    var codexHooksInstalled: Bool { hooks.codexHooksInstalled }
    var claudeHooksInstalled: Bool { hooks.claudeHooksInstalled }
    var qoderHooksInstalled: Bool { hooks.qoderHooksInstalled }
    var factoryHooksInstalled: Bool { hooks.factoryHooksInstalled }
    var codebuddyHooksInstalled: Bool { hooks.codebuddyHooksInstalled }
    var qoderHookStatus: ClaudeHookInstallationStatus? { hooks.qoderHookStatus }
    var factoryHookStatus: ClaudeHookInstallationStatus? { hooks.factoryHookStatus }
    var codebuddyHookStatus: ClaudeHookInstallationStatus? { hooks.codebuddyHookStatus }
    var isQoderHookSetupBusy: Bool { hooks.isQoderHookSetupBusy }
    var isFactoryHookSetupBusy: Bool { hooks.isFactoryHookSetupBusy }
    var isCodebuddyHookSetupBusy: Bool { hooks.isCodebuddyHookSetupBusy }
    var openCodePluginInstalled: Bool { hooks.openCodePluginInstalled }
    var claudeUsageInstalled: Bool { hooks.claudeUsageInstalled }
    var claudeHookStatusTitle: String { hooks.claudeHookStatusTitle }
    var claudeHookStatusSummary: String { hooks.claudeHookStatusSummary }
    var claudeUsageStatusTitle: String { hooks.claudeUsageStatusTitle }
    var claudeUsageStatusSummary: String { hooks.claudeUsageStatusSummary }
    var claudeUsageSummaryText: String? { hooks.claudeUsageSummaryText }
    var codexUsageStatusTitle: String { hooks.codexUsageStatusTitle }
    var codexUsageStatusSummary: String { hooks.codexUsageStatusSummary }
    var codexUsageSummaryText: String? { hooks.codexUsageSummaryText }
    var openCodePluginStatus: OpenCodePluginInstallationStatus? { hooks.openCodePluginStatus }
    var isOpenCodeSetupBusy: Bool { hooks.isOpenCodeSetupBusy }
    var openCodePluginStatusTitle: String { hooks.openCodePluginStatusTitle }
    var openCodePluginStatusSummary: String { hooks.openCodePluginStatusSummary }
    var claudeHealthReport: HookHealthReport? { hooks.claudeHealthReport }
    var codexHealthReport: HookHealthReport? { hooks.codexHealthReport }
    var cursorHooksInstalled: Bool { hooks.cursorHooksInstalled }
    var isCursorHookSetupBusy: Bool { hooks.isCursorHookSetupBusy }
    var cursorHookStatusTitle: String { hooks.cursorHookStatusTitle }
    var cursorHookStatusSummary: String { hooks.cursorHookStatusSummary }
    var codexHookStatusTitle: String { hooks.codexHookStatusTitle }
    var codexHookStatusSummary: String { hooks.codexHookStatusSummary }
    func refreshCodexHookStatus() { hooks.refreshCodexHookStatus() }
    func refreshClaudeHookStatus() { hooks.refreshClaudeHookStatus() }
    func refreshOpenCodePluginStatus() { hooks.refreshOpenCodePluginStatus() }
    func refreshCursorHookStatus() { hooks.refreshCursorHookStatus() }
    func refreshClaudeUsageState() { hooks.refreshClaudeUsageState() }
    func refreshCodexUsageState() { hooks.refreshCodexUsageState() }
    func installCodexHooks() { hooks.installCodexHooks() }
    func uninstallCodexHooks() { hooks.uninstallCodexHooks() }
    func installClaudeHooks() { hooks.installClaudeHooks() }
    func uninstallClaudeHooks() { hooks.uninstallClaudeHooks() }
    func installQoderHooks() { hooks.installQoderHooks() }
    func uninstallQoderHooks() { hooks.uninstallQoderHooks() }
    func installFactoryHooks() { hooks.installFactoryHooks() }
    func uninstallFactoryHooks() { hooks.uninstallFactoryHooks() }
    func installCodebuddyHooks() { hooks.installCodebuddyHooks() }
    func uninstallCodebuddyHooks() { hooks.uninstallCodebuddyHooks() }
    func refreshCCForkHookStatuses() { hooks.refreshCCForkHookStatuses() }
    func installOpenCodePlugin() { hooks.installOpenCodePlugin() }
    func uninstallOpenCodePlugin() { hooks.uninstallOpenCodePlugin() }
    func installCursorHooks() { hooks.installCursorHooks() }
    func uninstallCursorHooks() { hooks.uninstallCursorHooks() }
    func installClaudeUsageBridge() { hooks.installClaudeUsageBridge() }
    func uninstallClaudeUsageBridge() { hooks.uninstallClaudeUsageBridge() }
    func runHealthChecks() { hooks.runHealthChecks() }
    func repairHooks() {
        Task { @MainActor in
            await hooks.repairHooksIfNeeded()
        }
    }
    var isBridgeReady = false
    var lastActionMessage = "Waiting for agent hook events..." {
        didSet {
            guard lastActionMessage != oldValue else {
                return
            }

            harnessRuntimeMonitor?.recordLog(lastActionMessage)
        }
    }
    var isResolvingInitialLiveSessions: Bool {
        get { monitoring.isResolvingInitialLiveSessions }
        set { monitoring.isResolvingInitialLiveSessions = newValue }
    }
    var overlayDisplayOptions: [OverlayDisplayOption] {
        get { overlay.overlayDisplayOptions }
        set { overlay.overlayDisplayOptions = newValue }
    }
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics? {
        get { overlay.overlayPlacementDiagnostics }
        set { overlay.overlayPlacementDiagnostics = newValue }
    }
    var showDockIcon: Bool = false {
        didSet {
            guard hasFinishedInit, showDockIcon != oldValue else { return }
            UserDefaults.standard.set(showDockIcon, forKey: Self.showDockIconDefaultsKey)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            if !showDockIcon {
                // macOS does not immediately refresh the Dock when switching to
                // .accessory at runtime. Briefly activating another app forces
                // the Dock to drop the icon.
                NSApp.hide(nil)
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                }
            }
        }
    }
    var isSoundMuted = false {
        didSet {
            guard isSoundMuted != oldValue else {
                return
            }

            UserDefaults.standard.set(isSoundMuted, forKey: Self.soundMutedDefaultsKey)
            lastActionMessage = isSoundMuted
                ? "Island sound notifications muted."
                : "Island sound notifications enabled."
        }
    }
    var selectedSoundName: String = NotificationSoundService.defaultSoundName {
        didSet {
            guard selectedSoundName != oldValue else { return }
            NotificationSoundService.selectedSoundName = selectedSoundName
        }
    }
    var overlayDisplaySelectionID: String {
        get { overlay.overlayDisplaySelectionID }
        set { overlay.overlayDisplaySelectionID = newValue }
    }
    @ObservationIgnored
    var openSettingsWindow: (() -> Void)?

    @ObservationIgnored
    private var hasFinishedInit = false

    var openClawAvailability: OpenClawDiscovery.Availability?
    var openClawTeamStoreCount: Int = 0
    var openClawRecentOwnerCount: Int = 0

    var ignoresPointerExitDuringHarness = false
    var disablesOverlayEventMonitoringDuringHarness = false

    @ObservationIgnored
    private var bridgeTask: Task<Void, Never>?

    @ObservationIgnored
    private var bridgeReconnectTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasStarted = false

    @ObservationIgnored
    private let bridgeServer = BridgeServer()

    @ObservationIgnored
    private var bridgeClient = LocalBridgeClient()

    @ObservationIgnored
    private let terminalJumpAction: @Sendable (JumpTarget) throws -> String


    @ObservationIgnored
    var harnessRuntimeMonitor: HarnessRuntimeMonitor?


    @ObservationIgnored
    private var jumpTask: Task<Void, Never>?

    init(
        terminalJumpAction: @escaping @Sendable (JumpTarget) throws -> String = { target in
            try TerminalJumpService().jump(to: target)
        }
    ) {
        self.terminalJumpAction = terminalJumpAction
        UserDefaults.standard.register(defaults: [Self.showDockIconDefaultsKey: true])
        isSoundMuted = UserDefaults.standard.bool(forKey: Self.soundMutedDefaultsKey)
        selectedSoundName = NotificationSoundService.selectedSoundName
        showDockIcon = UserDefaults.standard.bool(forKey: Self.showDockIconDefaultsKey)

        overlay.appModel = self
        overlay.restoreDisplayPreference()
        overlay.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        overlay.activeIslandCardSessionAccessor = { [weak self] in
            self?.activeIslandCardSession
        }
        overlay.isSoundMutedAccessor = { [weak self] in
            self?.isSoundMuted ?? false
        }
        overlay.ignoresPointerExitAccessor = { [weak self] in
            self?.ignoresPointerExitDuringHarness ?? false
        }

        hooks.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }

        discovery.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        discovery.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        discovery.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        discovery.stateUpdater = { [weak self] in self?.state = $0 }
        discovery.onStateChanged = { [weak self] in
            self?.synchronizeSelection()
            self?.refreshOverlayPlacementIfVisible()
        }

        discovery.codexRolloutWatcher.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyTrackedEvent(
                    event,
                    updateLastActionMessage: false,
                    ingress: .rollout
                )
            }
        }

        monitoring.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        monitoring.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        monitoring.stateUpdater = { [weak self] in self?.state = $0 }
        monitoring.onSessionsReconciled = { [weak self] in
            self?.synchronizeSelection()
            self?.refreshOverlayPlacementIfVisible()
        }
        monitoring.onPersistenceNeeded = { [weak self] in
            self?.discovery.scheduleCodexSessionPersistence()
            self?.discovery.scheduleClaudeSessionPersistence()
            self?.discovery.scheduleCursorSessionPersistence()
        }

        refreshOverlayDisplayConfiguration()
        hasFinishedInit = true
    }

    var sessions: [AgentSession] {
        state.sessions
    }

    var allSessions: [AgentSession] {
        state.sessions
    }

    /// Measured by SwiftUI GeometryReader in notification mode. Used by panel controller for sizing.
    var measuredNotificationContentHeight: CGFloat = 0 {
        didSet {
            if measuredNotificationContentHeight != oldValue, measuredNotificationContentHeight > 0 {
                overlay.refreshOverlayPlacementIfVisible()
            }
        }
    }

    var surfacedSessions: [AgentSession] {
        sessionBuckets.primary
    }

    var recentSessions: [AgentSession] {
        sessionBuckets.overflow
    }

    var islandListSessions: [AgentSession] {
        surfacedSessions
    }

    var recentSessionCount: Int {
        recentSessions.count
    }

    var liveSessionCount: Int {
        surfacedSessions.count
    }

    var liveAttentionCount: Int {
        surfacedSessions.filter { $0.phase.requiresAttention }.count
    }

    var liveRunningCount: Int {
        surfacedSessions.filter { $0.phase == .running }.count
    }

    var shouldShowSessionBootstrapPlaceholder: Bool {
        isResolvingInitialLiveSessions
            && liveSessionCount == 0
            && state.sessions.contains(where: \.isTrackedLiveSession)
    }

    var focusedSession: AgentSession? {
        state.session(id: selectedSessionID) ?? surfacedSessions.first ?? state.activeActionableSession ?? state.sessions.first
    }

    var activeIslandCardSession: AgentSession? {
        guard let sessionID = islandSurface.sessionID else {
            return nil
        }

        return state.session(id: sessionID)
    }

    var openClawSessions: [AgentSession] {
        state.sessions.filter { $0.tool == .openClaw }
    }

    var surfacedOpenClawSessions: [AgentSession] {
        surfacedSessions.filter { $0.tool == .openClaw }
    }

    var productSurfacedSessions: [AgentSession] {
        surfacedSessions.filter(isSupportedProductSession)
    }

    var productRecentSessions: [AgentSession] {
        recentSessions.filter(isSupportedProductSession)
    }

    var productIslandListSessions: [AgentSession] {
        productSurfacedSessions
    }

    var productLiveSessionCount: Int {
        productSurfacedSessions.count
    }

    var productActiveAgentCount: Int {
        productSurfacedSessions.filter { $0.phase == .running || $0.phase.requiresAttention }.count
    }

    var productApprovalCount: Int {
        productSurfacedSessions.filter { $0.phase == .waitingForApproval }.count
    }

    var productDoneCount: Int {
        productSurfacedSessions.filter { $0.phase == .completed }.count
    }

    var hasVisibleProductSessions: Bool {
        !productSurfacedSessions.isEmpty
    }

    var productSpotlightSession: AgentSession? {
        productSurfacedSessions.max(by: { spotlightScore(for: $0) < spotlightScore(for: $1) })
    }

    var productFocusedSession: AgentSession? {
        if let selectedSessionID,
           let selected = productSurfacedSessions.first(where: { $0.id == selectedSessionID }) {
            return selected
        }

        return productSpotlightSession
            ?? productSurfacedSessions.first(where: { $0.phase.requiresAttention })
            ?? productSurfacedSessions.first
    }

    var productApprovalPinnedSession: AgentSession? {
        productSurfacedSessions.first(where: { $0.phase == .waitingForApproval })
    }

    var productAttentionSessions: [AgentSession] {
        productSurfacedSessions.filter { $0.phase.requiresAttention }
    }

    var productActiveSessions: [AgentSession] {
        productSurfacedSessions.filter { !$0.phase.requiresAttention && $0.phase == .running }
    }

    var productRecentCompletedSessions: [AgentSession] {
        let surfacedIDs = Set(productSurfacedSessions.map(\.id))
        return state.sessions
            .filter(isSupportedProductSession)
            .filter { !surfacedIDs.contains($0.id) || $0.phase == .completed }
    }

    var shouldShowProductBootstrapPlaceholder: Bool {
        isResolvingInitialLiveSessions && productLiveSessionCount == 0 && openClawAvailability == nil
    }

    var spotlightSession: AgentSession? {
        surfacedSessions.max(by: { spotlightScore(for: $0) < spotlightScore(for: $1) })
    }

    var spotlightIdentity: AgentIdentity? {
        spotlightSession.flatMap(identity(for:))
    }

    var spotlightOverflowCount: Int {
        max(0, surfacedSessions.filter { $0.id != spotlightSession?.id && $0.phase != .completed }.count)
    }

    var attentionSessions: [AgentSession] {
        surfacedSessions.filter { $0.phase.requiresAttention }
    }

    var activeSessions: [AgentSession] {
        surfacedSessions.filter { !$0.phase.requiresAttention && $0.phase == .running }
    }

    var recentCompletedSessions: [AgentSession] {
        let surfacedIDs = Set(surfacedSessions.map(\.id))
        return state.sessions.filter { !surfacedIDs.contains($0.id) || $0.phase == .completed }
    }

    var approvalPinnedSession: AgentSession? {
        attentionSessions.first(where: { $0.phase == .waitingForApproval })
    }

    var activeAgentCount: Int {
        surfacedSessions.filter { $0.phase == .running || $0.phase.requiresAttention }.count
    }

    var approvalCount: Int {
        state.sessions.filter { $0.phase == .waitingForApproval }.count
    }

    var doneCount: Int {
        state.sessions.filter { $0.phase == .completed }.count
    }

    var hasDetectedOpenClaw: Bool {
        openClawAvailability == .detected
    }

    var openClawStatusTitle: String {
        switch openClawAvailability {
        case .detected:
            return "OpenClaw detected"
        case .unavailable:
            return "OpenClaw unavailable"
        case .unreadable:
            return "OpenClaw unreadable"
        case nil:
            return "OpenClaw checking"
        }
    }

    var openClawStatusDetail: String {
        switch openClawAvailability {
        case .detected:
            if openClawTeamStoreCount > 0 && openClawRecentOwnerCount > 0 {
                return "\(openClawTeamStoreCount) Xteam stores found · \(openClawRecentOwnerCount) recent team rows"
            }
            if openClawTeamStoreCount > 0 {
                return "\(openClawTeamStoreCount) Xteam stores found · No recent OpenClaw sessions"
            }
            return "OpenClaw detected, but no Xteam stores were found"
        case .unavailable:
            return "OpenClaw CLI not detected on this Mac"
        case .unreadable:
            return "OpenClaw responded, but session JSON could not be read"
        case nil:
            return "Checking local OpenClaw CLI"
        }
    }

    var shouldShowOpenClawStatusStrip: Bool {
        openClawAvailability != nil
    }

    var hasAnySession: Bool {
        !sessions.isEmpty
    }

    var hasOpenClawSession: Bool {
        openClawSessions.contains(where: { $0.phase == .running || $0.phase.requiresAttention || $0.phase == .completed })
    }

    var hasResolvedOwnerLane: Bool {
        openClawSessions.contains(where: { displayOwner(for: $0) != nil })
    }

    var hasJumpableSession: Bool {
        sessions.contains(where: { $0.jumpTarget != nil })
    }

    var acceptanceSteps: [AcceptanceStep] {
        [
            AcceptanceStep(
                id: "bridge",
                title: "Bridge ready",
                detail: "The app must own the local socket and register as a bridge observer.",
                isComplete: isBridgeReady
            ),
            AcceptanceStep(
                id: "openclaw",
                title: "OpenClaw visibility detected",
                detail: "The local OpenClaw CLI should respond and expose Xteam visibility rows.",
                isComplete: hasDetectedOpenClaw
            ),
            AcceptanceStep(
                id: "overlay",
                title: "Island visible",
                detail: "Show the overlay at least once so the notch/top-bar surface is visible.",
                isComplete: isOverlayVisible
            ),
            AcceptanceStep(
                id: "session",
                title: "An OpenClaw session is observed",
                detail: "Let OpenClaw surface at least one recent team row in the island.",
                isComplete: hasOpenClawSession
            ),
            AcceptanceStep(
                id: "owner",
                title: "Owner lane resolved",
                detail: "At least one visible row should resolve to an owner such as Seven or Hermes.",
                isComplete: hasResolvedOwnerLane
            ),
        ]
    }

    var acceptanceCompletedCount: Int {
        acceptanceSteps.filter(\.isComplete).count
    }

    var isReadyForFirstAcceptance: Bool {
        acceptanceSteps.prefix(3).allSatisfy(\.isComplete)
    }

    var hasPassedAcceptanceFlow: Bool {
        acceptanceSteps.allSatisfy(\.isComplete)
    }

    var acceptanceStatusTitle: String {
        if hasPassedAcceptanceFlow {
            return "v0.1 acceptance passed"
        }

        if isReadyForFirstAcceptance {
            return "Ready for v0.1 acceptance"
        }

        return "v0.1 acceptance not ready"
    }

    var acceptanceStatusSummary: String {
        if hasPassedAcceptanceFlow {
            return "The current build has completed the OpenClaw cockpit checklist end to end."
        }

        if isReadyForFirstAcceptance {
            return "You can start your first acceptance run now. Let OpenClaw surface a live team row and confirm the owner lane renders correctly."
        }

        return "Finish the OpenClaw visibility checks, then bring in a recent team row for verification."
    }

    func startIfNeeded(
        startBridge: Bool = true,
        shouldPerformBootAnimation: Bool = true,
        loadRuntimeState: Bool = true
    ) {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        if loadRuntimeState {
            isResolvingInitialLiveSessions = true

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let payload = self.discovery.loadStartupDiscoveryPayload()
                await MainActor.run {
                    self.applyStartupDiscoveryPayload(payload)
                }
            }

            // These are already async or lightweight — safe to start immediately.
            hooks.refreshCodexHookStatus()
            hooks.refreshClaudeHookStatus()
            hooks.refreshCCForkHookStatuses()
            hooks.refreshOpenCodePluginStatus()
            hooks.refreshCursorHookStatus()
            hooks.refreshClaudeUsageState()
            hooks.startClaudeUsageMonitoringIfNeeded()
            hooks.refreshCodexUsageState()
            hooks.startCodexUsageMonitoringIfNeeded()
            updateChecker.startIfNeeded()

        } else {
            isResolvingInitialLiveSessions = false
        }
        refreshOverlayDisplayConfiguration()
        ensureOverlayPanel()
        if shouldPerformBootAnimation {
            performBootAnimation()
        }

        guard startBridge else {
            isBridgeReady = false
            lastActionMessage = loadRuntimeState
                ? "Harness mode active. Bridge startup skipped."
                : "Deterministic harness mode active. Runtime discovery and bridge startup skipped."
            harnessRuntimeMonitor?.recordMilestone("bridgeSkipped", message: lastActionMessage)
            return
        }

        do {
            try bridgeServer.start()
            connectBridgeObserver()
        } catch {
            isBridgeReady = false
            lastActionMessage = "Failed to start local bridge: \(error.localizedDescription)"
            harnessRuntimeMonitor?.recordMilestone("bridgeStartFailed", message: lastActionMessage)
        }
    }

    // MARK: - Bridge observer connection

    private static let bridgeReconnectDelay: Duration = .seconds(2)
    private static let bridgeMaxReconnectDelay: Duration = .seconds(30)

    private func connectBridgeObserver() {
        bridgeTask?.cancel()
        bridgeReconnectTask?.cancel()

        // Explicitly disconnect the old client so its DispatchSource is
        // cancelled deterministically rather than relying on dealloc timing.
        bridgeClient.disconnect()

        // Create a fresh client for each connection attempt so we don't
        // have to worry about stale file-descriptor state.
        let client = LocalBridgeClient()
        bridgeClient = client

        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()
        } catch {
            isBridgeReady = false
            lastActionMessage = "Failed to connect bridge observer: \(error.localizedDescription)"
            scheduleBridgeReconnect()
            return
        }

        // A single task handles both registration and event consumption so
        // there is no untracked task that could race with a reconnect.
        bridgeTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.send(.registerClient(role: .observer))
                self.isBridgeReady = true
                self.lastActionMessage = "Bridge ready. Waiting for OpenClaw visibility and local session events."
                self.harnessRuntimeMonitor?.recordMilestone("bridgeReady", message: self.lastActionMessage)
            } catch {
                guard !Task.isCancelled else { return }
                self.isBridgeReady = false
                self.lastActionMessage = "Failed to register bridge observer: \(error.localizedDescription)"
                self.harnessRuntimeMonitor?.recordMilestone(
                    "bridgeRegistrationFailed",
                    message: self.lastActionMessage
                )
                self.scheduleBridgeReconnect()
                return
            }

            do {
                for try await event in stream {
                    self.applyTrackedEvent(event)
                }
            } catch {}

            // Stream ended (server closed our connection or transient error).
            // Mark as disconnected and schedule reconnection.
            guard !Task.isCancelled else { return }
            self.isBridgeReady = false
            self.lastActionMessage = "Bridge observer disconnected. Reconnecting…"
            self.harnessRuntimeMonitor?.recordMilestone("bridgeDisconnected", message: self.lastActionMessage)
            self.scheduleBridgeReconnect()
        }
    }

    private func scheduleBridgeReconnect() {
        bridgeReconnectTask?.cancel()
        bridgeReconnectTask = Task { [weak self] in
            var delay = Self.bridgeReconnectDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.connectBridgeObserver()
                // If we're now connected, stop retrying.
                if self.isBridgeReady { return }
                delay = min(delay * 2, Self.bridgeMaxReconnectDelay)
            }
        }
    }

    func select(sessionID: String) {
        selectedSessionID = sessionID
    }

    // MARK: - Overlay forwarding

    func toggleOverlay() { overlay.toggleOverlay() }
    func notchOpen(reason: NotchOpenReason, surface: IslandSurface = .sessionList()) { overlay.notchOpen(reason: reason, surface: surface) }
    func notchClose() { overlay.notchClose() }
    func notchPop() { overlay.notchPop() }
    func performBootAnimation() { overlay.performBootAnimation() }
    func ensureOverlayPanel() { overlay.ensureOverlayPanel() }
    func showOverlay() { overlay.showOverlay() }
    func hideOverlay() { overlay.hideOverlay() }
    func expandNotificationToSessionList(clearExpansion: Bool = false) {
        overlay.expandNotificationToSessionList(clearExpansion: clearExpansion)
    }
    func refreshOverlayDisplayConfiguration() { overlay.refreshOverlayDisplayConfiguration() }
    func refreshOverlayPlacement() { overlay.refreshOverlayPlacement() }
    private func refreshOverlayPlacementIfVisible() { overlay.refreshOverlayPlacementIfVisible() }
    func notePointerInsideIslandSurface() { overlay.notePointerInsideIslandSurface() }
    func handlePointerExitedIslandSurface() { overlay.handlePointerExitedIslandSurface() }
    private func presentNotificationSurface(_ surface: IslandSurface) { overlay.presentNotificationSurface(surface) }
    private func reconcileIslandSurfaceAfterStateChange() { overlay.reconcileIslandSurfaceAfterStateChange() }
    private func dismissNotificationSurfaceIfPresent(for sessionID: String) { overlay.dismissNotificationSurfaceIfPresent(for: sessionID) }
    private func dismissOverlayForJump() { overlay.dismissOverlayForJump() }

    var shouldAutoCollapseOnMouseLeave: Bool { overlay.shouldAutoCollapseOnMouseLeave }
    var autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry: Bool { overlay.autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry }
    var showsNotificationCard: Bool { overlay.showsNotificationCard }

    func loadDebugSnapshot(
        _ snapshot: IslandDebugSnapshot,
        presentOverlay: Bool = false,
        autoCollapseNotificationCards: Bool = false
    ) {
        state = SessionState(sessions: snapshot.sessions)
        selectedSessionID = snapshot.selectedSessionID ?? snapshot.sessions.first?.id
        lastActionMessage = "Loaded debug scenario: \(snapshot.title)."
        harnessRuntimeMonitor?.recordMilestone("scenarioLoaded", message: snapshot.title)

        overlay.applyOverlayState(from: snapshot, presentOverlay: presentOverlay, autoCollapseNotificationCards: autoCollapseNotificationCards)
    }

    func showSettings() {
        openSettingsWindow?()
        if let window = NSApp.windows.first(where: { $0.title == "Open Island Settings" }) {
            window.orderFrontRegardless()
            window.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func showControlCenter() {
        guard let window = NSApp.windows.first(where: { $0.title == "Open Island Debug" }) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideControlCenter() {
        guard let window = NSApp.windows.first(where: { $0.title == "Open Island Debug" }) else {
            return
        }

        window.orderOut(nil)
    }

    func toggleSoundMuted() {
        isSoundMuted.toggle()
    }

    func approveFocusedPermission(_ approved: Bool) {
        guard let session = focusedSession else {
            return
        }

        send(
            .resolvePermission(sessionID: session.id, resolution: permissionResolution(for: approved)),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func answerFocusedQuestion(_ answer: String) {
        guard let session = focusedSession else {
            return
        }

        send(
            .answerQuestion(sessionID: session.id, response: QuestionPromptResponse(answer: answer)),
            userMessage: "Sending answer \"\(answer)\" for \(session.title)."
        )
    }

    func jumpToFocusedSession() {
        jump(to: focusedSession?.jumpTarget)
    }

    func jumpToSession(_ session: AgentSession) {
        guard let jumpTarget = session.jumpTarget,
              jumpTarget.terminalApp.lowercased() != "unknown" else {
            lastActionMessage = "Cannot jump: terminal app is unknown."
            return
        }
        jump(to: jumpTarget)
    }

    private func jump(to jumpTarget: JumpTarget?) {
        guard let jumpTarget else {
            lastActionMessage = "No jump target is available yet."
            return
        }

        let shouldDelayForDismissAnimation = isOverlayVisible
        let jumpAction = terminalJumpAction

        dismissOverlayForJump()
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            if shouldDelayForDismissAnimation {
                try? await Task.sleep(for: Self.jumpOverlayDismissLeadTime)
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try jumpAction(jumpTarget)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                self?.lastActionMessage = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.lastActionMessage = "Jump failed: \(error.localizedDescription)"
            }
        }
    }

    func approvePermission(for sessionID: String, approved: Bool) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        let resolution = permissionResolution(for: approved)
        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .resolvePermission(sessionID: session.id, resolution: resolution),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func approvePermission(for sessionID: String, action: ApprovalAction) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        let resolution: PermissionResolution
        let message: String

        switch action {
        case .deny:
            resolution = .deny(message: "Permission denied in Open Island.", interrupt: false)
            message = "Denying permission for \(session.title)."
        case .allowOnce:
            resolution = .allowOnce()
            message = "Approving permission for \(session.title)."
        case let .allowWithUpdates(updates):
            resolution = .allowOnce(updatedPermissions: updates)
            message = "Always allowing for \(session.title)."
        }

        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .resolvePermission(sessionID: session.id, resolution: resolution),
            userMessage: message
        )
    }

    func answerQuestion(for sessionID: String, answer: QuestionPromptResponse) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.answerQuestion(sessionID: session.id, response: answer)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .answerQuestion(sessionID: session.id, response: answer),
            userMessage: "Sending answer for \(session.title)."
        )
    }


    private func send(_ command: BridgeCommand, userMessage: String) {
        lastActionMessage = userMessage

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.bridgeClient.send(command)
            } catch {
                self.lastActionMessage = "Failed to send bridge command: \(error.localizedDescription)"
            }
        }
    }

    private func permissionResolution(for approved: Bool) -> PermissionResolution {
        if approved {
            return .allowOnce()
        }

        return .deny(message: "Permission denied in Open Island.", interrupt: false)
    }

    func applyTrackedEvent(
        _ event: AgentEvent,
        updateLastActionMessage: Bool = true,
        ingress: TrackedEventIngress = .bridge
    ) {
        // Snapshot whether this session was already completed before applying
        // the event. Used to suppress duplicate/stale completion notifications
        // (e.g. rollout watcher re-discovering an old completion on startup,
        // or producing a duplicate sessionCompleted that races with the bridge).
        let wasAlreadyCompleted: Bool = {
            guard case let .sessionCompleted(payload) = event else { return false }
            return state.session(id: payload.sessionID)?.phase == .completed
        }()

        // Guard: don't let rollout events downgrade a session from completed
        // back to running. The bridge's sessionCompleted is authoritative; the
        // rollout watcher may have read the JSONL before task_complete was
        // flushed, producing a stale activityUpdated(phase: .running).
        if ingress == .rollout,
           case let .activityUpdated(payload) = event,
           payload.phase == .running,
           state.session(id: payload.sessionID)?.phase == .completed {
            return
        }

        state.apply(event)
        reconcileIslandSurfaceAfterStateChange()
        if ingress == .bridge {
            monitoring.markSessionAttached(for: event)
            monitoring.markSessionProcessAlive(for: event)
        }
        synchronizeSelection()
        discovery.refreshCodexRolloutTracking()
        refreshOverlayPlacementIfVisible()
        discovery.scheduleCodexSessionPersistence()
        discovery.scheduleClaudeSessionPersistence()
        discovery.scheduleCursorSessionPersistence()

        if updateLastActionMessage {
            lastActionMessage = describe(event)
        }

        if let surface = IslandSurface.notificationSurface(for: event),
           !wasAlreadyCompleted,
           surface.sessionID.flatMap({ state.session(id: $0) }) != nil,
           (ingress == .bridge || !isResolvingInitialLiveSessions),
           notchStatus == .closed || notchOpenReason == .notification {
            presentNotificationSurface(surface)
        }
    }

    private func synchronizeSelection() {
        let surfacedIDs = Set(surfacedSessions.map(\.id))

        if let activeAction = state.activeActionableSession {
            selectedSessionID = activeAction.id
            return
        }

        guard let selectedSessionID,
              surfacedIDs.contains(selectedSessionID),
              state.session(id: selectedSessionID) != nil else {
            self.selectedSessionID = preferredVisibleSession?.id ?? surfacedSessions.first?.id ?? state.sessions.first?.id
            return
        }
    }

    /// Applies startup discovery results on the main thread after background I/O completes.
    private func applyStartupDiscoveryPayload(_ payload: SessionDiscoveryCoordinator.StartupDiscoveryPayload) {
        discovery.applyStartupDiscoveryPayload(payload)
        openClawAvailability = payload.openClawAvailability
        openClawTeamStoreCount = payload.openClawTeamStoreCount
        openClawRecentOwnerCount = payload.openClawRecentOwnerCount

        // Apply hooks binary URL and update the installed copy if the app ships a newer version.
        hooks.hooksBinaryURL = payload.hooksBinaryURL
        hooks.updateHooksBinaryIfNeeded()

        // Keep legacy hook status readable for debugging, but do not auto-install
        // upstream agent integrations in the Xteam-focused fork.
        if payload.hooksBinaryURL != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.hooks.refreshAllHookStatusAndWait()
            }
        }

        // Reconcile attachments and start monitoring (requires sessions to be loaded).
        monitoring.reconcileSessionAttachments()
        monitoring.startMonitoringIfNeeded()
    }

    private var preferredVisibleSession: AgentSession? {
        surfacedOpenClawSessions.first(where: { $0.phase.requiresAttention })
            ?? surfacedOpenClawSessions.first(where: { $0.phase == .running })
            ?? surfacedOpenClawSessions.first
    }


    private var sessionBuckets: (primary: [AgentSession], overflow: [AgentSession]) {
        if let cached = _cachedSessionBuckets {
            return cached
        }
        let result = computeSessionBuckets()
        _cachedSessionBuckets = result
        return result
    }

    private func computeSessionBuckets() -> (primary: [AgentSession], overflow: [AgentSession]) {
        let now = Date.now
        let rankedSessions = state.sessions.sorted { lhs, rhs in
            let lhsScore = sessionSortScore(for: lhs, now: now)
            let rhsScore = sessionSortScore(for: rhs, now: now)

            if lhsScore == rhsScore {
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }

                return lhs.islandActivityDate > rhs.islandActivityDate
            }

            return lhsScore > rhsScore
        }

        var primary: [AgentSession] = []
        var claimedLiveAttachmentKeys: Set<String> = []

        for session in rankedSessions where session.isVisibleInIsland {
            guard !session.isSubagentSession else { continue }

            if let liveAttachmentKey = monitoring.liveAttachmentKey(for: session) {
                guard claimedLiveAttachmentKeys.insert(liveAttachmentKey).inserted else {
                    continue
                }
            }

            primary.append(session)
        }

        let primaryIDs = Set(primary.map(\.id))
        let overflow = rankedSessions.filter { !primaryIDs.contains($0.id) && !$0.isSubagentSession }
        return (primary, overflow)
    }

    func isSupportedProductSession(_ session: AgentSession) -> Bool {
        if session.tool == .openClaw {
            return true
        }

        return normalizedOwnerDisplayName(from: session.ownerDisplayName) == "Hermes"
    }

    func displayOwner(for session: AgentSession) -> String? {
        if let explicitOwner = normalizedOwnerDisplayName(from: session.ownerDisplayName) {
            return explicitOwner
        }

        return Self.defaultOwnerDisplayNamesByTool[session.tool]
    }

    func displayProjectTag(for session: AgentSession) -> String? {
        if let explicitProjectTag = normalizedProjectTag(from: session.projectTag) {
            return explicitProjectTag
        }

        let candidateValues = [
            session.jumpTarget?.workspaceName,
            session.jumpTarget?.workingDirectory,
            session.trackingTranscriptPath,
            session.title,
        ]

        if candidateValues.contains(where: matchesOpenVibeIslandProject) {
            return "Open Vibe Island"
        }

        if let workspaceName = normalizedProjectTag(from: session.jumpTarget?.workspaceName) {
            return workspaceName
        }

        if let workingDirectory = session.jumpTarget?.workingDirectory,
           let directoryName = normalizedProjectTag(from: URL(fileURLWithPath: workingDirectory).lastPathComponent) {
            return directoryName
        }

        if let transcriptPath = session.trackingTranscriptPath,
           let parentName = normalizedProjectTag(from: URL(fileURLWithPath: transcriptPath).deletingLastPathComponent().lastPathComponent) {
            return parentName
        }

        return nil
    }

    func displayOwnerShortLabel(for session: AgentSession) -> String? {
        if let explicitShortLabel = normalizedInlineText(session.ownerShortLabel) {
            return explicitShortLabel.uppercased()
        }

        return identity(for: session)?.shortLabel
    }

    func identity(for session: AgentSession) -> AgentIdentity? {
        if let explicitOwner = normalizedOwnerDisplayName(from: session.ownerDisplayName),
           let identity = Self.canonicalAgentIdentities[explicitOwner.lowercased()] {
            return identity
        }

        if let defaultOwner = Self.defaultOwnerDisplayNamesByTool[session.tool],
           let identity = Self.canonicalAgentIdentities[defaultOwner.lowercased()] {
            return identity
        }

        return nil
    }

    func displayBlockedState(for session: AgentSession) -> Bool {
        session.isBlocked || session.phase.requiresAttention || displayBlockerSummary(for: session) != nil
    }

    func displayPriority(for session: AgentSession) -> SessionPriority? {
        if let explicitPriority = session.priority {
            return explicitPriority
        }

        if session.phase == .waitingForApproval {
            return .high
        }

        if session.phase == .waitingForAnswer || session.isBlocked {
            return .high
        }

        return nil
    }

    func displayBlockerSummary(for session: AgentSession) -> String? {
        if let blockerSummary = normalizedInlineText(session.blockerSummary) {
            return blockerSummary
        }

        switch session.phase {
        case .waitingForApproval:
            return normalizedInlineText(session.permissionRequest?.summary)
                ?? normalizedInlineText(session.currentCommandPreviewText)
                ?? "Waiting for approval"
        case .waitingForAnswer:
            return normalizedInlineText(session.questionPrompt?.title)
                ?? normalizedInlineText(session.questionPrompt?.questions.first?.question)
                ?? "Waiting for answer"
        case .running, .completed:
            return nil
        }
    }

    private func sessionSortScore(for session: AgentSession, now: Date) -> Int {
        var score = 0

        let presence = session.islandPresence(at: now)
        let isBlocked = displayBlockedState(for: session)
        let priority = displayPriority(for: session)
        let owner = displayOwner(for: session)

        if session.isProcessAlive {
            score += presence == .inactive ? 3_000 : 12_000
        } else if session.isDemoSession || session.phase.requiresAttention {
            score += 6_000
        }

        if session.currentToolName?.isEmpty == false {
            score += 2_000
        }

        if session.jumpTarget != nil {
            score += 1_500
        }

        if session.tool == .openClaw {
            score += 11_000
        }

        switch session.phase {
        case .waitingForApproval:
            score += 40_000
        case .waitingForAnswer:
            score += 34_000
        case .running:
            score += 8_000
        case .completed:
            score += 500
        }

        if isBlocked {
            score += 24_000
        }

        switch priority {
        case .critical?:
            score += 20_000
        case .high?:
            score += 13_000
        case .normal?:
            score += 2_500
        case .low?:
            score -= 1_000
        case nil:
            break
        }

        if owner == Self.prioritizedOwnerDisplayName {
            score += 6_000
        }

        switch presence {
        case .running:
            score += 3_000
        case .active:
            score += 1_500
        case .inactive:
            score -= 500
        }

        let age = now.timeIntervalSince(session.islandActivityDate)
        switch age {
        case ..<120:
            score += 500
        case ..<900:
            score += 250
        case ..<3_600:
            score += 120
        case ..<21_600:
            score += 40
        default:
            break
        }

        return score
    }

    private func spotlightScore(for session: AgentSession) -> Int {
        var score = sessionSortScore(for: session, now: .now)
        let owner = displayOwner(for: session)

        switch session.phase {
        case .waitingForApproval:
            score += 120_000
        case .waitingForAnswer:
            score += 85_000
        case .running:
            score += 40_000
        case .completed:
            score += 8_000
        }

        if displayBlockedState(for: session) {
            score += 95_000
        }

        if session.spotlightHandoffLabel != nil {
            score += 55_000
        }

        if let priority = displayPriority(for: session) {
            switch priority {
            case .critical:
                score += 50_000
            case .high:
                score += 28_000
            case .normal:
                score += 8_000
            case .low:
                break
            }
        }

        if owner == Self.prioritizedOwnerDisplayName {
            switch session.phase {
            case .running:
                score += 22_000
            case .waitingForAnswer, .waitingForApproval:
                score += 12_000
            case .completed:
                score += 2_000
            }
        }

        if session.phase != .completed {
            if session.spotlightPromptText?.isEmpty == false {
                score += 9_000
            }

            if session.spotlightHeadlinePromptText?.isEmpty == false {
                score += 4_000
            }
        }

        return score
    }

    private func normalizedOwnerDisplayName(from rawValue: String?) -> String? {
        guard let normalized = normalizedLookupKey(from: rawValue) else {
            return nil
        }

        return Self.canonicalOwnerDisplayNames[normalized]
            ?? normalizedInlineText(rawValue)
    }

    private func normalizedProjectTag(from rawValue: String?) -> String? {
        guard let text = normalizedInlineText(rawValue) else {
            return nil
        }

        if matchesOpenVibeIslandProject(text) {
            return "Open Vibe Island"
        }

        if ["workspace", "unknown", "untitled"].contains(text.lowercased()) {
            return nil
        }

        return prettifiedTag(text)
    }

    private func matchesOpenVibeIslandProject(_ rawValue: String?) -> Bool {
        guard let normalized = normalizedLookupKey(from: rawValue) else {
            return false
        }

        return normalized.contains("open vibe island")
            || normalized.contains("open-vibe-island")
            || normalized.contains("open island")
            || normalized.contains("open-island")
    }

    private func prettifiedTag(_ value: String) -> String {
        let replaced = value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let collapsed = replaced.split(whereSeparator: \.isWhitespace).map(String.init).joined(separator: " ")
        guard !collapsed.isEmpty else {
            return value
        }

        return collapsed
            .split(separator: " ")
            .map { token in
                if token.count <= 3 {
                    return token.uppercased()
                }

                return token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    private func normalizedLookupKey(from rawValue: String?) -> String? {
        guard let text = normalizedInlineText(rawValue) else {
            return nil
        }

        return text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private func normalizedInlineText(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let cleaned = rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    private func describe(_ event: AgentEvent) -> String {
        switch event {
        case let .sessionStarted(payload):
            return "Session started: \(payload.title)"
        case let .activityUpdated(payload):
            return payload.summary
        case let .permissionRequested(payload):
            return payload.request.summary
        case let .questionAsked(payload):
            return payload.prompt.title
        case let .sessionCompleted(payload):
            return payload.summary
        case let .jumpTargetUpdated(payload):
            return "Jump target updated to \(payload.jumpTarget.terminalApp)."
        case let .sessionMetadataUpdated(payload):
            if let currentTool = payload.codexMetadata.currentTool {
                return "Codex is running \(currentTool)."
            }

            return payload.codexMetadata.lastAssistantMessage ?? "Codex session metadata updated."
        case let .claudeSessionMetadataUpdated(payload):
            if let currentTool = payload.claudeMetadata.currentTool {
                return "Claude is running \(currentTool)."
            }

            return payload.claudeMetadata.lastAssistantMessage ?? "Claude session metadata updated."
        case let .openCodeSessionMetadataUpdated(payload):
            if let currentTool = payload.openCodeMetadata.currentTool {
                return "OpenCode is running \(currentTool)."
            }

            return payload.openCodeMetadata.lastAssistantMessage ?? "OpenCode session metadata updated."
        case let .cursorSessionMetadataUpdated(payload):
            if let currentTool = payload.cursorMetadata.currentTool {
                return "Cursor is running \(currentTool)."
            }

            return payload.cursorMetadata.lastAssistantMessage ?? "Cursor session metadata updated."
        case let .actionableStateResolved(payload):
            return "Actionable state resolved for session \(payload.sessionID)."
        }
    }

}
