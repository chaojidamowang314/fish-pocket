import SwiftUI
import WidgetKit

/// 会话状态: what runs and what waits on the user, on the home screen, in StandBy and on
/// the lock screen. A small widget is one tap (the session in focus, or 新对话 when idle);
/// the medium and large ones link each row to its session.
struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.sessionsKind, provider: SnapshotProvider()) { entry in
            SessionsWidgetView(entry: entry)
        }
        .configurationDisplayName("会话状态")
        .description("正在运行和等你处理的会话。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct SessionsWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularSessions(entry: entry).containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            RectangularSessions(entry: entry).containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            InlineSessions(entry: entry).containerBackground(for: .widget) { Color.clear }
        case .systemMedium:
            SessionList(entry: entry, rows: 3, details: false)
                .containerBackground(WidgetPalette.background, for: .widget)
        case .systemLarge:
            SessionList(entry: entry, rows: 6, details: true)
                .containerBackground(WidgetPalette.background, for: .widget)
        default:
            SmallSessions(entry: entry)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
    }
}

// MARK: Home screen

private struct SmallSessions: View {
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var focus: WidgetSnapshot.Session? { snapshot.active.first }

    var body: some View {
        Group {
            if let focus {
                active(focus)
            } else {
                idle
            }
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(focus.map { DshLink.session($0.id).url } ?? (entry.unset ? nil : DshLink.new().url))
    }

    private func active(_ session: WidgetSnapshot.Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(phase: session.phase, stale: entry.stale)
                Text(entry.stale ? String(localized: "状态未知") : WidgetText.phase(session.phase))
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 4)
                if !entry.stale, session.phase == .running, let since = session.since {
                    Text(since, style: .timer)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(WidgetPalette.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56, alignment: .trailing)
                } else {
                    FishMark(size: 13).foregroundStyle(WidgetPalette.secondary)
                }
            }
            Text(session.title ?? WidgetText.summary(snapshot))
                .font(.headline)
                .lineLimit(2)
                .privacySensitive()
                .padding(.top, 10)
            if entry.stale {
                Text("打开 App 查看").font(.footnote).foregroundStyle(WidgetPalette.secondary).padding(.top, 4)
            } else if let detail = session.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                    .privacySensitive()
                    .padding(.top, 4)
            }
            Spacer(minLength: 4)
            Group {
                if entry.stale {
                    UpdatedAgo(date: snapshot.writtenAt, now: entry.date)
                } else if snapshot.active.count > 1 {
                    Text("另有 \(snapshot.active.count - 1) 个")
                }
            }
            .font(.caption)
            .foregroundStyle(WidgetPalette.secondary)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                FishMark(size: 13)
                Text(entry.unset ? "Fish Pocket" : String(localized: "都处理完了")).font(.footnote.weight(.semibold))
            }
            Text(entry.unset ? String(localized: "打开 App 后这里会显示会话状态") : String(localized: "没有进行中的任务"))
                .font(.footnote)
                .foregroundStyle(WidgetPalette.secondary)
                .lineLimit(3)
                .padding(.top, 10)
            Spacer(minLength: 4)
            if !entry.unset { InkCapsule(title: "新对话") }
        }
    }
}

/// Medium and large: the sessions in order, each row a link; a 新对话 button when there is room.
private struct SessionList: View {
    let entry: SnapshotEntry
    let rows: Int
    let details: Bool

    private var snapshot: WidgetSnapshot { entry.snapshot }

    /// The medium widget gives its third row to the button unless three sessions, some active, need it.
    private var full: Bool { !details && snapshot.sessions.count >= rows && !snapshot.active.isEmpty }

    private var shown: [WidgetSnapshot.Session] {
        Array(snapshot.sessions.prefix(details || full ? rows : rows - 1))
    }

