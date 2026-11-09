import Foundation

/// When to ask for a rating, a Star or a share, after Orca's star nag: only right after a turn
/// went well, a few turns in, and rarely. One ask at a time, and every ask starts the same wait:
/// three days and the turns again, so the system's rating sheet and our own card never follow
/// each other. An App Store install is asked for a rating first, once a version (Apple decides
/// whether the sheet shows, and says nothing either way). Then the Star / share card: an ignored
/// one waits twice the turns, the third is the last, and the first tap settles it, as GitHub
/// can't say from here who has starred.
@MainActor
enum SupportPrompt {
    enum Ask { case review, support }

    private static let turnsKey = "dsh.support.turns"
    private static let asksKey = "dsh.support.asks"
    private static let notBeforeKey = "dsh.support.notBefore"
    private static let settledKey = "dsh.support.settled"
    private static let reviewedKey = "dsh.support.reviewedVersion"

    private static let firstAsk = 5
    private static let lastAsk = 3
    private static let cooldown: TimeInterval = 3 * 24 * 60 * 60

    /// Counts a turn that finished well; true when an ask is due.
    static func noteCompletedTurn() -> Bool {
        guard reviewOpen || supportOpen else { return false }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: turnsKey) + 1, forKey: turnsKey)
        return due != nil
    }

    /// The ask to make now: each is spent here, whatever becomes of it.
    static func take() -> Ask? {
        guard let ask = due else { return nil }
        let defaults = UserDefaults.standard
        switch ask {
        case .review: defaults.set(version, forKey: reviewedKey)
        case .support: defaults.set(defaults.integer(forKey: asksKey) + 1, forKey: asksKey)
        }
        defaults.set(0, forKey: turnsKey)
        defaults.set(Date.now.addingTimeInterval(cooldown).timeIntervalSince1970, forKey: notBeforeKey)
        return ask
    }

    /// They went to the repository or the share page: never show the card again.
    static func settle() { UserDefaults.standard.set(true, forKey: settledKey) }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var reviewOpen: Bool {
        AppDistribution.channel == .appStore && UserDefaults.standard.string(forKey: reviewedKey) != version
    }

    private static var supportOpen: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: settledKey) && defaults.integer(forKey: asksKey) < lastAsk
    }

    private static var due: Ask? {
        let defaults = UserDefaults.standard
        guard Date.now.timeIntervalSince1970 >= defaults.double(forKey: notBeforeKey) else { return nil }
        let turns = defaults.integer(forKey: turnsKey)
        if reviewOpen && turns >= firstAsk { return .review }
        if supportOpen && turns >= firstAsk << defaults.integer(forKey: asksKey) { return .support }
        return nil
    }
}

/// The app's links, and the message that passes them on.
enum AppLinks {
    static let repository = URL(string: "https://github.com/\(UpdateChecker.repository)")!
    /// The website (for now a redirect to its VibeVibi page), which sends each reader on to the
    /// App Store or the public beta. The share poster's QR code is a picture of this link:
    /// scripts/make-share-qr.swift redraws it.
    static let site = URL(string: "https://fish-pocket.deepseek1024.com")!
    /// The App Store's 「撰写评论」 page for the app.
    static let writeReview = URL(string: "https://apps.apple.com/app/id6830703602?action=write-review")!

    /// What 「链接」 on the share page sends.
    static var shareText: String {
        String(localized: "Fish Pocket：在 iPhone 和 iPad 上本机运行 DeepSeek Harness，支持第三方插件市场，不连电脑，不连服务器。\n\(site.absoluteString)")
    }
}
