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
/// 条链上最强的一道，而且不要钱。改和删系统没有现成界面可借，只能我们自己弹
/// 确认框，所以框里的摘要是原生按事件现状拼的，不是照搬调用方说的话（§4.3.1）。
@objc final class NativeBridge: NSObject {
    @objc static let shared = NativeBridge()

    /// 事件编辑器的 delegate 是 weak 的，而且一次只可能开一个，所以回调存在这里。
    private var editorCompletion: ((String?, String?, String?) -> Void)?

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
            presenter.present(controller, animated: true)
        }
    }

    @objc(confirmChange:destructive:completion:)
    func confirmChange(
        _ summary: String,
        destructive: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard let presenter = Self.topViewController() else {
                completion(false)
                return
            }
            let alert = UIAlertController(
                title: destructive ? String(localized: "删除这个日程？") : String(localized: "修改这个日程？"),
                // 摘要是这个框里唯一可信的信息：它是原生按事件现状拼的。
                message: summary,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { _ in
                completion(false)
            })
            alert.addAction(UIAlertAction(
                title: destructive ? String(localized: "删除") : String(localized: "修改"),
                style: destructive ? .destructive : .default
            ) { _ in
                completion(true)
            })
            presenter.present(alert, animated: true)
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
        let completion = editorCompletion
        editorCompletion = nil
        controller.dismiss(animated: true) {
            completion?(name, identifier, nil)
        }
    }
}
