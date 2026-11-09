import SwiftUI
import EventKit
import UserNotifications

/// 设置 →「本机能力」：智能体能用到手机的哪些东西，各自要不要系统授权。
///
/// 清单来自 addon 的能力表（`DshNativeCapabilityList`），不是这里写死的一份拷贝——
/// 判定调用和展示清单读同一张表，两者就不会悄悄对不上（docs/native-services.md §9.3）。
/// 这里只负责文案：没有文案的能力照样列出来（显示 id），所以原生加了能力而忘了加
/// 中文名时，页面会少个名字，但不会漏掉它。
struct NativeCapabilitiesView: View {
    @State private var capabilities: [NativeCapability] = []
    /// 按 `systemPermission` 存，所以新增一项要授权的能力时这里不用再加分支。
    @State private var permissions: [String: CapabilityPermission] = [:]

    var body: some View {
        List {
            Section {
                ForEach(capabilities) { capability in
                    CapabilityRow(
                        capability: capability,
                        permission: capability.systemPermission.flatMap { permissions[$0] } ?? .notNeeded
                    )
                }
            } footer: {
                // 不含糊其辞：插件用的就是这些能力，而且 App 不区分谁在调用——
                // 说清楚了，用户才知道该在装插件那一步把关。
                Text("智能体和你装的第三方插件都能用这些能力，App 不区分谁在调用。装插件前请确认来源可信。")
            }
            .groupedRow()

            if capabilities.contains(where: { $0.systemPermission != nil }) {
                Section {
                    NavigationLink { NativeAuditView() } label: {
                        Text("使用记录")
                    }
                } footer: {
                    // 没有应用层开关，这页就是用户事后唯一的查证途径（§5.4）。
                    Text("哪些要授权的能力被用过、谁用的。")
                }
                .groupedRow()

                Section {
                    Button("打开系统设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                } footer: {
                    Text("系统授权只能在「设置」里改。iOS 的授权弹窗每个 App 只出现一次，拒绝之后也要回那里打开。")
                }
                .groupedRow()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("本机能力")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        // 从系统设置改完授权切回来时刷新，否则这页会一直显示旧状态。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func load() {
        capabilities = NativeCapability.all
        refreshPermissions()
    }

    /// 只问清单里真的出现过的那些授权，别为一个这个构建没有的能力去碰框架。
    private func refreshPermissions() {
        let needed = Set(capabilities.compactMap(\.systemPermission))
        // EventKit 是同步查询，不用回调。日历和提醒的档位含义一样，所以共用一个映射。
        for (permission, entity) in [
            (NativeCapability.calendarPermission, EKEntityType.event),
            (NativeCapability.remindersPermission, EKEntityType.reminder),
        ] where needed.contains(permission) {
            permissions[permission] = .ofEventKit(EKEventStore.authorizationStatus(for: entity))
        }
        if needed.contains(NativeCapability.notificationPermission) {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                Task { @MainActor in
                    permissions[NativeCapability.notificationPermission] = .ofNotifications(settings.authorizationStatus)
                }
            }
        }
    }
}

/// 一项能力的系统授权状态。按档位而不是按能力分，所以加能力不用加状态。
enum CapabilityPermission {
    case notNeeded
    case notDetermined
    case allowed
    case denied
    /// 给了，但不够用。日历的「仅添加」就是这一档：写得进去，读不出来。
    case insufficient(LocalizedStringResource)

    static func ofNotifications(_ status: UNAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    static func ofEventKit(_ status: EKAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .fullAccess: return .allowed
        case .denied, .restricted: return .denied
        // iOS 17 起日历权限分「完全」和「仅添加」两档，没有只读档。停在「仅添加」
        // 的话读日程会一直失败，所以这里要说清楚是哪一档，而不是笼统说「已允许」。
        case .writeOnly: return .insufficient("仅可添加，读不了日程")
        default: return .notDetermined
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .notNeeded: return "无需授权"
        case .notDetermined: return "首次使用时询问"
        case .allowed: return "已允许"
        case .denied: return "已关闭"
        case .insufficient(let detail): return detail
        }
    }

    /// 只有用户动手才能解决的那两档才值得被强调出来。
    var needsAttention: Bool {
        switch self {
        case .denied, .insufficient: return true
        case .notNeeded, .notDetermined, .allowed: return false
        }
    }
}

/// 一项本机能力，连同它的中文说明。
struct NativeCapability: Identifiable {
    static let notificationPermission = "notifications"
    static let calendarPermission = "calendar"
    static let remindersPermission = "reminders"

    let id: String
    let ops: [String]
    /// 需要的 iOS 授权；为空表示不需要任何授权。
    let systemPermission: String?

    /// addon 的能力表。表在二进制里是固定的，读一次就够——设置页那行计数会随
    /// SwiftUI 每次重绘求值，不该每次都过一遍桥。
    static let all: [NativeCapability] = DshNativeCapabilityList().map { entry in
        NativeCapability(
            id: entry["id"] as? String ?? "",
            ops: entry["ops"] as? [String] ?? [],
            systemPermission: entry["systemPermission"] as? String
        )
    }

    /// 装插件前要告诉用户的那句话里，列出的能力名。
    ///
    /// 取自同一张能力表，所以日历加进来之后，安装页的警告会自己跟着变——
    /// 写死一份清单的话，迟早变成一句过期的承诺。
    static var installWarningSummary: String {
        all.map(\.title).joined(separator: "、")
    }

    /// 文案按 id 查；没有就退回 id 本身，这样新能力不会从列表里消失。
    var title: String {
        switch id {
        case "device": return String(localized: "设备状态")
        case "notify": return String(localized: "通知提醒")
        case "speak": return String(localized: "朗读")
        case "calendar": return String(localized: "日历")
        case "reminders": return String(localized: "提醒事项")
        default: return id
        }
    }

    var detail: String {
        switch id {
        case "device": return String(localized: "机型、系统版本、电量、存储空间")
        case "notify": return String(localized: "按你的要求定时提醒你，App 关着也会响")
        case "speak": return String(localized: "把文字念出来")
        case "calendar": return String(localized: "查看你的日程。新建、修改和删除都要你当场确认")
        case "reminders": return String(localized: "查看「提醒事项」里的待办。新建、完成和删除都要你当场确认")
        default: return ops.joined(separator: " · ")
        }
    }
}

private struct CapabilityRow: View {
    let capability: NativeCapability
    let permission: CapabilityPermission

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title).foregroundStyle(Palette.ink)
                Text(capability.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(permission.label)
                .font(.footnote)
                .foregroundStyle(permission.needsAttention ? Palette.ink : Palette.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
