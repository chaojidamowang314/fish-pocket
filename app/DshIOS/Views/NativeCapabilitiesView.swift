import SwiftUI
import Contacts
import CoreLocation
import EventKit
import HealthKit
import MediaPlayer
import Speech
import Photos
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
    /// iOS 管不到、由 App 自己把门的那几项，开没开。
    @State private var appEnabled: [String: Bool] = [:]
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
                        permission: capability.appGated
                            ? (appEnabled[capability.id] == true ? .allowed : .notDetermined)
                            : (capability.systemPermission.flatMap { permissions[$0] } ?? .notNeeded),
                        policy: policies[capability.id] ?? .direct,
                        busy: requesting != nil && requesting == capability.systemPermission,
                        enabled: capability.appGated ? (appEnabled[capability.id] ?? false) : nil,
                        setEnabled: { on in
                            DshNativeSetCapabilityEnabled(capability.id, on)
                            appEnabled[capability.id] = on
                        },
                        enable: { enable(capability) },
                        setPolicy: { policies[capability.id] = $0; DshNativeSetWritePolicy(capability.id, $0) },
                        openSettings: openSystemSettings,
                        openHealth: openHealthApp
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
                    Text("开过之后要改或者收回，都在「设置」里。iOS 的授权框每个 App 一生只出现一次，拒绝之后也只能回那里打开。健康数据是例外，要在「健康」App 里改。")
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
        for capability in capabilities where capability.appGated {
            appEnabled[capability.id] = DshNativeCapabilityEnabled(capability.id)
        }
        refreshPermissions()
    }

    /// 让用户亲自开一项。这是 App 里唯一一处会把系统授权框叫出来的调用。
    private func enable(_ capability: NativeCapability) {
        // 没有系统授权可问的那几项，开关就在本机：按下就是开了。
        if capability.appGated {
            DshNativeSetCapabilityEnabled(capability.id, true)
            appEnabled[capability.id] = true
            return
        }
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

    /// 健康数据的授权不在本 App 的系统设置页里，只在「健康」App 里能逐项改。
    /// 「健康」打不开的机器（比如 iPad 上没装）才退回系统设置，总比按了没反应强。
    private func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { openSystemSettings() }
        }
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
        if needed.contains(NativeCapability.locationPermission) {
            // Synchronous, like EventKit: reading the status costs nothing and
            // raises nothing. Only `requestWhenInUseAuthorization` shows a dialog.
            permissions[NativeCapability.locationPermission] = .ofLocation(CLLocationManager().authorizationStatus)
        }
        if needed.contains(NativeCapability.speechPermission) {
            permissions[NativeCapability.speechPermission] = .ofSpeech(SFSpeechRecognizer.authorizationStatus())
        }
        if needed.contains(NativeCapability.photosPermission) {
            permissions[NativeCapability.photosPermission] =
                .ofPhotos(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
        if needed.contains(NativeCapability.contactsPermission) {
            permissions[NativeCapability.contactsPermission] =
                .ofContacts(CNContactStore.authorizationStatus(for: .contacts))
        }
        if needed.contains(NativeCapability.musicPermission) {
            permissions[NativeCapability.musicPermission] = .ofMusic(MPMediaLibrary.authorizationStatus())
        }
        if needed.contains(NativeCapability.alarmPermission), let alarms = DshAlarmCurrentProvider() {
            // 闹钟的状态在 Swift 提供方手里（AlarmKit 没有 ObjC 接口）。这个查询只读
            // 不弹框。漏了它的话这一行会落到「随时可用」，连「开启」按钮都没有。
            alarms.alarmAuthorizationState { state in
                Task { @MainActor in
                    permissions[NativeCapability.alarmPermission] = .ofAlarm(state)
                }
            }
        }
        if needed.contains(NativeCapability.homeKitPermission) {
            // HomeKit has no free status query — creating the manager IS the
            // prompt — so this asks what the app has already seen iOS answer.
            permissions[NativeCapability.homeKitPermission] = DshHomeKitAccessGranted()
                ? .allowed
                : (DshHomeKitAccessRefused() ? .denied : .notDetermined)
        }
        if needed.contains(NativeCapability.healthPermission) {
            // The only capability that cannot report whether it was allowed.
            DshHealthRequestStatus { status in
                Task { @MainActor in
                    // 1 is "would still ask"; 2 is "has been asked", which is NOT
                    // "was allowed" and must never be shown as 已开启.
                    permissions[NativeCapability.healthPermission] = status == 2 ? .asked : .notDetermined
                }
            }
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
    /// 问过了，但**系统不肯说用户答了什么**。健康数据是这一档，而且只有这一档：
    /// Apple 故意不让 App 查询读权限的状态，因为「能不能读到某一项」本身就会
    /// 泄露用户有没有这项数据。所以这里既不能写「已开启」也不能写「已关闭」——
    /// 两种都是我们不知道的事，写哪个都是在骗人。
    case asked
    /// 这台机器的系统版本不支持这项能力。闹钟要 iOS 26，而部署目标是 17。
    /// 这一档既不是「没开」也不是「关了」——用户做什么都没用，所以不能给他
    /// 一个点了毫无反应的「开启」按钮。
    case unsupported(LocalizedStringResource)

    static func ofNotifications(_ status: UNAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    static func ofSpeech(_ status: SFSpeechRecognizerAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    static func ofPhotos(_ status: PHAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .authorized: return .allowed
        // 「仅选择照片…」确实是授权了，但说「已开启」会让用户以为智能体看得到
        // 整个相册。它看得到的只有用户挑的那几张，这一行得说实话。
        case .limited: return .insufficient("仅限你分享的那几张")
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    static func ofContacts(_ status: CNAuthorizationStatus) -> CapabilityPermission {
        // iOS 18 起可以只分享几位联系人。和照片的「仅选择」是一回事：查不到某个人
        // 不等于通讯录里没有他，这一行不能写成「已开启」。
        if #available(iOS 18.0, *), status == .limited { return .insufficient("仅限你分享的那几位") }
        switch status {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    static func ofMusic(_ status: MPMediaLibraryAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    static func ofAlarm(_ state: String) -> CapabilityPermission {
        switch state {
        case DshAlarmAuthorizationAuthorized: return .allowed
        case DshAlarmAuthorizationDenied: return .denied
        case DshAlarmAuthorizationUnsupported: return .unsupported("需要 iOS 26")
        default: return .notDetermined
        }
    }

    static func ofLocation(_ status: CLAuthorizationStatus) -> CapabilityPermission {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        case .denied, .restricted: return .denied
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
        case .asked: return "已询问"
        case .unsupported(let why): return why
        }
    }

    /// 用户动一下就能解决的那几档。决定右边给按钮还是给状态字。
    var action: CapabilityAction {
        switch self {
        case .notNeeded, .allowed: return .none
        case .notDetermined: return .enable
        case .denied, .insufficient: return .settings
        // 再点一次「开启」不会再弹框（iOS 一生只问一次）。能逐项查看和改的地方
        // 在「健康」App 里，不在本 App 的系统设置页——那一页根本没有健康这一项，
        // 把人送过去等于让他白找一趟。
        case .asked: return .health
        // 系统设置里也没有这一项可开，给「去设置」同样是空指望。
        case .unsupported: return .none
        }
    }

    var isAllowed: Bool { if case .allowed = self { return true } else { return false } }

    /// 写入开关只在确定开着的时候才有意义。`.asked` 不算——我们并不知道它开着。
    var showsWriteSetting: Bool { isAllowed }
}

enum CapabilityAction { case none, enable, settings, health }

/// 一项本机能力，连同它的中文说明。
struct NativeCapability: Identifiable {
    static let notificationPermission = "notifications"
    static let locationPermission = "location"
    static let speechPermission = "speech"
    static let healthPermission = "health"
    static let homeKitPermission = "homekit"
    static let photosPermission = "photos"
    static let calendarPermission = "calendar"
    static let remindersPermission = "reminders"
    static let contactsPermission = "contacts"
    static let alarmPermission = "alarm"
    static let musicPermission = "music"

    let id: String
    let ops: [String]
    /// 需要的 iOS 授权；为空表示不需要任何授权。
    let systemPermission: String?
    /// 会改用户自己数据的那些操作。空的话这项只读，不需要写入开关。
    let writeOps: [String]
    /// iOS 没有对应授权可问，由 App 自己把门——剪贴板就是这种。
    let appGated: Bool

    var canWrite: Bool { !writeOps.isEmpty }

    /// addon 的能力表。表在二进制里是固定的，读一次就够——设置页那行计数会随
    /// SwiftUI 每次重绘求值，不该每次都过一遍桥。
    static let all: [NativeCapability] = DshNativeCapabilityList().map { entry in
        NativeCapability(
            id: entry["id"] as? String ?? "",
            ops: entry["ops"] as? [String] ?? [],
            systemPermission: entry["systemPermission"] as? String,
            writeOps: entry["writeOps"] as? [String] ?? [],
            appGated: entry["appGated"] as? Bool ?? false
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
        case "maps": return String(localized: "地图")
        case "vision": return String(localized: "图像识别")
        case "clipboard": return String(localized: "剪贴板")
        case "location": return String(localized: "位置")
        case "transcribe": return String(localized: "语音转写")
        case "health": return String(localized: "健康")
        case "homekit": return String(localized: "智能家居")
        case "photos": return String(localized: "照片")
        case "alarm": return String(localized: "闹钟")
        case "contacts": return String(localized: "通讯录")
        case "compose": return String(localized: "写邮件和短信")
        case "files": return String(localized: "文件")
        case "music": return String(localized: "音乐")
        case "weather": return String(localized: "天气")
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
        case "nlp": return String(localized: "认语言、认出人名地名、按意思给一堆文字排序。全在本机算，不出手机")
        case "maps": return String(localized: "搜地点、算路线和到达时间。不读你的位置")
        case "vision": return String(localized: "认出图里的文字、二维码和内容。全在本机算，图片不上传")
        case "clipboard": return String(localized: "读你复制的内容。每次读取 iOS 都会提示你")
        case "location": return String(localized: "问到的时候读一次当前位置。不持续记录，也没有轨迹")
        case "transcribe": return String(localized: "把录音文件里说的话转成文字。默认只在本机识别，录音不上传")
        case "health": return String(localized: "读「健康」里的步数、睡眠、心率等。只读，绝不写入")
        case "homekit": return String(localized: "查看家里有哪些配件和它们的状态，并按你设的写入方式改状态、跑场景")
        case "photos": return String(localized: "查看相册里有哪些照片，并把你指定的一张导出给本机识别。不增不改不删")
        case "alarm": return String(localized: "让智能体设真正的闹钟。和通知不同，闹钟会穿透静音和专注模式，响到你关掉为止")
        case "contacts": return String(localized: "按名字、电话或邮箱查联系人。只读，不增不改不删")
        case "compose": return String(localized: "把邮件或短信替你填好，弹出系统的发送页。发不发由你点，智能体自己发不出去")
        case "files": return String(localized: "请你从「文件」里挑文件交给智能体，或把它做好的文件存到你选的位置。它只拿得到你挑的那几个")
        case "music": return String(localized: "在你的音乐资料库里找歌和歌单，并按你设的写入方式播放、暂停、切歌")
        case "weather": return String(localized: "查某个地点的实时天气和预报，数据来自 Apple 天气。不读你的位置")
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
        case "maps": return "map"
        case "vision": return "eye"
        case "clipboard": return "doc.on.clipboard"
        case "location": return "location"
        case "transcribe": return "waveform"
        case "health": return "heart"
        case "homekit": return "house"
        case "photos": return "photo"
        case "alarm": return "alarm.waves.left.and.right"
        case "contacts": return "person.crop.circle"
        case "compose": return "envelope"
        case "files": return "folder"
        case "music": return "music.note"
        case "weather": return "cloud.sun"
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
    /// nil unless this capability is gated by the app rather than by iOS.
    let enabled: Bool?
    let setEnabled: (Bool) -> Void
    let enable: () -> Void
    let setPolicy: (DshWritePolicy) -> Void
    let openSettings: () -> Void
    let openHealth: () -> Void

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
                if permission.action == .settings || permission.action == .health {
                    Text(permission.label)
                        .font(.footnote)
                        .foregroundStyle(Palette.ink)
                }
                // 「已询问」三个字单独摆着没人看得懂，必须跟一句为什么只能这么说。
                if case .asked = permission {
                    Text("iOS 不告诉 App 你允许了哪几项健康数据，所以这里只能说问过了。要逐项查看和更改：打开「健康」App，点右上角的头像，在「隐私」下面进「App」，再选 Fish Pocket。")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 只在这项真的能改用户数据、而且已经开着的时候才出现：没开的
                // 能力给个写入开关，是在问一个还不成立的问题。
                if capability.canWrite, permission.showsWriteSetting {
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
        // iOS has nothing to ask about these, so the switch is ours and it has to
        // turn off as easily as it turns on. A one-way "Turn On" button would
        // leave the user no way back except deleting the app.
        if let enabled {
            Toggle("", isOn: Binding(get: { enabled }, set: setEnabled))
                .labelsHidden()
        } else {
            systemTrailing
        }
    }

    @ViewBuilder
    private var systemTrailing: some View {
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
        case .health:
            Button("打开健康", action: openHealth)
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
