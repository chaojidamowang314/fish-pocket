import EventKit
import EventKitUI
import SwiftUI

/// 本机能力里需要用户亲自点一下的那些操作，都从这里出去。
///
/// 为什么写操作一定要经过这里：iOS 给的日历权限是读写一起给的（§4.0），所以
/// 「智能体能看我的日程但不会乱改」这件事系统不管，只能我们自己兜。兜法就是
/// **决策不离开原生侧**——addon 调到这里、等用户答复、再动手，中间没有任何
/// 东西经过 JS，插件既拦不住也替不了用户点（docs/native-services.md §4.3）。
///
/// 新建走系统自带的事件编辑器：那是 Apple 的界面、Apple 的「添加」按钮，是这
/// 条链上最强的一道。改和删系统没有现成界面可借，只能我们自己弹确认框，所以
/// 框里的摘要是原生按事件现状拼的，不是照搬调用方说的话（§4.3.1）。
///
/// **这里的每一条路都必须有结果。** addon 那边是一个在等的 Promise，界面没答复
/// 就是插件永远卡住——挂死比报错坏得多，因为报错至少能说给用户听。事件编辑器
/// 是跨进程扩展（`EventKitUIRemoteUIExtension`），它可以在不走代理回调的情况下
/// 自己消失，所以每个等待都配一个看门狗（§4.3.2）。
@objc final class NativeBridge: NSObject {
    @objc static let shared = NativeBridge()

    /// 事件编辑器的 delegate 是 weak 的，而且一次只可能开一个，所以回调存在这里。
    /// 只在主线程上读写。
    private var editorCompletion: ((String?, String?, String?) -> Void)?
    private weak var editorController: UIViewController?
    private var editorWatchdog: DispatchSourceTimer?

    private override init() { super.init() }

    /// 启动时登记。登记本身不碰 UI，所以多早都行；真正要窗口是在弹出来的时候。
    @objc static func install() {
        DshNativeSetBridge(shared)
    }

    /// 和 App 里另外几处一样的找法：优先前台场景，没有就退而求其次。
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// 收尾，只做一次。代理回调和看门狗都走这里，谁先到算谁的。
    private func finishEditor(action: String?, identifier: String?, error: String?) {
        guard let completion = editorCompletion else { return }
        editorCompletion = nil
        editorController = nil
        editorWatchdog?.cancel()
        editorWatchdog = nil
        completion(action, identifier, error)
    }

    /// 盯着那个已经弹出来的界面。它还在窗口上就继续等人答复；窗口没了却没人
    /// 答复，说明它是被收走的——那就替它收尾，别让调用方一直等。
    ///
    /// 用轮询而不是通知，是因为要盯的那个 controller 是远端视图的代理，它的生命
    ///周期不归我们管，没有一个可靠的「它被收走了」事件可以订阅。
    private func watchForSilentDismissal(of controller: UIViewController,
                                         finish: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak controller] in
            // 刚 present 完还没上屏的那一拍不算，所以看的是「上过屏之后没了」。
            guard let controller else { finish(); return }
            if controller.viewIfLoaded?.window == nil && controller.presentingViewController == nil {
                finish()
            }
        }
        timer.resume()
        // 定时器归调用方拿着：编辑器和确认框可能同时开着（两个插件各调一个），
        // 共用一个成员变量会互相把对方的看门狗取消掉。
        return timer
    }
}

private extension NativeBridge {
    /// 框的标题按「能力 + 操作」写。以前它只知道 `destructive`，于是新建一条提醒
    /// 也问「修改这个日程？」——而这个框存在的全部意义就是把将要发生的事说准。
    /// 对照表和使用记录那张是同一套（`NativeAuditView`），因为说的是同一件事。
    static func confirmTitle(capability: String, op: String, destructive: Bool) -> String {
        switch (capability, op) {
        case ("calendar", "create"): return String(localized: "新建这个日程？")
        case ("calendar", "update"): return String(localized: "修改这个日程？")
        case ("calendar", "delete"): return String(localized: "删除这个日程？")
        case ("reminders", "create"): return String(localized: "新建这个提醒？")
        case ("reminders", "complete"): return String(localized: "把这个提醒标记为完成？")
        case ("reminders", "delete"): return String(localized: "删除这个提醒？")
        case ("alarm", "create"): return String(localized: "设这个闹钟？")
        case ("alarm", "cancel"): return String(localized: "取消这个闹钟？")
        case ("clipboard", "set"): return String(localized: "替换剪贴板的内容？")
        case ("clipboard", "clear"): return String(localized: "清空剪贴板？")
        case ("homekit", "set"): return String(localized: "改这个配件的状态？")
        case ("homekit", "trigger"): return String(localized: "执行这个场景？")
        // 新能力忘了加文案时，问句仍然成立，只是不够具体——总好过问错对象。
        default: return destructive ? String(localized: "删除这一条？") : String(localized: "确认这个改动？")
        }
    }

