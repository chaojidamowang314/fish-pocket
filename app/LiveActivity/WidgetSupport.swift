import SwiftUI
import UIKit
import WidgetKit

/// One timeline entry: the snapshot as of `date`, which is when it may have gone stale.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    /// Active sessions the app has not confirmed for a while: the app is not running.
    var stale: Bool { snapshot.isStale(at: date) && !snapshot.active.isEmpty }
    /// The app has never written one: nothing to show yet.
    var unset: Bool { snapshot.writtenAt == .distantPast }
}

/// Reads the snapshot. The app asks for reloads when it writes, so the only entry
/// planned ahead is the moment active sessions turn stale.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.read()
        let now = Date.now
        var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
        // Active sessions turn 状态未知 at `staleAfter`; from then on 「更新于…」 moves every quarter hour.
        if !snapshot.active.isEmpty {
            let staleAt = snapshot.writtenAt.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
            for step in 0..<24 {
                let date = staleAt.addingTimeInterval(Double(step) * 15 * 60)
                if date > now { entries.append(SnapshotEntry(date: date, snapshot: snapshot)) }
            }
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

/// The design tokens (docs/design/README.md §3) the widgets use, light and dark.
enum WidgetPalette {
    static let background = dynamic(0xFFFFFF, 0x161618)
    static let ink = dynamic(0x0C0C0D, 0xF2F2F3)
    static let onInk = dynamic(0xFFFFFF, 0x0C0C0D)
    static let secondary = dynamic(0x6B6B72, 0x9A9AA0)
    static let field = dynamic(0xF3F3F4, 0x232326)
    static let faint = dynamic(0xC8C8CE, 0x4A4A50)
    static let running = dynamic(0x12A06A, 0x3DD68C)
    static let waiting = dynamic(0xD98A00, 0xF5A524)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The brand mark, as on the Live Activity.
struct FishMark: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "fish.fill")
            .font(.system(size: size, weight: .bold))
            .accessibilityLabel("Fish Pocket")
    }
}

/// A session's status dot: colour while it runs or waits, hollow when stale, faint when idle.
struct StatusDot: View {
    let phase: WidgetSnapshot.Phase
    var stale = false

    var body: some View {
        if stale && phase.active {
            Circle().strokeBorder(WidgetPalette.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        } else {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private var color: Color {
        switch phase {
        case .approval, .question: WidgetPalette.waiting
        case .running: WidgetPalette.running
        case .idle: WidgetPalette.faint
        }
    }
}

/// The black capsule the app's primary buttons use.
struct InkCapsule: View {
    let title: LocalizedStringKey
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 13, weight: .bold))
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(WidgetPalette.onInk)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(WidgetPalette.ink, in: Capsule())
    }
}

enum WidgetText {
    static func phase(_ phase: WidgetSnapshot.Phase) -> String {
        switch phase {
        case .approval: String(localized: "等你允许")
        case .question: String(localized: "等你回答")
        case .running: String(localized: "进行中")
        case .idle: String(localized: "已完成")
        }
    }

    /// 「1 个等你 · 2 个进行中」, or that nothing is running.
    static func summary(_ snapshot: WidgetSnapshot) -> String {
        let waiting = snapshot.waitingCount, running = snapshot.runningCount
        switch (waiting, running) {
        case (0, 0): return String(localized: "没有进行中的任务")
        case (_, 0): return String(localized: "\(waiting) 个等你")
        case (0, _): return String(localized: "\(running) 个进行中")
        default: return String(localized: "\(waiting) 个等你 · \(running) 个进行中")
        }
    }

    /// A session's title, or its state when the user turned titles off.
    static func title(_ session: WidgetSnapshot.Session) -> String {
        session.title ?? phase(session.phase)
    }
}

/// When the snapshot was last confirmed, as of the entry: 「更新于 42 分钟前」. The timeline
/// adds entries every quarter hour once stale, so the minutes move on without the app.
struct UpdatedAgo: View {
    let date: Date
    let now: Date

    var body: some View {
        Text("更新于 \(Self.formatter.localizedString(for: date, relativeTo: max(now, date)))")
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// An idle session's time: the clock today, the date before.
struct SessionTime: View {
    let date: Date

    var body: some View {
        if Calendar.current.isDateInToday(date) {
            Text(date, style: .time)
        } else {
            Text(date, format: .dateTime.month(.defaultDigits).day())
        }
    }
}
