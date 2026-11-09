import Foundation

/// 「新功能」: what a version brings, shown once to those who updated to it, and kept under
/// 设置 → 关于. It is the highlights a reader would notice, not the change log, so a fix-only
/// release adds nothing here and shows nothing. An entry belongs to a version, or to one build
/// of it when a later build (TestFlight) brings more. Whoever reaches a version sees all of its
/// entries at once; only a later build of a version already seen shows again, and then says
/// which build, the way TestFlight does, so it doesn't read as the same notice twice. App Store
/// installs get one build a version and see it once. Fresh installs see nothing they already have.
@MainActor
enum WhatsNew {
    struct Feature: Identifiable {
        /// An SF Symbol.
        let symbol: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        var id: String { symbol }
    }

    struct Release: Identifiable {
        /// As `MARKETING_VERSION` writes it.
        let version: String
        /// The first build that has this entry; nil for every build of the version. Shown only on
        /// a notice for a later build of a version already seen.
        var build: Int?
        let features: [Feature]
        var id: String { "\(version) (\(build ?? 0))" }

        /// 1.1.0 reads as 1.1, and a build as TestFlight writes it: 1.1 (20).
        var label: String {
            let short = version.hasSuffix(".0") && version.split(separator: ".").count > 2 ? String(version.dropLast(2)) : version
            return build.map { "\(short) (\($0))" } ?? short
        }
    }

    /// Newest first. Until the app reaches an entry's version (and build, when it names one),
    /// the entry is not shown. Entries of one version are shown together, newest first.
    static let releases: [Release] = [
        Release(version: "1.1.0", features: [
            Feature(symbol: "square.grid.2x2",
                    title: "主屏幕和锁屏小组件",
                    detail: "不打开 App 也能看到会话在进行、已完成还是在等你允许，轻点回到对话。"),
            Feature(symbol: "switch.2",
                    title: "控制中心、Siri 和快捷指令",
                    detail: "从控制中心按钮、Siri 或快捷指令直接开始新对话。"),
            Feature(symbol: "chevron.left.forwardslash.chevron.right",
                    title: "内置 Python",
                    detail: "插件和终端都能直接运行 Python 脚本，不用另外安装。"),
            Feature(symbol: "globe",
                    title: "在 App 内切换语言",
                    detail: "在设置里直接选择界面语言，新增西班牙语。"),
        ]),
    ]

    /// The newest entry dealt with: shown, or already there when the app was installed.
    private static let seenVersionKey = "dsh.whatsNew.version"
    private static let seenBuildKey = "dsh.whatsNew.build"

    /// Everything this build has to say about its version, for 设置 → 关于.
    static var current: Release? {
        guard let newest = reached.first else { return nil }
        return merged(reached.filter { same($0.version, newest.version) }, version: newest.version, build: nil)
    }

    /// At launch, before anything this launch writes. With no record yet, the install is either
    /// new, and has seen everything so far, or from before the record was kept (1.0.x), and has
    /// seen nothing: those leave their own settings behind (`dsh.theme.preference` once the
    /// engine answers, `dsh.currentWorkspace` with the first conversation).
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: seenVersionKey) == nil else { return }
        let earlier = defaults.object(forKey: ThemePreference.key) != nil || defaults.object(forKey: "dsh.currentWorkspace") != nil
        if earlier { markSeen("0", 0) } else { markSeen(version, build) }
    }

    /// What to show now, once: this version's entries not seen yet, together.
    static func take() -> Release? {
        let defaults = UserDefaults.standard
        guard let newest = reached.first, let seenVersion = defaults.string(forKey: seenVersionKey) else { return nil }
        let seenBuild = defaults.integer(forKey: seenBuildKey)
        let unseen = reached.filter { same($0.version, newest.version) && isAfter($0.version, $0.build ?? 0, than: seenVersion, seenBuild) }
        guard let latest = unseen.first else { return nil }
        markSeen(newest.version, newest.build ?? 0)
        // Something of this version was seen before: name the build this notice is for.
        let again = same(seenVersion, newest.version)
        return merged(unseen, version: newest.version, build: again ? latest.build : nil)
    }

    /// The entries this build has reached, newest first.
    private static var reached: [Release] {
        releases.filter { !isAfter($0.version, $0.build ?? 0, than: version, build) }
    }

    private static func merged(_ entries: [Release], version: String, build: Int?) -> Release {
        Release(version: version, build: build, features: entries.flatMap(\.features))
    }

    private static func same(_ version: String, _ other: String) -> Bool {
        !AppVersion.isNewer(version, than: other) && !AppVersion.isNewer(other, than: version)
    }

    private static func markSeen(_ version: String, _ build: Int) {
        UserDefaults.standard.set(version, forKey: seenVersionKey)
        UserDefaults.standard.set(build, forKey: seenBuildKey)
    }

    /// Version first, then build.
    private static func isAfter(_ version: String, _ build: Int, than otherVersion: String, _ otherBuild: Int) -> Bool {
        if AppVersion.isNewer(version, than: otherVersion) { return true }
        if AppVersion.isNewer(otherVersion, than: version) { return false }
        return build > otherBuild
    }

    // UI checks in DEBUG builds: `simctl launch … -dshVersion 1.1.0 -dshBuild 20` act as that build.
    private static var version: String {
        #if DEBUG
        if let version = UserDefaults.standard.string(forKey: "dshVersion") { return version }
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var build: Int {
        #if DEBUG
        if let build = UserDefaults.standard.string(forKey: "dshBuild").flatMap(Int.init) { return build }
        #endif
        return (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
    }
}