    /// 按操作选词，destructive 只做兜底——它决定的是按钮的样式（红色），不是
    /// 按钮上的字。先按 destructive 返回「删除」的话，关掉一个闹钟和清空剪贴板
    /// 都会写成「删除」，而那两件事都不是删除。
    static func confirmButton(op: String, destructive: Bool) -> String {
        switch op {
        case "create": return String(localized: "新建")
        case "complete": return String(localized: "标记完成")
        // 不能只说「取消」——那是框上另一个按钮的字，两个按钮都写「取消」时
        // 用户分不清哪个是「别动我的闹钟」。
        case "cancel": return String(localized: "关掉闹钟")
        case "trigger": return String(localized: "执行")
        case "clear": return String(localized: "清空")
        case "delete": return String(localized: "删除")
        default: return destructive ? String(localized: "删除") : String(localized: "修改")
        }
    }
}

extension NativeBridge: DshNativeBridging {
    // 标签是 Swift 的 ObjC 导入器定的：它把 `ForEvent:inStore:` 里的介词吃掉，
    // 协议要求的就是 `(for:in:completion:)`，和这里的 selector 注解并不冲突。
    @objc(presentEventEditorForEvent:inStore:completion:)
    func presentEventEditor(
        for event: EKEvent,
        in store: EKEventStore,
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        // addon 从 Node 线程或日历队列调进来，UIKit 只认主线程。
        DispatchQueue.main.async {
            guard let presenter = Self.topViewController() else {
                completion(nil, nil, "the app has no window to present the event editor in")
                return
            }
            // 已经开着一个就别再叠：两个编辑器同时在，用户分不清自己在答哪一个。
            guard self.editorCompletion == nil else {
                completion(nil, nil, "an event editor is already open; finish that one first")
                return
            }
            let controller = EKEventEditViewController()
            controller.eventStore = store
            controller.event = event
            controller.editViewDelegate = self
            self.editorCompletion = completion
            self.editorController = controller
            presenter.present(controller, animated: true) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.editorWatchdog = self.watchForSilentDismissal(of: controller) { [weak self] in
                    self?.finishEditor(
                        action: nil, identifier: nil,
                        // 说实话：不是用户取消的，是界面没了。模型会把这句读给用户。
                        error: "the event editor closed before the user answered it; nothing was added"
                    )
                }
            }
        }
    }

    @objc(confirmChange:capability:op:destructive:completion:)
    func confirmChange(
        _ summary: String,
        capability: String,
        op: String,
        destructive: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard let presenter = Self.topViewController() else {
                completion(false)
                return
            }
            // 和编辑器同理：框被连带收走时没人点按钮，调用方会一直等。没答复就
            // 当作没同意——这个方向上出错是安全的。
            var answered = false
            var watchdog: DispatchSourceTimer?
            let answer: (Bool) -> Void = { value in
                guard !answered else { return }
                answered = true
                watchdog?.cancel()
                watchdog = nil
                completion(value)
            }
            let alert = UIAlertController(
                title: Self.confirmTitle(capability: capability, op: op, destructive: destructive),
                // 摘要是这个框里唯一可信的信息：它是原生按记录现状拼的。
                message: summary,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { _ in
                answer(false)
            })
            alert.addAction(UIAlertAction(
                title: Self.confirmButton(op: op, destructive: destructive),
                style: destructive ? .destructive : .default
            ) { _ in
                answer(true)
            })
            presenter.present(alert, animated: true) { [weak self, weak alert] in
                guard let self, let alert else { return }
                watchdog = self.watchForSilentDismissal(of: alert) { answer(false) }
            }
        }
    }
}

extension NativeBridge: EKEventEditViewDelegate {
    func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
        // 先把事件 id 取出来：dismiss 之后 controller.event 就不该再读了。
        let identifier = action == .saved ? controller.event?.eventIdentifier : nil
        let name: String
        switch action {
        case .saved: name = DshNativeActionSaved
        case .deleted: name = DshNativeActionDeleted
        default: name = DshNativeActionCancelled
        }
        controller.dismiss(animated: true) { [weak self] in
            self?.finishEditor(action: name, identifier: identifier, error: nil)
        }
    }
}
