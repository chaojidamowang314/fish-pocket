import SwiftUI
import EventKit
import UserNotifications

/// 「本机能力」：智能体能用到手机的哪些东西，各自要不要系统授权——以及由你在这里
/// 一项项打开。
///
/// 这一页是**唯一**会弹出系统授权框的地方。能力本身在没拿到授权时直接拒绝调用，
/// 不会自己去弹框（docs/native-services.md §5.5），所以「某个插件碰巧调了一下，
/// 用户就被按头要权限」这件事不会发生；反过来，这一页要是不好找，这些能力就
/// 永远开不起来——它在侧边栏有自己的入口，不只藏在设置里。
///
/// 清单来自 addon 的能力表（`DshNativeCapabilityList`），不是这里写死的一份拷贝——
/// 判定调用和展示清单读同一张表，两者就不会悄悄对不上（§9.3）。这里只负责文案：
/// 没有文案的能力照样列出来（显示 id），所以原生加了能力而忘了加中文名时，页面会
/// 少个名字，但不会漏掉它。
struct NativeCapabilitiesView: View {
    @State private var capabilities: [NativeCapability] = []
    /// 按 `systemPermission` 存，所以新增一项要授权的能力时这里不用再加分支。
    @State private var permissions: [String: CapabilityPermission] = [:]
    /// 每项能力的写入策略，按能力 id 存。
    @State private var policies: [String: DshWritePolicy] = [:]
    /// 正在等系统弹框答复的那一项，用来挡住重复点击。
    @State private var requesting: String?
    /// 只有 iOS 自己出错时才有东西——用户点「不允许」不算错，状态会直接变成已关闭。
    @State private var failure: String?

    private var needsPermission: Bool {
        capabilities.contains { $0.systemPermission != nil }
    }