    private var showsButton: Bool { !full }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                FishMark(size: 14)
                Text("会话状态").font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                Group {
                    if entry.stale {
                        UpdatedAgo(date: snapshot.writtenAt, now: entry.date)
                    } else {
                        Text(WidgetText.summary(snapshot))
                    }
                }
                .font(.caption)
                .foregroundStyle(WidgetPalette.secondary)
                .lineLimit(1)
            }
            .padding(.bottom, 4)
            if shown.isEmpty {
                Text(entry.unset ? String(localized: "打开 App 后这里会显示会话状态") : String(localized: "还没有会话"))
                    .font(.subheadline)
                    .foregroundStyle(WidgetPalette.secondary)
                    .padding(.top, 8)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                Link(destination: DshLink.session(session.id).url) {
                    row(session, detail: details && index == 0 && session.phase.waiting)
                }
            }
            Spacer(minLength: 0)
            if showsButton, !entry.unset {
                Link(destination: DshLink.new().url) { InkCapsule(title: "新对话", height: details ? 44 : 36) }
            }
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ session: WidgetSnapshot.Session, detail: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(phase: session.phase, stale: entry.stale)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(WidgetText.title(session))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .privacySensitive()
                    Spacer(minLength: 4)
                    trailing(session)
                }
                if detail, let text = session.detail {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
        }
        .frame(minHeight: details ? 34 : 32)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailing(_ session: WidgetSnapshot.Session) -> some View {
        if entry.stale && session.phase.active {
            Text("状态未知").font(.footnote).foregroundStyle(WidgetPalette.secondary)
        } else {
            switch session.phase {
            case .approval, .question:
                Text(WidgetText.phase(session.phase)).font(.footnote.weight(.semibold))
            case .running:
                if let since = session.since {
                    Text(since, style: .timer)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(WidgetPalette.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56, alignment: .trailing)
                }
            case .idle:
                SessionTime(date: session.updatedAt).font(.footnote).foregroundStyle(WidgetPalette.secondary)
            }
        }
    }
}

// MARK: Lock screen

/// The lock screen is drawn in one tint, so waiting is told by the symbol, not the colour.
private struct RectangularSessions: View {
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var focus: WidgetSnapshot.Session? { snapshot.active.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let focus {
                Label {
                    Text(entry.stale ? String(localized: "状态未知") : WidgetText.phase(focus.phase))
                } icon: {
                    Image(systemName: entry.stale ? "questionmark.circle" : focus.phase.waiting ? "exclamationmark.circle.fill" : "circle.fill")
                        .imageScale(focus.phase.waiting || entry.stale ? .medium : .small)
                }
                .font(.headline)
                if let title = focus.title {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1).privacySensitive()
                    Group {
                        if entry.stale {
                            Text("打开 App 查看")
                        } else if snapshot.active.count > 1 {
                            Text("另有 \(snapshot.active.count - 1) 个")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(WidgetText.summary(snapshot)).font(.subheadline).lineLimit(2)
                }
            } else {
                Label { Text(verbatim: "Fish Pocket") } icon: { Image(systemName: "fish.fill") }
                    .font(.headline)
                Text(entry.unset ? String(localized: "打开 App 后这里会显示会话状态") : String(localized: "没有进行中的任务"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(focus.map { DshLink.session($0.id).url })
    }
}

private struct CircularSessions: View {
    let entry: SnapshotEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "fish.fill").font(.system(size: 12, weight: .bold))
                // verbatim：问号是「读不到数」的占位符号，不是一句话。不这样写的话
                // SwiftUI 会把它当文案抽进 String Catalog，三语各补一个问号。
                Text(verbatim: entry.stale ? "?" : "\(entry.snapshot.active.count)")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                if !entry.stale, entry.snapshot.waitingCount > 0 {
                    Text("\(entry.snapshot.waitingCount) 待处理").font(.system(size: 9, weight: .semibold)).lineLimit(1)
                }
            }
        }
        .widgetAccentable()
        .widgetURL(entry.snapshot.active.first.map { DshLink.session($0.id).url })
    }
}

private struct InlineSessions: View {
    let entry: SnapshotEntry

    var body: some View {
        Label {
            Text(entry.stale ? String(localized: "状态未知") : WidgetText.summary(entry.snapshot))
        } icon: {
            Image(systemName: "fish.fill")
        }
        .widgetURL(entry.snapshot.active.first.map { DshLink.session($0.id).url })
    }
}
