import AlarmKit
import Foundation
import SwiftUI

/// alarm 能力的实现。
///
/// 为什么只有这一个能力要绕这么一圈：AlarmKit 根本没有 ObjC 接口 —— 它的
/// umbrella header 只导出两个版本号符号，公开面全是带协议约束的泛型、
/// `async throws`、`AsyncSequence` 和 ActivityKit / SwiftUI 的类型，ObjC 里一个
/// 都表达不出来。不是少了个头文件可以绕，是压根没有东西可声明。所以
/// `caps_alarm.m` 只是个转发壳，真正调框架的在这里。
///
/// **这个类不做任何决策。** 参数校验、没授权时的拒绝、写确认、审计摘要，全都在
/// `caps_alarm.m` 里做完了才会调到这里。写确认尤其不能挪过来：它必须留在原生侧
/// 那条唯一的路上，插件才拦不住、绕不开（§4.3）。这里只负责两件事 —— 把已经批准
/// 的事做掉，以及如实回答当前的授权状态。
///
/// 下面每个 `@objc` 方法都只做一件事：分版本。AlarmKit 要 iOS 26，而 App 的部署
/// 目标是 17，所以真正用到框架的代码全在底下那个 `@available(iOS 26.0, *)` 的
/// extension 里，老系统上一句都碰不到。
@objc final class AlarmProvider: NSObject {
    @objc static let shared = AlarmProvider()

    private override init() { super.init() }

    /// 启动时登记，和 `NativeBridge.install()` 一起、在引擎起来之前。
    ///
    /// **iOS 17–25 上也要登记。** 不登记的话 `caps_alarm.m` 只能报「App 没装这个
    /// 服务」，那是句用户听不懂、也帮不上他的话；登记上之后它会如实报
    /// `unsupported`，模型就能说「你的系统版本还不够，要 iOS 26」，而不是「你没
    /// 开权限」——后者会把用户送进设置里去找一个他机器上根本不存在的开关。
    @objc static func install() {
        DshAlarmSetProvider(shared)
    }

    /// 闹钟响起时那一屏的主色。用字面量而不是 asset 名：这个值要和 widget
    /// extension 里的呈现对得上，而两个 target 的 asset catalog 不是一份。取的是
    /// App 的 StatusWaiting 橙色。
    static let tint = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
}

// MARK: - 标题

/// 闹钟标题存在这里。
///
/// AlarmKit 的 `Alarm` 不带标题 —— 标题在 `AlarmAttributes.presentation` 里，而
/// 那个结构是单向的，排进去就读不回来了。于是 `list` 不自己记的话只能报「你有个
/// 20:00 的闹钟」，对用户基本没用；取消时的确认框和使用记录也就没东西可写，而
/// 那个摘要恰恰是框里唯一可信的信息（§4.3.1）。
///
/// 这不算 §4.5 砍掉的第三类「替调用方解释」：没有挑、没有过滤、没有改写，只是把
/// 当时被告知的标题记住再原样报回去。每次 `list` 按 AlarmKit 现有的闹钟剪一遍，
/// 所以它不会越长越大，也不会留着早就不存在的闹钟的标题。
private enum AlarmTitleStore {
    private static let key = "dsh.alarm.titles"

    static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func title(for id: UUID) -> String? {
        all()[id.uuidString]
    }

    static func put(_ title: String, for id: UUID) {
        var map = all()
        map[id.uuidString] = title
        UserDefaults.standard.set(map, forKey: key)
    }

    /// 只留下还存在的那些。
    static func keepOnly(_ ids: Set<String>) {
        let map = all()
        let kept = map.filter { ids.contains($0.key) }
        if kept.count != map.count { UserDefaults.standard.set(kept, forKey: key) }
    }
}

// MARK: - 星期

