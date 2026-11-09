import SwiftUI

/// 设置 → 本机能力 →「使用记录」：哪些本机能力被用过，谁用的，什么时候。
///
/// 这一页不是日志，是**用户唯一能看到「这个 App 碰了我哪些数据」的地方**
/// （docs/native-services.md §5.4）。应用层没有授权开关，事前只剩「装不装这个
/// 插件」那一次机会，事后就只剩这里。
///
/// 记录存在原生侧（`audit.m`）而不是引擎侧：引擎侧的文件插件自己就能改，
/// 能被改的审计等于没有审计。
struct NativeAuditView: View {
    @State private var entries: [NativeAuditEntry] = []
    @State private var askingToClear = false

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    Text("还没有用过任何需要授权的本机能力。")
                        .foregroundStyle(Palette.secondary)
                }
                .groupedRow()
            } else {
                Section {
                    ForEach(entries) { entry in
                        NativeAuditRow(entry: entry)
                    }
                } footer: {
                    // 「谁调的」这件事必须说清楚不可信，否则用户会拿它当证据。
                    Text("调用方是自己报的名字，不能当证据：插件可以把自己报成引擎本体。只保留最近 \(NativeAuditEntry.capacity) 条。")
                }
                .groupedRow()

                Section {
                    Button("清空记录", role: .destructive) { askingToClear = true }
                }
                .groupedRow()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("使用记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = NativeAuditEntry.all }
        // 从别处回到这一页时重读：期间智能体可能又调用了一次。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            entries = NativeAuditEntry.all
        }
        .confirmationDialog("清空使用记录？", isPresented: $askingToClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                DshNativeAuditClear()
                entries = []
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空之后就看不到之前谁用过这些能力了。")
        }
    }
}

/// 一条使用记录。
struct NativeAuditEntry: Identifiable {
    /// 和 `audit.m` 的环形缓冲上限一致，只为在页面上说清楚留多少条。
    static let capacity = 200

    let id = UUID()
    let capability: String
    let op: String
    let at: Date
    /// 调用方自报的名字。不可信——命名里带 claim 就是为了让人别拿它做判定。
    let callerClaim: String?
    /// 能力自己给的一行说明，语言中性（日期、数量、用户自己的文字）。
    let summary: String?

    static var all: [NativeAuditEntry] {
        DshNativeAuditEntries().map { entry in
            NativeAuditEntry(
                capability: entry["capability"] as? String ?? "",
                op: entry["op"] as? String ?? "",
                at: Date(timeIntervalSince1970: entry["at"] as? TimeInterval ?? 0),
                callerClaim: entry["caller"] as? String,
                summary: entry["summary"] as? String
            )
        }
    }

    /// 「日历 · 读取事件」。文案查不到就退回原始 id，这样新能力不会显示成空白。
    var title: String {
        let name = NativeCapability.all.first { $0.id == capability }?.title ?? capability
        return "\(name) · \(operationName)"
    }

    private var operationName: String {
        switch (capability, op) {
        case ("calendar", "list"): return String(localized: "读取事件")
        case ("calendar", "calendars"): return String(localized: "读取日历列表")
        case ("calendar", "create"): return String(localized: "新建日程")
        case ("calendar", "update"): return String(localized: "修改日程")
        case ("calendar", "delete"): return String(localized: "删除日程")
        case ("reminders", "list"): return String(localized: "读取待办")
        case ("reminders", "create"): return String(localized: "新建待办")
        case ("reminders", "complete"): return String(localized: "标记完成")
        case ("reminders", "delete"): return String(localized: "删除待办")
        case ("notify", "schedule"): return String(localized: "设定提醒")
        case ("notify", "cancel"): return String(localized: "取消提醒")
        case ("notify", "pending"): return String(localized: "查看待发提醒")
        default: return op
        }
    }

    /// 本体自报的名字在 UI 上说成「智能体」，插件直接显示它报的包名。
    var callerLabel: String {
        switch callerClaim {
        case nil, "": return String(localized: "未知来源")
        case "dsh", "root": return String(localized: "智能体")
        case .some(let name): return name
        }
    }
}

private struct NativeAuditRow: View {
    let entry: NativeAuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                Text(entry.at, format: .dateTime.month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
            }
            if let summary = entry.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.callerLabel)
                .font(.caption)
                .foregroundStyle(Palette.secondary)
        }
        .padding(.vertical, 2)
    }
}
