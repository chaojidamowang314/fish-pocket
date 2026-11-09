import Foundation
import StoreKit

/// Where this copy of the app came from. Only an App Store install can be rated there, so the
/// rating asks (`SupportPrompt`, 设置 › 给个评分) go to it alone.
@MainActor
enum AppDistribution {
    enum Channel: String {
        case appStore
        case testFlight
        /// Xcode, the simulator, a re-signed or sideloaded copy, or not known yet.
        case other
    }

    private static let channelKey = "dsh.distribution.channel"

    /// The last answer StoreKit gave, so it is there at once on the next launch; `other`
    /// until one comes. An install can move from TestFlight to the App Store, so each launch asks again.
    private(set) static var channel = Channel(rawValue: UserDefaults.standard.string(forKey: channelKey) ?? "") ?? .other

    /// App Store and TestFlight installs carry no provisioning profile; anything
    /// signed by hand does. Simulator builds have none either, and are not Apple's.
    nonisolated static var deliveredByApple: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil
        #endif
    }

    /// StoreKit's signed record of this install says which store delivered it: production is the
    /// App Store, sandbox is TestFlight. When it can't be had (offline on a first launch), the
    /// cached answer stays.
    static func refresh() async {
        guard deliveredByApple else { return remember(.other) }
        guard let result = try? await AppTransaction.shared else { return }
        let environment = switch result {
        case .verified(let transaction), .unverified(let transaction, _): transaction.environment
        }
        remember(environment == .production ? .appStore : environment == .sandbox ? .testFlight : .other)
    }

    private static func remember(_ value: Channel) {
        channel = value
        UserDefaults.standard.set(value.rawValue, forKey: channelKey)
    }
}
