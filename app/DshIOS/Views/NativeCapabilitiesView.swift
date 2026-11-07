import SwiftUI
import UserNotifications

/// 设置 →「本机能力」：智能体能用到手机的哪些东西，各自要不要系统授权。
///
/// 清单来自 addon 的能力表（`DshNativeCapabilityList`），不是这里写死的一份拷贝——
/// 判定调用和展示清单读同一张表，两者就不会悄悄对不上（docs/native-services.md §9.3）。
/// 这里只负责文案：没有文案的能力照样列出来（显示 id），所以原生加了能力而忘了加
/// 中文名时，页面会少个名字，但不会漏掉它。
struct NativeCapabilitiesView: View {
    @State private var capabilities: [NativeCapability] = []
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            Section {
                ForEach(capabilities) { capability in
                    CapabilityRow(capability: capability, notificationStatus: notificationStatus)
                }
            } footer: {
                Text("这些能力对智能体和你装的插件一视同仁：插件和智能体走同一条路，App 不区分谁在调用。")
            }
            .groupedRow()

            if capabilities.contains(where: { $0.systemPermission != nil }) {
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
            refreshNotificationStatus()
        }
    }

    private func load() {
        capabilities = NativeCapability.all
        refreshNotificationStatus()
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in notificationStatus = settings.authorizationStatus }
        }
    }
}

/// 一项本机能力，连同它的中文说明。
struct NativeCapability: Identifiable {
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

    /// 文案按 id 查；没有就退回 id 本身，这样新能力不会从列表里消失。
    var title: String {
        switch id {
        case "device": return String(localized: "设备状态")
        case "notify": return String(localized: "通知提醒")
        case "speak": return String(localized: "朗读")
        default: return id
        }
    }

    var detail: String {
        switch id {
        case "device": return String(localized: "机型、系统版本、电量、存储空间")
        case "notify": return String(localized: "按你的要求定时提醒你，App 关着也会响")
        case "speak": return String(localized: "把文字念出来")
        default: return ops.joined(separator: " · ")
        }
    }
}

private struct CapabilityRow: View {
    let capability: NativeCapability
    let notificationStatus: UNAuthorizationStatus

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
            Text(status.label)
                .font(.footnote)
                .foregroundStyle(status.needsAttention ? Palette.ink : Palette.secondary)
        }
        .padding(.vertical, 2)
    }

    private var status: (label: String, needsAttention: Bool) {
        guard capability.systemPermission != nil else {
            return (String(localized: "无需授权"), false)
        }
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return (String(localized: "已允许"), false)
        case .denied:
            // 这一档才值得用户动手：去系统设置打开。
            return (String(localized: "已关闭"), true)
        default:
            return (String(localized: "首次使用时询问"), false)
        }
    }
}
