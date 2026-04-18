import Foundation

/// Authoritative read-model adapter for OpenClaw sessions and tasks.
///
/// Replaces fragile terminal-attachment heuristics (AppleScript polling of
/// Ghostty/Terminal/iTerm) as the primary truth source for OpenClaw session
/// existence, phase, summary, and priority.
///
/// Data flows in:
///   1. Seeded once at startup from `OpenClawDiscovery.discover()` via
///      `seedFromStartupPayload()` — fast, no AppleScript required.
///   2. Kept current via `applyBridgeEvent()` — driven by the bridge's
///      hook-event stream, which is already the authoritative signal.
///
/// Data flows out via `surfacedSessions`, `session(id:)`, `openClawSessionCount`,
/// and `activityStateSummary` — queried by AppModel when building the
/// session list and computing spotlight/attention state.
///
/// ## Design constraints
///
/// - Stored in `OpenIslandCore` so it can be shared without pulling UI
///   dependencies into the core model layer.
/// - `@unchecked Sendable`: the isolate is the `@MainActor` AppModel; all
///   writes happen on that isolate. Reads on the main actor are safe.
/// - Exposes a plain `SessionState` snapshot so callers can query without
///   async overhead; the snapshot is replaced atomically on each update.
///
public final class OpenClawStateAdapter: @unchecked Sendable {

    // MARK: - Snapshot

    /// Atomically-replaced snapshot of OpenClaw sessions.
    /// Replaced (not mutated) on each update so concurrent readers see
    /// a consistent, immutable view.
    private var _snapshot: SessionState

    /// Lock for inter-isolate writes. On Swift 5.10+ the runtime enforces
    /// that all access to Sendable classes happens on the same isolate;
    /// we use a simple lock here only for thread-safety during init before
    /// the main-actor assumption is established.
    private let lock = NSLock()

    // MARK: - Init

    public init() {
        _snapshot = SessionState()
    }

    // MARK: - Seed (startup path)

    /// Seeds the adapter from the startup discovery payload.
    /// Called once at app startup on a background thread; safe to call
    /// before @MainActor isolation is established.
    public func seedFromStartupPayload(_ payload: OpenClawDiscoveryPayload) {
        let sessions = payload.sessions
        lock.lock()
        _snapshot = SessionState(sessions: sessions)
        lock.unlock()
    }

    // MARK: - Update (bridge-event path)

    /// Applies a bridge event that may affect OpenClaw session state.
    /// Returns true if the OpenClaw snapshot changed as a result.
    @discardableResult
    public func applyBridgeEvent(_ event: AgentEvent) -> Bool {
        // Only process events that carry an OpenClaw session ID.
        guard sessionID(from: event)?.hasPrefix("openclaw:") == true else {
            return false
        }

        lock.lock()
        var snapshot = _snapshot
        snapshot.apply(event)
        let changed = snapshot != _snapshot
        if changed {
            _snapshot = snapshot
        }
        lock.unlock()
        return changed
    }

    /// Applies a batch of events (e.g. replayed on reconnect).
    public func applyBridgeEvents(_ events: [AgentEvent]) {
        lock.lock()
        var snapshot = _snapshot
        for event in events {
            snapshot.apply(event)
        }
        _snapshot = snapshot
        lock.unlock()
    }

    // MARK: - Read (main-actor path)

    /// Returns a stable copy of the current snapshot.
    /// The copy is cheap (struct with dictionary reference copy).
    public var snapshot: SessionState {
        lock.lock()
        let result = _snapshot
        lock.unlock()
        return result
    }

    /// All OpenClaw sessions in recency order.
    public var sessions: [AgentSession] {
        snapshot.sessions
    }

    /// OpenClaw sessions visible in the island (non-completed + attention).
    public var surfacedSessions: [AgentSession] {
        snapshot.sessions.filter { $0.isVisibleInIsland }
    }

    /// OpenClaw sessions that need user attention.
    public var attentionSessions: [AgentSession] {
        surfacedSessions.filter { $0.phase.requiresAttention }
    }

    /// OpenClaw sessions actively running.
    public var activeSessions: [AgentSession] {
        surfacedSessions.filter { $0.phase == .running }
    }

    /// The spotlight session: highest-priority attention or active session.
    /// Uses `phase` rather than the presentation-layer `activityState(at:)` so this
    /// stays in OpenIslandCore without pulling UI-layer presentation logic into core.
    public var spotlightSession: AgentSession? {
        surfacedSessions
            .filter { $0.phase.requiresAttention }
            .max(by: { $0.updatedAt < $1.updatedAt })
        ?? surfacedSessions
            .filter { $0.phase == .running }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// Number of surfaced OpenClaw sessions.
    public var surfacedCount: Int { surfacedSessions.count }

    /// Number of OpenClaw sessions needing attention.
    public var attentionCount: Int { attentionSessions.count }

    /// Number of OpenClaw sessions actively running.
    public var activeCount: Int { activeSessions.count }

    /// Whether any OpenClaw sessions are present.
    public var hasAnySession: Bool { !snapshot.sessions.isEmpty }

    /// Whether any OpenClaw sessions need attention.
    public var hasAttention: Bool { attentionCount > 0 }

    /// Returns a specific session by ID, or nil.
    public func session(id: String) -> AgentSession? {
        snapshot.session(id: id)
    }

    /// Human-readable summary of current OpenClaw activity.
    public var activitySummary: String {
        let a = attentionCount
        let r = activeCount
        if a > 0 {
            return "\(a) needing attention"
        }
        if r > 0 {
            return "\(r) active"
        }
        let total = snapshot.sessions.count
        if total > 0 {
            return "\(total) session\(total == 1 ? "" : "s")"
        }
        return "No OpenClaw sessions"
    }

    // MARK: - Helpers

    private func sessionID(from event: AgentEvent) -> String? {
        switch event {
        case let .sessionStarted(s):         return s.sessionID
        case let .activityUpdated(s):        return s.sessionID
        case let .permissionRequested(s):     return s.sessionID
        case let .questionAsked(s):          return s.sessionID
        case let .sessionCompleted(s):       return s.sessionID
        case let .jumpTargetUpdated(s):      return s.sessionID
        case let .sessionMetadataUpdated(s):  return s.sessionID
        case let .claudeSessionMetadataUpdated(s): return s.sessionID
        case let .openCodeSessionMetadataUpdated(s): return s.sessionID
        case let .cursorSessionMetadataUpdated(s):  return s.sessionID
        case let .actionableStateResolved(s): return s.sessionID
        }
    }
}

// MARK: - Startup payload passthrough

/// Lightweight summary of OpenClaw startup discovery results.
/// Passed from SessionDiscoveryCoordinator to OpenClawStateAdapter at startup.
public struct OpenClawDiscoveryPayload: Sendable {
    public let sessions: [AgentSession]

    public init(sessions: [AgentSession]) {
        self.sessions = sessions
    }
}