/// 线上的名字和 `Locale.Weekday` 之间显式对照，不走 `rawValue`。
///
/// 线上这套名字是我们自己定的，不该跟着 Foundation 内部的 raw value 走 —— 它改
/// 一次，我们的工具参数就跟着破一次，而调用方那边是硬编码的字符串。
@available(iOS 26.0, *)
private let dshAlarmWeekdays: [(name: String, day: Locale.Weekday)] = [
    ("monday", .monday), ("tuesday", .tuesday), ("wednesday", .wednesday),
    ("thursday", .thursday), ("friday", .friday), ("saturday", .saturday), ("sunday", .sunday),
]

@available(iOS 26.0, *)
private func dshAlarmDays(from names: [String]) -> [Locale.Weekday] {
    names.compactMap { name in dshAlarmWeekdays.first { $0.name == name }?.day }
}

@available(iOS 26.0, *)
private func dshAlarmNames(from days: [Locale.Weekday]) -> [String] {
    days.compactMap { day in dshAlarmWeekdays.first { $0.day == day }?.name }
}

// MARK: - DshAlarmProviding

extension AlarmProvider: DshAlarmProviding {
    /// 只读，绝不弹框：能力页每次出现都会读一次这个状态（§5.5）。
    @objc(alarmAuthorizationState:)
    func alarmAuthorizationState(_ done: @escaping (String) -> Void) {
        if #available(iOS 26.0, *) {
            done(AlarmProvider.currentState())
        } else {
            done(DshAlarmAuthorizationUnsupported)
        }
    }

    @objc(requestAlarmAuthorization:)
    func requestAlarmAuthorization(_ done: @escaping (Bool, String?) -> Void) {
        if #available(iOS 26.0, *) {
            AlarmProvider.request(done)
        } else {
            // 走不到：`DshAlarmGrantAccess` 会先问状态，`unsupported` 就自己答了，
            // 不会调到这里。留着是因为一个 API 不该靠调用顺序才安全。
            done(false, nil)
        }
    }

    @objc(listAlarmsWithCompletion:)
    func listAlarms(completion done: @escaping ([[String: Any]]?, String?) -> Void) {
        if #available(iOS 26.0, *) {
            AlarmProvider.list(done)
        } else {
            // 同样走不到：`caps_alarm.m` 会先卡在授权检查上。
            done([], nil)
        }
    }

    // 标签是 Swift 的 ObjC 导入器定的：`createAlarmWithTitle:` 推出来的第一个
    // 标签是 `withTitle:`，不是 `title:`。和 NativeBridge.swift 里那条注释同一
    // 个坑——selector 注解和参数标签是两件事，写对一个不等于写对另一个。
    @objc(createAlarmWithTitle:hour:minute:weekdays:completion:)
    func createAlarm(
        withTitle title: String,
        hour: Int,
        minute: Int,
        weekdays: [String]?,
        completion done: @escaping (String?, String?) -> Void
    ) {
        if #available(iOS 26.0, *) {
            AlarmProvider.create(title: title, hour: hour, minute: minute, weekdays: weekdays, done: done)
        } else {
            done(nil, nil)
        }
    }

    @objc(cancelAlarmWithIdentifier:completion:)
    func cancelAlarm(withIdentifier identifier: String, completion done: @escaping (String?) -> Void) {
        if #available(iOS 26.0, *) {
            AlarmProvider.cancel(identifier: identifier, done: done)
        } else {
            done(nil)
        }
    }
}

// MARK: - AlarmKit

@available(iOS 26.0, *)
extension AlarmProvider {
    static func currentState() -> String {
        switch AlarmManager.shared.authorizationState {
        case .authorized: DshAlarmAuthorizationAuthorized
        case .denied: DshAlarmAuthorizationDenied
        case .notDetermined: DshAlarmAuthorizationNotDetermined
        // 以后多出来的状态按「还没问过」处理：那一档只会让能力拒绝、让用户自己去
        // 开，是这几个方向里出错代价最小的。
        @unknown default: DshAlarmAuthorizationNotDetermined
        }
    }

