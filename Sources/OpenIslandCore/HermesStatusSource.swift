import Foundation

/// Hermes status-source integration for Island.
///
/// Reads from `~/.hermes/` as the source of truth:
///   1. `gateway_state.json`  — gateway health, PID, platform connectivity
///   2. `channel_directory.json` — active channel inventory per platform
///   3. `state.db`           — recent session inventory (SQLite)
///
/// Logs are debug-only and are NOT used as a primary state source.
public struct HermesStatusSource {
    public enum Availability: Sendable {
        case detected
        case unavailable
        case unreadable
    }

    /// Gateway health snapshot surfaced as a system-status session.
    public struct GatewayHealth: Sendable {
        public var pid: Int
        public var isRunning: Bool
        public var activeAgents: Int
        public var updatedAt: Date
        public var platformSummary: String
        public var discordConnected: Bool
        public var feishuConnected: Bool
    }

    /// One channel entry from channel_directory.json.
    public struct ChannelEntry: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var platform: String
        public var type: String  // channel, dm, thread
        public var guild: String?

        public init(id: String, name: String, platform: String, type: String, guild: String?) {
            self.id = id
            self.name = name
            self.platform = platform
            self.type = type
            self.guild = guild
        }
    }

    public struct Result: Sendable {
        public var sessions: [AgentSession]
        public var gatewayHealth: GatewayHealth?
        public var channels: [ChannelEntry]
        public var availability: Availability
        public var statusMessage: String?
    }

    // MARK: - Path resolution

    private static let hermesHome: URL = {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes")
    }()

    private static var gatewayStateURL: URL {
        hermesHome.appendingPathComponent("gateway_state.json")
    }

    private static var channelDirectoryURL: URL {
        hermesHome.appendingPathComponent("channel_directory.json")
    }

    private static var stateDBURL: URL {
        hermesHome.appendingPathComponent("state.db")
    }

    // MARK: - Public API

    public init() {}

    /// Discover Hermes status: gateway health, channels, and recent sessions.
    public func discover() -> Result {
        var sessions: [AgentSession] = []
        var gatewayHealth: GatewayHealth?
        var channels: [ChannelEntry] = []

        // 1. Gateway health from gateway_state.json
        if let health = parseGatewayState() {
            gatewayHealth = health
            // Surface gateway health as a system-status session
            sessions.append(makeGatewaySession(health: health))
        }

        // 2. Channel mapping from channel_directory.json
        channels = parseChannelDirectory()

        // 3. Recent session inventory from state.db
        let dbSessions = parseStateDB()
        sessions.append(contentsOf: dbSessions)

        // Availability determination
        let availability: Availability
        let statusMessage: String?

        if gatewayHealth != nil || !dbSessions.isEmpty {
            availability = .detected
            statusMessage = "Hermes gateway is \(gatewayHealth?.isRunning == true ? "running" : "stopped")."
        } else if FileManager.default.fileExists(atPath: Self.gatewayStateURL.path) {
            availability = .unreadable
            statusMessage = "Hermes state files found but could not be parsed."
        } else {
            availability = .unavailable
            statusMessage = "Hermes gateway not detected."
        }

        return Result(
            sessions: sessions,
            gatewayHealth: gatewayHealth,
            channels: channels,
            availability: availability,
            statusMessage: statusMessage
        )
    }

    // MARK: - Gateway state parser

    private func parseGatewayState() -> GatewayHealth? {
        guard let data = try? Data(contentsOf: Self.gatewayStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let pid = json["pid"] as? Int else { return nil }

        let state = json["gateway_state"] as? String ?? "unknown"
        let activeAgents = json["active_agents"] as? Int ?? 0

        let updatedAt: Date
        if let updatedAtString = json["updated_at"] as? String {
            updatedAt = ISO8601DateFormatter().date(from: updatedAtString) ?? Date()
        } else {
            updatedAt = Date()
        }

        let platforms = json["platforms"] as? [String: Any] ?? [:]
        let discordState = platforms["discord"] as? [String: Any]
        let feishuState = platforms["feishu"] as? [String: Any]

        let discordConnected = discordState?["state"] as? String == "connected"
        let feishuConnected = feishuState?["state"] as? String == "connected"

        let platformSummary = buildPlatformSummary(
            discordConnected: discordConnected,
            feishuConnected: feishuConnected,
            otherPlatforms: platforms.filter { $0.key != "discord" && $0.key != "feishu" }
        )

        return GatewayHealth(
            pid: pid,
            isRunning: state == "running",
            activeAgents: activeAgents,
            updatedAt: updatedAt,
            platformSummary: platformSummary,
            discordConnected: discordConnected,
            feishuConnected: feishuConnected
        )
    }

    private func buildPlatformSummary(
        discordConnected: Bool,
        feishuConnected: Bool,
        otherPlatforms: [String: Any]
    ) -> String {
        var parts: [String] = []
        if discordConnected { parts.append("Discord ✓") }
        if feishuConnected { parts.append("Feishu ✓") }
        for (key, value) in otherPlatforms {
            if let state = (value as? [String: Any])?["state"] as? String, state == "connected" {
                parts.append("\(key.capitalized) ✓")
            }
        }
        return parts.isEmpty ? "No platforms connected" : parts.joined(separator: " · ")
    }

    // MARK: - Channel directory parser

    private func parseChannelDirectory() -> [ChannelEntry] {
        guard let data = try? Data(contentsOf: Self.channelDirectoryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = json["platforms"] as? [String: [Any]] else {
            return []
        }

        var entries: [ChannelEntry] = []
        for (platformName, channelList) in platforms {
            guard let channels = channelList as? [[String: Any]] else { continue }
            for channel in channels {
                guard let id = channel["id"] as? String,
                      let name = channel["name"] as? String,
                      let type = channel["type"] as? String else { continue }
                let guild = channel["guild"] as? String
                entries.append(ChannelEntry(
                    id: id,
                    name: name,
                    platform: platformName,
                    type: type,
                    guild: guild
                ))
            }
        }
        return entries
    }

    // MARK: - State DB parser

    private func parseStateDB() -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: Self.stateDBURL.path) else {
            return []
        }

        let cutoff = Date().addingTimeInterval(-36 * 60 * 60)
        let cutoffEpoch = cutoff.timeIntervalSince1970

        let query = """
        SELECT id, source, model, started_at, ended_at, end_reason, message_count, title
        FROM sessions
        WHERE started_at >= \(cutoffEpoch)
        ORDER BY started_at DESC
        LIMIT 20;
        """

        guard let output = runSQLite(query: query),
              !output.isEmpty else {
            return []
        }

        return parseSessionRows(output)
    }

    private func runSQLite(query: String) -> [String]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [Self.stateDBURL.path, query]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        } catch {
            return nil
        }
    }

    private func parseSessionRows(_ rows: [String]) -> [AgentSession] {
        rows.compactMap { row -> AgentSession? in
            let cols = row.components(separatedBy: "|")
            guard cols.count >= 7 else { return nil }

            let sessionID = cols[0]
            let source = cols[1]
            _ = cols[2]  // model (reserved for future use)
            let startedAtEpoch = Double(cols[3]) ?? 0
            let endedAtEpoch = cols[4].isEmpty ? nil : Double(cols[4])
            let endReason = cols[5]
            let messageCount = Int(cols[6]) ?? 0
            let title = cols.count > 7 ? cols[7] : nil

            let startedAt = Date(timeIntervalSince1970: startedAtEpoch)
            let endedAt = endedAtEpoch.map { Date(timeIntervalSince1970: $0) }

            let phase: SessionPhase
            if endedAt != nil || endReason == "cron_complete" || endReason == "session_reset" {
                phase = .completed
            } else {
                phase = .running
            }

            let summary: String
            if !endReason.isEmpty {
                summary = "Hermes session · \(messageCount) messages"
            } else {
                summary = "Hermes session · \(messageCount) messages · Active"
            }

            return AgentSession(
                id: "hermes:\(sessionID)",
                title: title ?? "Hermes \(source.capitalized) session",
                tool: .openClaw,
                origin: .live,
                attachmentState: endedAt != nil ? .stale : .attached,
                phase: phase,
                summary: summary,
                updatedAt: endedAt ?? startedAt,
                ownerDisplayName: "Hermes",
                teamRole: "Xteam",
                projectTag: source.capitalized
            )
        }
    }

    // MARK: - Session builders

    private func makeGatewaySession(health: GatewayHealth) -> AgentSession {
        let title: String
        let summary: String
        let phase: SessionPhase
        let attachmentState: SessionAttachmentState

        if health.isRunning {
            title = "Hermes Gateway"
            summary = "Gateway PID \(health.pid) · \(health.platformSummary)"
            phase = .running
            attachmentState = .attached
        } else {
            title = "Hermes Gateway (stopped)"
            summary = "Gateway was running as PID \(health.pid)"
            phase = .completed
            attachmentState = .stale
        }

        return AgentSession(
            id: "hermes:gateway",
            title: title,
            tool: .openClaw,
            origin: .live,
            attachmentState: attachmentState,
            phase: phase,
            summary: summary,
            updatedAt: health.updatedAt,
            ownerDisplayName: "Hermes",
            teamRole: "Xteam",
            projectTag: "Gateway",
            priority: health.isRunning ? .normal : .low,
            isBlocked: !health.isRunning,
            blockerSummary: health.isRunning ? nil : "Gateway process is not running",
            avatarPresetKey: "halo",
            animationProfileKey: "glow"
        )
    }
}
