import Foundation
import Observation
import WidgetKit

/// Keeps the widgets' snapshot (`WidgetSnapshot`) in step with the app: rewritten
/// shortly after what it shows changes, and confirmed every few minutes while work
/// runs so that the widgets can tell a running session from a stale one.
/// Reloads are asked for only when something was written.
@MainActor
final class WidgetSnapshotWriter {
    /// 设置 → 小组件显示会话标题. Off: no title or detail reaches the shared container.
    static let showTitlesKey = "dsh.widget.showTitles"
    /// MainView's current workspace.
    static let workspaceKey = "dsh.currentWorkspace"

    static let shared = WidgetSnapshotWriter()

    /// Sessions in the snapshot: the large widget shows six.
    private static let limit = 6
    private static let debounce = Duration.seconds(1)
    /// Well inside `WidgetSnapshot.staleAfter`.
    private static let heartbeat = Duration.seconds(10 * 60)

    private weak var app: AppModel?
    /// The content last written, `writtenAt` aside.
    private var written: WidgetSnapshot?
    private var wanted: WidgetSnapshot?
    /// When each session was first seen running in this run of the app.
    private var runningSince: [String: Date] = [:]
    private var pendingWrite: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private init() {}

    func attach(_ app: AppModel) {
        self.app = app
        observe()
    }

    /// A setting or the current workspace changed: both live outside the model.
    func refresh() {
        guard let app else { return }
        apply(Self.snapshot(of: app))
    }

    private func observe() {
        guard let app else { return }
        let next = withObservationTracking { Self.snapshot(of: app) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(next)
    }

    private func apply(_ snapshot: WidgetSnapshot) {
        var next = snapshot
        let now = Date.now
        let running = Set(next.sessions.filter { $0.phase == .running }.map(\.id))
        runningSince = runningSince.filter { running.contains($0.key) }
        for id in running where runningSince[id] == nil { runningSince[id] = now }
        next.sessions = next.sessions.map { session in
            var session = session
            session.since = runningSince[session.id]
            return session
        }
        wanted = next
        guard next != written else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        guard var snapshot = wanted else { return }
        written = snapshot
        snapshot.writtenAt = .now
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        keepConfirming(!snapshot.active.isEmpty)
    }

    /// While sessions are active the snapshot is confirmed now and then; idle needs no confirming.
    private func keepConfirming(_ on: Bool) {
        guard on else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }
        guard heartbeatTask == nil else { return }
        // `write` cancels it once nothing is active.
        heartbeatTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled, let self else { return }
                self.write()
            }
        }
    }

    /// Top-level sessions only: a subagent's approval or question shows on the session it serves.
    private static func snapshot(of app: AppModel) -> WidgetSnapshot {
        let showTitles = UserDefaults.standard.object(forKey: showTitlesKey) as? Bool ?? true
        func root(_ id: String) -> String {
            var id = id
            for _ in 0..<8 {
                guard let session = app.sessions[id], session.isSubagent, let parent = session.parentId else { break }
                id = parent
            }
            return id
        }

        var phase: [String: WidgetSnapshot.Phase] = [:]
        var detail: [String: String] = [:]
        for (agentId, pending) in app.approvals.sorted(by: { $0.key < $1.key }) {
            guard let approval = pending.first else { continue }
            let id = root(agentId)
            guard phase[id] == nil else { continue }
            phase[id] = .approval
            detail[id] = approval.reason?.isEmpty == false ? approval.reason! : String(localized: "工具 \(approval.toolName) 请求越权执行")
        }
        for id in app.sessions.keys.sorted() where app.isWaiting(id) {
            let owner = root(id)
            guard phase[owner] == nil else { continue }
            phase[owner] = .question
            detail[owner] = app.control[id]?["userQuestions"]?["active"].array.first?["questions"].array.first?["question"].string
                ?? app.questionRequests[id]?.first?.questions.first?.question
        }
        for session in app.sessions.values where session.running {
            let id = root(session.id)
            if phase[id] == nil { phase[id] = .running }
        }

        let rank: (WidgetSnapshot.Phase) -> Int = { $0.waiting ? 0 : $0 == .running ? 1 : 2 }
        let sessions = app.sessions.values
            .filter { !$0.isSubagent && !$0.blank && !app.isArchived($0.id) }
            .map { summary in
                WidgetSnapshot.Session(
                    id: summary.id,
                    title: showTitles ? app.title(of: summary.id) : nil,
                    phase: phase[summary.id] ?? .idle,
                    detail: showTitles ? detail[summary.id] : nil,
                    since: nil,
                    updatedAt: summary.updatedAt
                )
            }
            .sorted { lhs, rhs in
                let l = rank(lhs.phase), r = rank(rhs.phase)
                return l != r ? l < r : lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)

        let workspaceId = UserDefaults.standard.string(forKey: workspaceKey)
        let workspace = app.workspaces.first { $0.id == workspaceId } ?? app.workspaces.first
        return WidgetSnapshot(writtenAt: .distantPast, sessions: Array(sessions), workspace: workspace?.displayTitle)
    }
}