    static func request(_ done: @escaping (Bool, String?) -> Void) {
        Task {
            do {
                let state = try await AlarmManager.shared.requestAuthorization()
                // 「用户点了不允许」不是错误，所以 error 给 nil：那句话归能力页说，
                // 它是三语的，而这个文件不是（§5.5）。
                done(state == .authorized, nil)
            } catch {
                done(false, error.localizedDescription)
            }
        }
    }

    static func list(_ done: @escaping ([[String: Any]]?, String?) -> Void) {
        do {
            let alarms = try AlarmManager.shared.alarms
            AlarmTitleStore.keepOnly(Set(alarms.map { $0.id.uuidString }))
            done(alarms.map { describe($0) }, nil)
        } catch {
            done(nil, error.localizedDescription)
        }
    }

    static func create(
        title: String,
        hour: Int,
        minute: Int,
        weekdays: [String]?,
        done: @escaping (String?, String?) -> Void
    ) {
        let days = dshAlarmDays(from: weekdays ?? [])
        let schedule = Alarm.Schedule.relative(
            Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(hour: hour, minute: minute),
                // 不给星期就是一次性的：AlarmKit 自己排到那个时间的下一次。
                repeats: days.isEmpty ? .never : .weekly(days)
            )
        )
        let attributes = AlarmAttributes<DshAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert(titled: title)),
            metadata: DshAlarmMetadata(label: title),
            tintColor: tint
        )
        let configuration = AlarmManager.AlarmConfiguration<DshAlarmMetadata>.alarm(
            schedule: schedule,
            attributes: attributes
        )
        Task {
            do {
                let alarm = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
                AlarmTitleStore.put(title, for: alarm.id)
                done(alarm.id.uuidString, nil)
            } catch {
                // AlarmKit 的 `maximumLimitReached` 也从这里原样出去。上限是多少、
                // 该删哪个才腾得出位置，是调用方对用户的判断，不是我们的（§4.5）。
                done(nil, error.localizedDescription)
            }
        }
    }

    static func cancel(identifier: String, done: @escaping (String?) -> Void) {
        guard let id = UUID(uuidString: identifier) else {
            done("that id is not one this app hands out")
            return
        }
        do {
            try AlarmManager.shared.cancel(id: id)
            done(nil)
        } catch {
            done(error.localizedDescription)
        }
    }

    static func alert(titled title: String) -> AlarmPresentation.Alert {
        // 闹钟标题是智能体写的运行时文本，不是界面文案，所以走
        // `LocalizedStringResource(stringLiteral:)`：查不到对应的键时它按字面显示，
        // 正好是我们要的结果。
        let label = LocalizedStringResource(stringLiteral: title)
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: label)
        }
        // 26.0 上没有那个干净的构造器，只能带 stopButton —— 26.1 起它被标为弃用且
        // 不再使用。嫌这条弃用警告吵的话，把这个类型的门槛提到 26.1、删掉这一段
        // 即可，代价只是 26.0 这一个小版本。
        return AlarmPresentation.Alert(
            title: label,
            stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
        )
    }

    /// 一个闹钟报给调用方的样子。按 AlarmKit 给的原样转发，不挑不改（§4.5）。
    static func describe(_ alarm: Alarm) -> [String: Any] {
        var entry: [String: Any] = ["id": alarm.id.uuidString, "state": stateName(alarm.state)]
        if let title = AlarmTitleStore.title(for: alarm.id) { entry["title"] = title }
        if let schedule = alarm.schedule {
            switch schedule {
            case .relative(let relative):
                entry["hour"] = relative.time.hour
                entry["minute"] = relative.time.minute
                if case .weekly(let days) = relative.repeats, !days.isEmpty {
                    entry["repeatWeekdays"] = dshAlarmNames(from: days)
                }
            case .fixed(let date):
                entry["at"] = date.timeIntervalSince1970
            @unknown default:
                break
            }
        }
        return entry
    }

    static func stateName(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: "scheduled"
        case .countdown: "countdown"
        case .paused: "paused"
        case .alerting: "alerting"
        @unknown default: "unknown"
        }
    }
}
