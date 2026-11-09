import SwiftUI
import WidgetKit

/// 新对话: one tap into a new conversation in the current workspace, keyboard up.
struct NewConversationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.newConversationKind, provider: SnapshotProvider()) { entry in
            NewConversationView(entry: entry)
                .widgetURL(DshLink.new().url)
        }
        .configurationDisplayName("新对话")
        .description("点一下就开始新对话。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

private struct NewConversationView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var workspace: String { entry.snapshot.workspace ?? String(localized: "上次的工作区") }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil").font(.system(size: 22, weight: .semibold))
            }
            .accessibilityLabel(Text("新对话"))
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
        case .systemMedium:
            medium.containerBackground(WidgetPalette.background, for: .widget)
        default:
            small.containerBackground(WidgetPalette.background, for: .widget)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                FishMark(size: 18)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(WidgetPalette.onInk)
                    .frame(width: 44, height: 44)
                    .background(WidgetPalette.ink, in: Circle())
            }
            Spacer(minLength: 4)
            Text("新对话").font(.title3.weight(.bold))
            Text(workspace).font(.footnote).foregroundStyle(WidgetPalette.secondary).lineLimit(1)
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The app's composer, as a way into it.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                FishMark(size: 14)
                Text(verbatim: "Fish Pocket").font(.footnote.weight(.semibold))
            }
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Text("描述任务").font(.callout).foregroundStyle(WidgetPalette.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WidgetPalette.onInk)
                    .frame(width: 40, height: 40)
                    .background(WidgetPalette.ink, in: Circle())
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(height: 52)
            .background(WidgetPalette.field, in: Capsule())
            Spacer(minLength: 6)
            Text(workspace).font(.footnote).foregroundStyle(WidgetPalette.secondary).lineLimit(1)
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
