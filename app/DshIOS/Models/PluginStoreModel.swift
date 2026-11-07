import Foundation
import Observation

/// The store's own state, around the market reader 发现 under 设置 → 插件 also uses: readying the
/// market on first use and restoring the preset index.
@MainActor
@Observable
final class PluginStoreModel {
    enum Readiness { case checking, preparing, ready, off, unavailable }

    /// Set once a preset has been offered: after that, an index list without it is the user's choice.
    private static let seededKey = "dsh.store.seeded:\(PluginStoreCatalog.presetIndex)"

    let market = PluginMarketModel()
    private(set) var readiness = Readiness.checking
    @ObservationIgnored private var preparing: Task<Void, Never>?

    private var seeded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.seededKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.seededKey) }
    }

    var hasPreset: Bool { market.indexes?.contains { $0["url"].string == PluginStoreCatalog.presetIndex } ?? false }

    /// The market bundle is optional and off in the shipped profile. The first visit turns it on and
    /// adds the preset index; after that its switch under 设置 → 插件 is the user's. A task of its own:
    /// the page's is cancelled when the connection comes up, which is exactly when a first visit runs.
    func prepare(_ app: AppModel) async {
        if let preparing {
            await preparing.value
            return
        }
        let task = Task { await ready(app) }
        preparing = task
        await task.value
        preparing = nil
    }

    private func ready(_ app: AppModel) async {
        let manager = app.plugins
        await manager.refresh(revision: app.revision("plugin-manager/changed"))
        guard manager.status != .unavailable, let bundle = manager.package(PluginManagerModel.marketBundle) else {
            readiness = .unavailable
            return
        }
        if !bundle.enabled {
            guard !seeded else {
                readiness = .off
                return
            }
            await enable(app)
            return
        }
        await open(app)
    }

    /// 开启: the market bundle's switch, from here.
    func enable(_ app: AppModel) async {
        let manager = app.plugins
        guard let bundle = manager.package(PluginManagerModel.marketBundle) else { return }
        readiness = .preparing
        await manager.setEnabled(bundle, true)
        readiness = manager.marketEnabled ? .preparing : .off
        if manager.marketEnabled { await open(app) }
    }

    private func open(_ app: AppModel) async {
        await market.loadIndexes(app)
        if !seeded, let indexes = market.indexes {
            let urls = indexes.compactMap { $0["url"].string }
            if urls.contains(PluginStoreCatalog.presetIndex) {
                seeded = true
            } else if await market.saveSources([PluginStoreCatalog.presetIndex] + urls, adding: false, app) {
                seeded = true
            }
        }
        readiness = .ready
    }

    /// Its switch went off under 设置 → 插件 while the store stayed open (iPad).
    func marketTurnedOff() {
        if readiness == .ready { readiness = .off }
    }

    /// The newest read of a listing: a page that holds one outlives what it says about installation.
    func latest(_ entry: StoreEntry) -> StoreEntry {
        market.entries.first { $0["name"].string == entry.name }.map(StoreEntry.init) ?? entry
    }

    /// 恢复预置市场.
    func restorePreset(_ app: AppModel) async {
        let urls = (market.indexes ?? []).compactMap { $0["url"].string }
        guard !urls.contains(PluginStoreCatalog.presetIndex) else { return }
        _ = await market.saveSources([PluginStoreCatalog.presetIndex] + urls, adding: false, app)
        market.selected = PluginStoreCatalog.presetIndex
        await market.reload(app)
    }
}