    var body: some View {
        List {
            Section {
                ForEach(capabilities) { capability in
                    CapabilityRow(
                        capability: capability,
                        permission: capability.systemPermission.flatMap { permissions[$0] } ?? .notNeeded,
                        policy: policies[capability.id] ?? .direct,
                        busy: requesting != nil && requesting == capability.systemPermission,
                        enable: { enable(capability) },
                        setPolicy: { policies[capability.id] = $0; DshNativeSetWritePolicy(capability.id, $0) },
                        openSettings: openSystemSettings
                    )
                }
            } header: {
                // 这一段是整页的要点：没开的用不了，而且只有你能开。
                Text("没开的能力，智能体和你装的插件都用不了，也没法替你打开。系统的授权框只会在你点「开启」时出现。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .textCase(nil)
                    .padding(.bottom, 6)
            } footer: {
                // 不含糊其辞：插件用的就是这些能力，而且 App 不区分谁在调用——
                // 说清楚了，用户才知道该在装插件那一步把关。
                Text("开启之后，智能体和你装的第三方插件都能用，App 不区分谁在调用。装插件前请确认来源可信。改、删这类写操作默认直接执行，不会每次问你——想让它每次停下来问，把那一项的「写入」改成「每次确认」。")
            }
            .groupedRow()

            if needsPermission {
                Section {
                    NavigationLink { NativeAuditView() } label: {
                        Label("使用记录", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    // 没有应用层开关，这页就是用户事后唯一的查证途径（§5.4）。
                    Text("哪些要授权的能力被用过、谁用的。")
                }
                .groupedRow()

                Section {
                    Button("打开系统设置", action: openSystemSettings)
                } footer: {
                    Text("开过之后要改或者收回，都在「设置」里。iOS 的授权框每个 App 一生只出现一次，拒绝之后也只能回那里打开。")
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
        .alert("没能打开", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func load() {
        capabilities = NativeCapability.all
        for capability in capabilities where capability.canWrite {
            policies[capability.id] = DshNativeWritePolicyFor(capability.id)
        }
        refreshPermissions()
    }

    /// 让用户亲自开一项。这是 App 里唯一一处会把系统授权框叫出来的调用。
    private func enable(_ capability: NativeCapability) {
        guard let permission = capability.systemPermission, requesting == nil else { return }
        requesting = permission
        // 回调按约定在主线程上，但那是 ObjC 头里的承诺，Swift 的并发检查看不见，
        // 所以照这页另一处的写法再过一次 MainActor。
        DshNativeRequestPermission(permission) { _, error in
            Task { @MainActor in
                requesting = nil
                // 用户说「不允许」时 error 是空的：那不是故障，刷新后这一项会显示
                // 「已关闭」，并给出去系统设置的路。
                if let error, !error.isEmpty { failure = error }
                refreshPermissions()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
        case .notNeeded: return "随时可用"
        // 以前这里写的是「首次使用时询问」。现在没人会去问了——不开就是不能用。
        case .notDetermined: return "未开启"
        case .allowed: return "已开启"
        case .denied: return "已关闭"
        case .insufficient(let detail): return detail
        }
    }

    /// 用户动一下就能解决的那几档。决定右边给按钮还是给状态字。
    var action: CapabilityAction {
        switch self {
        case .notNeeded, .allowed: return .none
        case .notDetermined: return .enable
        case .denied, .insufficient: return .settings
        }
    }

    var isAllowed: Bool { if case .allowed = self { return true } else { return false } }
}

enum CapabilityAction { case none, enable, settings }

/// 一项本机能力，连同它的中文说明。
struct NativeCapability: Identifiable {
    static let notificationPermission = "notifications"
    static let calendarPermission = "calendar"
    static let remindersPermission = "reminders"

    let id: String
    let ops: [String]
    /// 需要的 iOS 授权；为空表示不需要任何授权。
    let systemPermission: String?
    /// 会改用户自己数据的那些操作。空的话这项只读，不需要写入开关。
    let writeOps: [String]

    var canWrite: Bool { !writeOps.isEmpty }

    /// addon 的能力表。表在二进制里是固定的，读一次就够——设置页那行计数会随
    /// SwiftUI 每次重绘求值，不该每次都过一遍桥。
    static let all: [NativeCapability] = DshNativeCapabilityList().map { entry in
        NativeCapability(
            id: entry["id"] as? String ?? "",
            ops: entry["ops"] as? [String] ?? [],
            systemPermission: entry["systemPermission"] as? String,
            writeOps: entry["writeOps"] as? [String] ?? []
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
        case "open": return String(localized: "打开链接")
        case "nlp": return String(localized: "文本分析")
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
        case "open": return String(localized: "用对应的 App 打开地图、邮件草稿、电话号码或网页")
        case "nlp": return String(localized: "认语言、分词、情绪、认出人名地名。全在本机算，不出手机")
        case "calendar": return String(localized: "查看你的日程，并按你设的写入方式增删改")
        case "reminders": return String(localized: "查看「提醒事项」里的待办，并按你设的写入方式增删改")
        default: return ops.joined(separator: " · ")
        }
    }

    /// 不认识的能力也有个图标，不然新能力那一行会缺一块。
    var icon: String {
        switch id {
        case "device": return "iphone"
        case "notify": return "bell"
        case "speak": return "speaker.wave.2"
        case "open": return "arrow.up.forward.app"
        case "nlp": return "text.magnifyingglass"
        case "calendar": return "calendar"
        case "reminders": return "checklist"
        default: return "square.grid.2x2"
        }
    }
}

extension DshWritePolicy {
    var label: LocalizedStringResource {
        switch self {
        case .confirm: return "每次确认"
        case .blocked: return "不允许"
        // 默认档。叫「直接执行」而不是「允许」，因为用户要知道的是"不会再问我"，
        // 不是"有权限"——权限那一栏在同一行的右边，两件事别混。
        default: return "直接执行"
        }
    }
}

private struct CapabilityRow: View {
    let capability: NativeCapability
    let permission: CapabilityPermission
    let policy: DshWritePolicy
    let busy: Bool
    let enable: () -> Void
    let setPolicy: (DshWritePolicy) -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 开着的那几项用实心底，扫一眼就知道这台手机上开了哪些。
            Image(systemName: capability.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(permission.isAllowed ? Palette.onInk : Palette.secondary)
                .frame(width: 30, height: 30)
                .background(
                    permission.isAllowed ? Palette.ink : Palette.control,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title).foregroundStyle(Palette.ink)
                Text(capability.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if permission.action == .settings {
                    Text(permission.label)
                        .font(.footnote)
                        .foregroundStyle(Palette.ink)
                }
                // 只在这项真的能改用户数据、而且已经开着的时候才出现：没开的
                // 能力给个写入开关，是在问一个还不成立的问题。
                if capability.canWrite, permission.isAllowed {
                    Menu {
                        Picker("写入", selection: Binding(get: { policy }, set: setPolicy)) {
                            Text(DshWritePolicy.direct.label).tag(DshWritePolicy.direct)
                            Text(DshWritePolicy.confirm.label).tag(DshWritePolicy.confirm)
                            Text(DshWritePolicy.blocked.label).tag(DshWritePolicy.blocked)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("写入").foregroundStyle(Palette.secondary)
                            Text(policy.label).foregroundStyle(Palette.ink)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                                .foregroundStyle(Palette.faint)
                        }
                        .font(.footnote)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        switch permission.action {
        case .none:
            Text(permission.label)
                .font(.footnote)
                .foregroundStyle(permission.isAllowed ? Palette.ink : Palette.faint)
        case .enable:
            Button(action: enable) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 44)
                } else {
                    Text("开启").font(.footnote.weight(.medium))
                }
            }
            .buttonStyle(CapabilityActionStyle(filled: true))
            .disabled(busy)
        case .settings:
            Button("去设置", action: openSettings)
                .buttonStyle(CapabilityActionStyle(filled: false))
        }
    }
}

/// 列表行里的小胶囊按钮。实心是「这是你该点的那个」，描边是「去别处处理」。
private struct CapabilityActionStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .foregroundStyle(filled ? Palette.onInk : Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if filled {
                    Capsule().fill(Palette.ink)
                } else {
                    Capsule().strokeBorder(Palette.stroke, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            // 列表行自己也可点时，按钮要把点击吃掉，不然点「开启」会连带触发整行。
            .contentShape(Capsule())
    }
}
