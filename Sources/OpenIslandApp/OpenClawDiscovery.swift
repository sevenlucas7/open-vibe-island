import Foundation
import OpenIslandCore

struct OpenClawDiscovery {
    enum Availability: Sendable {
        case detected
        case unavailable
        case unreadable
    }

    struct Result: Sendable {
        var sessions: [AgentSession]
        var statusMessage: String?
        var availability: Availability
        var teamStoreCount: Int
        var recentOwnerCount: Int
    }

    struct CommandOutput: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var executableFound: Bool
    }

    typealias CommandRunner = @Sendable ([String]) -> CommandOutput

    private struct OwnerDescriptor: Sendable {
        var displayName: String
        var teamRole: String?
        var agentIDs: [String]
        var lookupTokens: [String]
    }

    private struct RawSession: Sendable {
        var key: String
        var sessionID: String
        var updatedAt: Date
        var ageMs: Double?
        var agentID: String?
        var kind: String?
        var abortedLastRun: Bool
    }

    private struct RawTask: Sendable {
        var id: String
        var ownerName: String?
        var agentID: String?
        var sessionKey: String?
        var status: String?
        var summary: String?
        var projectTag: String?
        var priority: SessionPriority?
        var blockerSummary: String?
    }

    private static let recentSessionWindow: TimeInterval = 36 * 60 * 60
    private static let runningSessionWindow: TimeInterval = 30 * 60
    private static let knownOwners: [OwnerDescriptor] = [
        OwnerDescriptor(
            displayName: "Seven",
            teamRole: "Xteam",
            agentIDs: ["main", "claw_seven"],
            lookupTokens: ["seven", "claw seven", "main"]
        ),
        OwnerDescriptor(
            displayName: "Luvian",
            teamRole: "Xteam",
            agentIDs: ["claw_luvian", "luvian"],
            lookupTokens: ["luvian", "claw luvian", "luvi"]
        ),
        OwnerDescriptor(
            displayName: "Fanshu",
            teamRole: "Xteam",
            agentIDs: ["claw_fanshu", "fanshu"],
            lookupTokens: ["fanshu", "claw fanshu"]
        ),
        OwnerDescriptor(
            displayName: "Pipi",
            teamRole: "Xteam",
            agentIDs: ["claw_pipi", "pipi"],
            lookupTokens: ["pipi", "claw pipi"]
        ),
        OwnerDescriptor(
            displayName: "Momo",
            teamRole: "Xteam",
            agentIDs: ["claw_momo", "momo"],
            lookupTokens: ["momo", "claw momo"]
        ),
    ]

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = Self.defaultCommandRunner(arguments:)) {
        self.commandRunner = commandRunner
    }

    func discover() -> Result {
        let sessionsOutput = commandRunner(["sessions", "--all-agents", "--json"])
        guard sessionsOutput.executableFound else {
            return Result(
                sessions: [],
                statusMessage: "OpenClaw CLI not found. Xteam session visibility is unavailable."
                ,availability: .unavailable,
                teamStoreCount: 0,
                recentOwnerCount: 0
            )
        }

        guard let sessionsRoot = Self.extractJSONObject(from: sessionsOutput),
              let sessionRecords = Self.arrayValue(for: "sessions", in: sessionsRoot) else {
            return Result(
                sessions: [],
                statusMessage: "OpenClaw CLI responded, but session JSON could not be parsed."
                ,availability: .unreadable,
                teamStoreCount: 0,
                recentOwnerCount: 0
            )
        }

        let stores = Self.arrayValue(for: "stores", in: sessionsRoot) ?? []
        let rawSessions = sessionRecords.compactMap(Self.parseSession)

        let tasksOutput = commandRunner(["tasks", "list", "--json"])
        let tasksRoot = tasksOutput.executableFound ? Self.extractJSONObject(from: tasksOutput) : nil
        let rawTasks = (tasksRoot.flatMap { Self.arrayValue(for: "tasks", in: $0) } ?? [])
            .compactMap(Self.parseTask)

        let discoveredSessions = buildRepresentativeSessions(
            from: rawSessions,
            tasks: rawTasks,
            stores: stores,
            now: .now
        )
        let recentOwnerCount = discoveredSessions.filter(Self.isRecentOpenClawRow).count

        let statusMessage: String
        if recentOwnerCount > 0 {
            statusMessage = "Loaded \(discoveredSessions.count) Xteam OpenClaw visibility row(s) from local CLI."
        } else {
            statusMessage = "OpenClaw CLI is available, but no recent Xteam sessions were found."
        }

        return Result(
            sessions: discoveredSessions,
            statusMessage: statusMessage,
            availability: .detected,
            teamStoreCount: stores.count,
            recentOwnerCount: recentOwnerCount
        )
    }

    private func buildRepresentativeSessions(
        from rawSessions: [RawSession],
        tasks rawTasks: [RawTask],
        stores: [[String: Any]],
        now: Date
    ) -> [AgentSession] {
        let recentCutoff = now.addingTimeInterval(-Self.recentSessionWindow)
        let recentSessions = rawSessions.filter { $0.updatedAt >= recentCutoff }

        var sessionsByOwner: [String: [RawSession]] = [:]
        for session in recentSessions {
            guard let owner = Self.ownerName(forAgentID: session.agentID, key: session.key) else {
                continue
            }

            sessionsByOwner[owner, default: []].append(session)
        }

        var tasksByOwner: [String: [RawTask]] = [:]
        for task in rawTasks {
            let owner = task.ownerName
                ?? Self.ownerName(forAgentID: task.agentID, key: task.sessionKey)
            guard let owner else {
                continue
            }

            tasksByOwner[owner, default: []].append(task)
        }

        let knownStoreOwners = stores.compactMap {
            Self.ownerName(
                forAgentID: Self.stringValue(forKeys: ["agentId"], in: $0),
                key: Self.stringValue(forKeys: ["path"], in: $0)
            )
        }
        let ownerNames = Set(Self.knownOwners.map(\.displayName))
            .union(knownStoreOwners)
            .union(sessionsByOwner.keys)
            .union(tasksByOwner.keys)

        let orderedOwners = Self.knownOwners.filter { ownerNames.contains($0.displayName) }

        return orderedOwners.map { owner in
            let representativeSession = sessionsByOwner[owner.displayName]?
                .max(by: { lhs, rhs in
                    Self.sessionSortWeight(lhs: lhs, rhs: rhs)
                })
            let representativeTask = selectRepresentativeTask(
                for: representativeSession,
                from: tasksByOwner[owner.displayName] ?? []
            )

            if let representativeSession {
                return makeAgentSession(
                    owner: owner,
                    session: representativeSession,
                    task: representativeTask,
                    now: now
                )
            }

            return makePlaceholderSession(
                owner: owner,
                task: representativeTask,
                now: now
            )
        }
    }

    private func selectRepresentativeTask(
        for session: RawSession?,
        from tasks: [RawTask]
    ) -> RawTask? {
        if let session {
            let exactMatch = tasks.filter {
                $0.sessionKey == session.key
                    || $0.sessionKey == session.sessionID
            }
            if let matched = exactMatch.max(by: { lhs, rhs in
                Self.taskSortWeight(lhs: lhs, rhs: rhs)
            }) {
                return matched
            }
        }

        return tasks.max(by: { lhs, rhs in
            Self.taskSortWeight(lhs: lhs, rhs: rhs)
        })
    }

    private func makeAgentSession(
        owner: OwnerDescriptor,
        session: RawSession,
        task: RawTask?,
        now: Date
    ) -> AgentSession {
        let taskStatus = Self.classifyTaskStatus(task?.status, summary: task?.summary, blocker: task?.blockerSummary)
        let isBlocked = taskStatus == .blocked || session.abortedLastRun
        let blockerSummary = Self.normalizedInlineText(task?.blockerSummary)
            ?? (session.abortedLastRun ? "Last OpenClaw run aborted." : nil)
        let projectTag = inferredProjectTag(sessionKey: session.key, taskProjectTag: task?.projectTag)
        let phase = inferredPhase(
            taskStatus: taskStatus,
            isBlocked: isBlocked,
            updatedAt: session.updatedAt,
            now: now
        )
        let priority = inferredPriority(
            explicit: task?.priority,
            taskStatus: taskStatus,
            isBlocked: isBlocked
        )
        let headline = inferredHeadline(
            taskSummary: task?.summary,
            sessionKey: session.key,
            sessionKind: session.kind,
            projectTag: projectTag
        )
        let summary = Self.normalizedInlineText(task?.summary)
            ?? inferredSummary(sessionKey: session.key, sessionKind: session.kind, projectTag: projectTag)

        return AgentSession(
            id: "openclaw:\(owner.displayName.lowercased())",
            title: headline,
            tool: .openClaw,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: summary,
            updatedAt: session.updatedAt,
            ownerDisplayName: owner.displayName,
            teamRole: owner.teamRole,
            projectTag: projectTag,
            priority: priority,
            isBlocked: isBlocked,
            blockerSummary: blockerSummary
        )
    }

    private func makePlaceholderSession(
        owner: OwnerDescriptor,
        task: RawTask?,
        now: Date
    ) -> AgentSession {
        let taskStatus = Self.classifyTaskStatus(task?.status, summary: task?.summary, blocker: task?.blockerSummary)
        let isBlocked = taskStatus == .blocked
        let priority = inferredPriority(
            explicit: task?.priority,
            taskStatus: taskStatus,
            isBlocked: isBlocked
        )
        let projectTag = Self.normalizedInlineText(task?.projectTag)
        let blockerSummary = Self.normalizedInlineText(task?.blockerSummary)
        let phase: SessionPhase
        let title: String

        switch taskStatus {
        case .waitingForApproval:
            phase = .waitingForApproval
            title = Self.normalizedInlineText(task?.summary) ?? "Approval needed"
        case .waitingForAnswer:
            phase = .waitingForAnswer
            title = Self.normalizedInlineText(task?.summary) ?? "Waiting for answer"
        case .blocked:
            phase = .running
            title = Self.normalizedInlineText(task?.summary) ?? "Blocked without active session"
        case .running:
            phase = .running
            title = Self.normalizedInlineText(task?.summary) ?? "Task active without session context"
        case .completed, .unknown:
            phase = .completed
            title = "No recent OpenClaw session"
        }

        return AgentSession(
            id: "openclaw:\(owner.displayName.lowercased())",
            title: title,
            tool: .openClaw,
            origin: .live,
            attachmentState: .stale,
            phase: phase,
            summary: Self.normalizedInlineText(task?.summary) ?? "No recent OpenClaw session.",
            updatedAt: phase == .completed ? now.addingTimeInterval(-3_600) : now,
            ownerDisplayName: owner.displayName,
            teamRole: owner.teamRole,
            projectTag: projectTag,
            priority: priority,
            isBlocked: isBlocked,
            blockerSummary: blockerSummary
        )
    }

    private func inferredPhase(
        taskStatus: TaskStatus,
        isBlocked: Bool,
        updatedAt: Date,
        now: Date
    ) -> SessionPhase {
        switch taskStatus {
        case .waitingForApproval:
            return .waitingForApproval
        case .waitingForAnswer:
            return .waitingForAnswer
        case .running:
            return .running
        case .completed:
            return .completed
        case .blocked:
            return .running
        case .unknown:
            if isBlocked {
                return .running
            }

            if now.timeIntervalSince(updatedAt) <= Self.runningSessionWindow {
                return .running
            }

            return .completed
        }
    }

    private func inferredPriority(
        explicit: SessionPriority?,
        taskStatus: TaskStatus,
        isBlocked: Bool
    ) -> SessionPriority? {
        if let explicit {
            return explicit
        }

        if isBlocked {
            return .high
        }

        switch taskStatus {
        case .waitingForApproval, .waitingForAnswer:
            return .high
        case .running:
            return .normal
        case .completed, .unknown, .blocked:
            return nil
        }
    }

    private func inferredHeadline(
        taskSummary: String?,
        sessionKey: String,
        sessionKind: String?,
        projectTag: String?
    ) -> String {
        if let taskSummary = Self.normalizedInlineText(taskSummary) {
            return taskSummary
        }

        let normalizedKey = Self.normalizedLookupKey(from: sessionKey) ?? ""
        if normalizedKey.contains("discord") {
            return "Discord session active"
        }
        if normalizedKey.contains("feishu") {
            return "Feishu session active"
        }
        if normalizedKey.contains("subagent") {
            return "Subagent worktree active"
        }
        if normalizedKey.contains("cron") {
            return "Scheduled automation run"
        }
        if normalizedKey.contains("direct") {
            return "Direct session active"
        }
        if let projectTag {
            return projectTag
        }
        if let sessionKind = Self.normalizedInlineText(sessionKind) {
            return "\(sessionKind.capitalized) session"
        }

        return "OpenClaw session"
    }

    private func inferredSummary(
        sessionKey: String,
        sessionKind: String?,
        projectTag: String?
    ) -> String {
        if let projectTag {
            return "OpenClaw visibility via \(projectTag)."
        }

        let normalizedKey = Self.normalizedLookupKey(from: sessionKey) ?? ""
        if normalizedKey.contains("discord") {
            return "OpenClaw Discord session."
        }
        if normalizedKey.contains("feishu") {
            return "OpenClaw Feishu session."
        }
        if normalizedKey.contains("subagent") {
            return "OpenClaw subagent session."
        }
        if normalizedKey.contains("cron") {
            return "OpenClaw scheduled automation."
        }
        if normalizedKey.contains("direct") {
            return "OpenClaw direct session."
        }
        if let sessionKind = Self.normalizedInlineText(sessionKind) {
            return "OpenClaw \(sessionKind.lowercased()) session."
        }

        return "OpenClaw session."
    }

    private func inferredProjectTag(
        sessionKey: String,
        taskProjectTag: String?
    ) -> String? {
        if let taskProjectTag = Self.normalizedInlineText(taskProjectTag) {
            return taskProjectTag
        }

        let normalizedKey = Self.normalizedLookupKey(from: sessionKey) ?? ""
        if normalizedKey.contains("open vibe island") {
            return "Open Vibe Island"
        }
        if normalizedKey.contains("discord") {
            return "Discord"
        }
        if normalizedKey.contains("feishu") {
            return "Feishu"
        }
        if normalizedKey.contains("subagent") {
            return "Subagent"
        }
        if normalizedKey.contains("cron") {
            return "Scheduled"
        }
        if normalizedKey.contains("direct") {
            return "Direct"
        }

        return nil
    }

    private enum TaskStatus {
        case running
        case waitingForApproval
        case waitingForAnswer
        case blocked
        case completed
        case unknown
    }

    private static func classifyTaskStatus(
        _ rawStatus: String?,
        summary: String?,
        blocker: String?
    ) -> TaskStatus {
        let normalizedStatus = normalizedLookupKey(from: rawStatus) ?? ""
        let normalizedSummary = normalizedLookupKey(from: summary) ?? ""
        let normalizedBlocker = normalizedLookupKey(from: blocker) ?? ""
        let haystack = [normalizedStatus, normalizedSummary, normalizedBlocker]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if haystack.contains("approval") {
            return .waitingForApproval
        }
        if haystack.contains("question") || haystack.contains("answer") || haystack.contains("input") {
            return .waitingForAnswer
        }
        if haystack.contains("blocked") || haystack.contains("error") || haystack.contains("failed") || haystack.contains("abort") {
            return .blocked
        }
        if haystack.contains("running") || haystack.contains("active") || haystack.contains("in progress") || haystack.contains("working") {
            return .running
        }
        if haystack.contains("complete") || haystack.contains("done") || haystack.contains("success") || haystack.contains("finished") {
            return .completed
        }

        return .unknown
    }

    private static func ownerName(forAgentID agentID: String?, key: String?) -> String? {
        let candidates = [agentID, key]
            .compactMap(normalizedLookupKey(from:))

        guard !candidates.isEmpty else {
            return nil
        }

        for owner in knownOwners {
            let tokens = Set(owner.agentIDs.map { normalizedLookupKey(from: $0) ?? "" } + owner.lookupTokens.map { normalizedLookupKey(from: $0) ?? "" })
            if candidates.contains(where: { candidate in
                tokens.contains(candidate) || tokens.contains(where: { candidate.contains($0) || $0.contains(candidate) })
            }) {
                return owner.displayName
            }
        }

        return nil
    }

    private static func parseSession(_ value: [String: Any]) -> RawSession? {
        let key = stringValue(forKeys: ["key"], in: value) ?? stringValue(forKeys: ["sessionKey"], in: value)
        let sessionID = stringValue(forKeys: ["sessionId", "id"], in: value)
        let updatedAt = dateValue(forKeys: ["updatedAt"], in: value)
        guard let key, let sessionID, let updatedAt else {
            return nil
        }

        return RawSession(
            key: key,
            sessionID: sessionID,
            updatedAt: updatedAt,
            ageMs: doubleValue(forKeys: ["ageMs"], in: value),
            agentID: stringValue(forKeys: ["agentId", "agentID"], in: value),
            kind: stringValue(forKeys: ["kind"], in: value),
            abortedLastRun: boolValue(forKeys: ["abortedLastRun"], in: value) ?? false
        )
    }

    private static func parseTask(_ value: [String: Any]) -> RawTask? {
        let priority = stringValue(
            forKeys: ["priority"],
            in: value
        ).flatMap(Self.sessionPriority(from:))

        let agentID = stringValue(forKeys: ["agentId", "agentID"], in: value)
        let sessionKey = stringValue(
            forKeys: ["sessionKey", "childSessionKey", "sessionId", "sessionID"],
            in: value
        )
        let ownerName = ownerName(
            forAgentID: agentID,
            key: stringValue(forKeys: ["label", "title", "name", "summary"], in: value) ?? sessionKey
        )
        let summary = stringValue(forKeys: ["summary", "title", "label", "prompt"], in: value)
        let blockerSummary = stringValue(
            forKeys: ["blockerSummary", "lastError", "error", "errorMessage"],
            in: value
        )

        if ownerName == nil && sessionKey == nil && summary == nil && blockerSummary == nil {
            return nil
        }

        return RawTask(
            id: stringValue(forKeys: ["id", "taskId"], in: value) ?? UUID().uuidString,
            ownerName: ownerName,
            agentID: agentID,
            sessionKey: sessionKey,
            status: stringValue(forKeys: ["status", "state"], in: value),
            summary: summary,
            projectTag: stringValue(forKeys: ["projectTag", "project", "workspace"], in: value),
            priority: priority,
            blockerSummary: blockerSummary
        )
    }

    private static func sessionSortWeight(lhs: RawSession, rhs: RawSession) -> Bool {
        let lhsWeight = representativeWeight(for: lhs)
        let rhsWeight = representativeWeight(for: rhs)
        if lhsWeight == rhsWeight {
            return lhs.updatedAt < rhs.updatedAt
        }

        return lhsWeight < rhsWeight
    }

    private static func representativeWeight(for session: RawSession) -> Int {
        var score = Int(session.updatedAt.timeIntervalSince1970)
        let normalizedKey = normalizedLookupKey(from: session.key) ?? ""
        let rawKey = session.key.lowercased()

        if rawKey.contains(":run:") {
            score -= 10_000_000
        }
        if normalizedKey.contains("direct") {
            score += 20_000
        }
        if normalizedKey.contains("subagent") {
            score += 10_000
        }
        if session.abortedLastRun {
            score += 5_000
        }

        return score
    }

    private static func taskSortWeight(lhs: RawTask, rhs: RawTask) -> Bool {
        let lhsWeight = representativeWeight(for: lhs)
        let rhsWeight = representativeWeight(for: rhs)
        if lhsWeight == rhsWeight {
            return lhs.id < rhs.id
        }

        return lhsWeight < rhsWeight
    }

    private static func representativeWeight(for task: RawTask) -> Int {
        var score = 0
        switch classifyTaskStatus(task.status, summary: task.summary, blocker: task.blockerSummary) {
        case .waitingForApproval:
            score += 5_000
        case .waitingForAnswer:
            score += 4_000
        case .blocked:
            score += 4_500
        case .running:
            score += 3_000
        case .completed:
            score += 500
        case .unknown:
            break
        }

        switch task.priority {
        case .critical?:
            score += 2_000
        case .high?:
            score += 1_500
        case .normal?:
            score += 400
        case .low?:
            score -= 100
        case nil:
            break
        }

        if normalizedInlineText(task.blockerSummary) != nil {
            score += 600
        }

        return score
    }

    private static func sessionPriority(from rawValue: String) -> SessionPriority? {
        switch normalizedLookupKey(from: rawValue) {
        case "critical":
            return .critical
        case "high":
            return .high
        case "normal", "medium":
            return .normal
        case "low":
            return .low
        default:
            return nil
        }
    }

    private static func extractJSONObject(from output: CommandOutput) -> [String: Any]? {
        let candidates = [output.stdout, [output.stdout, output.stderr].joined(separator: "\n")]

        for candidate in candidates {
            guard let start = candidate.firstIndex(of: "{"),
                  let end = candidate.lastIndex(of: "}"),
                  start <= end else {
                continue
            }

            let jsonText = String(candidate[start...end])
            guard let data = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                continue
            }

            return dictionary
        }

        return nil
    }

    private static func arrayValue(for key: String, in root: [String: Any]) -> [[String: Any]]? {
        root[key] as? [[String: Any]]
    }

    private static func stringValue(forKeys keys: [String], in root: [String: Any]) -> String? {
        for key in keys {
            if let text = root[key] as? String, !text.isEmpty {
                return text
            }
            if let number = root[key] as? NSNumber {
                return number.stringValue
            }
        }

        return nil
    }

    private static func doubleValue(forKeys keys: [String], in root: [String: Any]) -> Double? {
        for key in keys {
            if let value = root[key] as? Double {
                return value
            }
            if let value = root[key] as? Int {
                return Double(value)
            }
            if let value = root[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = root[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }

        return nil
    }

    private static func boolValue(forKeys keys: [String], in root: [String: Any]) -> Bool? {
        for key in keys {
            if let value = root[key] as? Bool {
                return value
            }
            if let value = root[key] as? NSNumber {
                return value.boolValue
            }
            if let value = root[key] as? String {
                switch value.lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    break
                }
            }
        }

        return nil
    }

    private static func dateValue(forKeys keys: [String], in root: [String: Any]) -> Date? {
        guard let timestamp = doubleValue(forKeys: keys, in: root) else {
            return nil
        }

        if timestamp > 100_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1_000)
        }

        return Date(timeIntervalSince1970: timestamp)
    }

    private static func normalizedLookupKey(from rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else {
            return nil
        }

        let separators = CharacterSet.alphanumerics.inverted
        let components = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !components.isEmpty else {
            return nil
        }

        return components.joined(separator: " ")
    }

    private static func normalizedInlineText(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let collapsed = rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed.isEmpty ? nil : collapsed
    }

    private static func isRecentOpenClawRow(_ session: AgentSession) -> Bool {
        session.phase != .completed || session.summary != "No recent OpenClaw session."
    }

    private static func defaultCommandRunner(arguments: [String]) -> CommandOutput {
        guard let executableURL = resolveExecutableURL() else {
            return CommandOutput(stdout: "", stderr: "", exitCode: 127, executableFound: false)
        }

        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.executableURL = executableURL
        task.arguments = arguments
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        task.environment = mergedEnvironment()

        do {
            try task.run()
            task.waitUntilExit()
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CommandOutput(
                stdout: stdout,
                stderr: stderr,
                exitCode: task.terminationStatus,
                executableFound: true
            )
        } catch {
            return CommandOutput(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: 1,
                executableFound: true
            )
        }
    }

    private static func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        let extraPaths = [
            "\(NSHomeDirectory())/.local/node22/bin",
            "\(NSHomeDirectory())/.local/node-v22.22.1-darwin-arm64/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/v22.22.1/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let pathParts = [currentPath]
            .filter { !$0.isEmpty }
            + extraPaths
        var uniquePaths: [String] = []
        for path in pathParts.joined(separator: ":").split(separator: ":").map(String.init) where !uniquePaths.contains(path) {
            uniquePaths.append(path)
        }
        environment["PATH"] = uniquePaths.joined(separator: ":")
        return environment
    }

    private static func resolveExecutableURL() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/node22/bin/openclaw",
            "\(NSHomeDirectory())/.local/node-v22.22.1-darwin-arm64/bin/openclaw",
            "\(NSHomeDirectory())/.nvm/versions/node/v22.22.1/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            "/usr/bin/openclaw",
        ]

        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["openclaw"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        process.environment = mergedEnvironment()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let output, !output.isEmpty else {
                return nil
            }

            return URL(fileURLWithPath: output)
        } catch {
            return nil
        }
    }
}
