import Foundation

/// What the widgets show, written by the app into the App Group container.
///
/// The engine runs in the app's process, so the widget extension has nothing to ask:
/// it draws the last snapshot the app wrote (`WidgetSnapshotWriter`). Only what the
/// widgets display goes in — no tokens, no message text, no file contents.
struct WidgetSnapshot: Codable, Equatable {
    enum Phase: String, Codable {
        case approval, question, running, idle

        /// Waiting on the user.
        var waiting: Bool { self == .approval || self == .question }
        var active: Bool { self != .idle }
    }

    struct Session: Codable, Hashable, Identifiable {
        var id: String
        /// nil when the user turned titles off (设置 → 小组件显示会话标题).
        var title: String?
        var phase: Phase
        /// The approval's command or reason, or the open question; nil when titles are off.
        var detail: String?
        /// Running since (as far as the app saw); the widgets count up from it.
        var since: Date?
        var updatedAt: Date
    }

    /// When the app last wrote or confirmed this. It rewrites it while work runs,
    /// so an old one means the app is no longer running.
    var writtenAt: Date
    /// Waiting first, then running, then the most recently updated idle ones.
    var sessions: [Session]
    /// The current workspace's title, for 新对话.
    var workspace: String?

    static let empty = WidgetSnapshot(writtenAt: .distantPast, sessions: [], workspace: nil)

    /// Past this, active sessions read as 状态未知: the app has not confirmed them since.
    static let staleAfter: TimeInterval = 30 * 60

    func isStale(at date: Date) -> Bool { date.timeIntervalSince(writtenAt) > Self.staleAfter }

    var active: [Session] { sessions.filter(\.phase.active) }
    var waitingCount: Int { sessions.filter(\.phase.waiting).count }
    var runningCount: Int { sessions.filter { $0.phase == .running }.count }
}

/// The snapshot file in the App Group container, shared by the app (writes) and the extension (reads).
enum WidgetSnapshotStore {
    /// The widget kinds, for `WidgetCenter.reloadTimelines(ofKind:)`.
    static let sessionsKind = "DshSessions"
    static let newConversationKind = "DshNewConversation"

    /// `DshAppGroup` in Info.plist (`DSH_APP_GROUP` in project.yml).
    static var groupId: String? { Bundle.main.object(forInfoDictionaryKey: "DshAppGroup") as? String }

    static var fileURL: URL? {
        guard let groupId, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return nil }
        return container.appending(path: "widget-snapshot.json")
    }

    static func read() -> WidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return .empty }
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? .empty
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL, let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
