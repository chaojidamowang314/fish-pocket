import SwiftUI

/// 插件: browse a market and manage what is installed. It reads the same market and plugin models
/// as 设置 → 插件, which stays as it is until this page replaces it.
struct PluginStoreView: View {
    @Environment(AppModel.self) private var app
    /// The sidebar button, where this page is the split view's detail.
    var openSidebar: (() -> Void)?
    @AppStorage("dsh.store.tab") private var tab = "discover"
    @State private var model = PluginStoreModel()
    @State private var managing = false
    @State private var searching = false

    private var manager: PluginManagerModel { app.plugins }

    var body: some View {
        VStack(spacing: 0) {
            if !searching { tabs }
            if tab == "discover" {
                StoreDiscoverPage(model: model, searching: $searching, manage: { managing = true })
            } else {
                StoreInstalledPage(showDiscover: { tab = "discover" })
            }
        }
        .background(Palette.background)
        .animation(.snappy(duration: 0.2), value: searching)
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let openSidebar { ToolbarItem(placement: .topBarLeading) { DrawerButton(action: openSidebar) } }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .sheet(isPresented: $managing) { StoreSourcesSheet(model: model) }
        .task(id: app.revision()) { await model.prepare(app) }
        .task(id: app.revision("plugin-manager/changed")) {
            await manager.refresh(revision: app.revision("plugin-manager/changed"))
            guard model.readiness == .ready, model.market.result != nil else { return }
            await model.market.reload(app, limit: max(model.market.entries.count, 50))
        }
        .task(id: app.revision("plugin-market/changed")) {
            guard model.readiness == .ready else { return }
            await model.market.loadIndexes(app)
        }
        .onChange(of: manager.marketEnabled) { _, enabled in if !enabled { model.marketTurnedOff() } }
        .followSettings()
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton("发现", value: "discover")
            tabButton("已安装", value: "installed")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tabButton(_ title: LocalizedStringKey, value: String) -> some View {
        Button {
            if tab != value { Haptics.select() }
            tab = value
        } label: {
            Text(title)
                .font(.subheadline.weight(tab == value ? .semibold : .medium))
                .foregroundStyle(tab == value ? Palette.onInk : Palette.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background { if tab == value { Capsule().fill(Palette.ink) } }
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? [.isSelected, .isButton] : .isButton)
    }

    private var menu: some View {
        Menu {
            let indexes = model.market.indexes ?? []
            if indexes.count > 1 {
                Section("插件市场") {
                    ForEach(indexes, id: \.self) { index in
                        Button {
                            model.market.selected = index["url"].string
                            Task { await model.market.reload(app) }
                        } label: {
                            if index["url"].string == model.market.url {
                                Label(model.market.label(index), systemImage: "checkmark")
                            } else {
                                Text(model.market.label(index))
                            }
                        }
                    }
                }
            }
            Button { managing = true } label: { Label("索引源", systemImage: "list.bullet") }
                .disabled(model.readiness != .ready)
            Button {
                app.pluginInstall.openDialog()
            } label: {
                Label {
                    Text("安装第三方插件")
                    Text("从 npm、Git 仓库或本地文件夹安装")
                } icon: {
                    Image(systemName: "shippingbox")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
    }
}

// MARK: - 发现

private struct StoreDiscoverPage: View {
    @Environment(AppModel.self) private var app
    let model: PluginStoreModel
    @Binding var searching: Bool
    let manage: () -> Void
    @State private var search = ""
    @State private var width: CGFloat = 0
    @State private var choice: MarketChoice?
    @FocusState private var searchFocused: Bool

    private var market: PluginMarketModel { model.market }
    private var metadata: JSON { market.result?["metadata"] ?? .null }
    /// Rows sit side by side once two of them fit.
    private var wide: Bool { width >= 640 }
    private var hasText: Bool { !market.query.text.trimmingCharacters(in: .whitespaces).isEmpty }
    private var unfiltered: Bool { !hasText && market.query.category == nil && market.query.labels.isEmpty }

    var body: some View {
        Group {
            switch model.readiness {
            case .checking where model.hasList:
                ready
            case .checking, .preparing:
                ProgressView("正在准备插件市场")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                ContentUnavailableView("无法管理插件", systemImage: "puzzlepiece.extension", description: Text("当前无法安装或启停插件。"))
            case .off:
                ContentUnavailableView {
                    Label("插件市场已关闭", systemImage: "storefront")
                } description: {
                    Text("它的开关在「设置 → 插件 → 实验性插件」")
                } actions: {
                    Button("开启") { Task { await model.enable(app) } }.buttonStyle(.capsule(height: 44, fill: false))
                }
            case .ready:
                ready
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(item: $choice) { StoreInstallConfirm(choice: $0, marketTitle: localized(market.result?["title"] ?? .null)) }
        .onChange(of: searchFocused) { updateSearching() }
        .onChange(of: search) { updateSearching() }
        // Keystrokes settle for 250 ms before a read.
        .task(id: search) {
            guard search != market.query.text else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            market.setText(search)
            await market.reload(app)
        }
    }

    private func updateSearching() {
        searching = searchFocused || !search.isEmpty
    }

    @ViewBuilder
    private var ready: some View {
        if let indexes = market.indexes {
            if indexes.isEmpty { noMarket } else { browser }
        } else if market.indexesFailed {
            failure { await market.loadIndexes(app) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noMarket: some View {
        ContentUnavailableView {
            Label("还没有插件市场", systemImage: "storefront")
        } description: {
            Text("恢复预置市场，或添加其他索引。")
        } actions: {
            Button("恢复预置市场") { Task { await model.restorePreset(app) } }.buttonStyle(.capsule(height: 44, fill: false))
            Button("添加索引源", action: manage).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).hitTarget()
        }
    }

    private func failure(_ retry: @escaping () async -> Void) -> some View {
        ContentUnavailableView {
            Text("无法读取插件市场").font(.title3.weight(.semibold))
        } description: {
            Text("检查网络后再试一次。已经安装的插件不受影响。")
        } actions: {
            Button("重试") { Task { await retry() } }.buttonStyle(.capsule(.outline, height: 44, fill: false))
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            searchField
            if market.failure != nil, market.entries.isEmpty {
                failure { await market.reload(app, refresh: true) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !searching { StoreWebUINote(compact: true).padding(.horizontal, 16).padding(.top, 12) }
                        if !searching, !categories.isEmpty { categoryBar }
                        sectionHeader {
                            Text(unfiltered ? "全部插件" : hasText ? "搜索结果" : "相关插件")
                            Spacer()
                            if !declared("labels").isEmpty { labelsMenu }
                            sortMenu
                        }
                        listing
                    }
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await market.reload(app, refresh: true) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Palette.secondary)
            TextField(searchPrompt, text: $search)
                .font(.callout)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
            if !search.isEmpty || searchFocused {
                Button {
                    search = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint).hitTarget()
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, search.isEmpty && !searchFocused ? 14 : 2)
        .frame(minHeight: 44)
        .background(Palette.bubble, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, searching ? 8 : 0)
    }

    private var searchPrompt: String {
        guard let total = market.result?["total"].double, unfiltered, !market.loading else { return String(localized: "搜索插件") }
        return String(localized: "搜索 \(Int(total).formatted()) 个插件")
    }

    // MARK: Lists

    private func sectionHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 34)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private var trustLine: some View {
        Button(action: manage) {
            Text("来自 \(localized(market.result?["title"] ?? .null) ?? "")。插件由社区作者发布，Fish Pocket 不审核。")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var listing: some View {
        if market.entries.isEmpty {
            HStack(spacing: 8) {
                if market.loading || market.result == nil {
                    ProgressView()
                    Text("正在读取索引")
                } else {
                    Text(unfiltered ? "此索引没有插件" : "没有符合条件的插件")
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 88)
        } else {
            if wide { trustLine.padding(.horizontal, 34).padding(.bottom, 10) }
            rows(market.entries.map(StoreEntry.init), lead: wide ? nil : AnyView(trustLine.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 6)))
            if let failure = market.failure {
                Text(failure).font(.footnote).foregroundStyle(Palette.removed).padding(.horizontal, 34).padding(.top, 10)
            }
            if market.result?["nextOffset"].isNull == false {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .onAppear { Task { await market.loadMore(app) } }
            }
        }
    }

    /// One card on a phone; cards side by side where there is room.
    @ViewBuilder
    private func rows(_ entries: [StoreEntry], lead: AnyView? = nil) -> some View {
        if wide {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(entries) { row($0).background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let lead { lead }
                ForEach(entries) { row($0) }
            }
            .padding(.vertical, 3)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func row(_ entry: StoreEntry) -> some View {
        StoreRow(entry: entry, model: model, wide: wide) { choice = $0 }
    }

    // MARK: Filters

    /// What the market declares under `metadata`, by title.
    private func declared(_ group: String) -> [(id: String, title: String)] {
        metadata[group].object.map { (id: $0.key, title: localized($0.value["title"]) ?? $0.key) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private var categories: [(id: String, title: String)] { declared("categories") }

    private var labelsMenu: some View {
        Menu {
            ForEach(declared("labels"), id: \.id) { label in
                Button {
                    if let index = market.query.labels.firstIndex(of: label.id) { market.query.labels.remove(at: index) } else { market.query.labels.append(label.id) }
                    Task { await market.reload(app) }
                } label: {
                    if market.query.labels.contains(label.id) { Label(label.title, systemImage: "checkmark") } else { Text(label.title) }
                }
            }
        } label: {
            Text(market.query.labels.isEmpty ? String(localized: "标签") : String(localized: "标签 · \(market.query.labels.count)"))
                .font(.footnote.weight(.regular)).foregroundStyle(Palette.secondary)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "全部"), selected: market.query.category == nil) { market.query.category = nil }
                ForEach(categories, id: \.id) { category in
                    chip(category.title, selected: market.query.category == category.id) { market.query.category = category.id }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
    }

    private func chip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
            Task { await market.reload(app) }
        } label: {
            Text(title)
                .font(.footnote.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Palette.onInk : Palette.ink)
                .padding(.horizontal, 13)
                .frame(minHeight: 34)
                .background(selected ? Palette.ink : Palette.control, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var sortName: String {
        let sort = market.query.sort
        switch sort["kind"].string {
        case "relevance": return String(localized: "最佳匹配")
        case "published": return String(localized: "发布时间")
        case "key": return localized(metadata["sortKeys"][sort["id"].string ?? ""]["title"]) ?? (sort["id"].string ?? "")
        default: return String(localized: "默认顺序")
        }
    }

    private var sortMenu: some View {
        let current = market.query.sort
        func choose(_ sort: JSON) {
            market.query.sort = sort
            Task { await market.reload(app) }
        }
        return Menu {
            Button(hasText ? "最佳匹配" : "默认顺序") { choose(["kind": hasText ? "relevance" : "index"]) }
            Button("发布时间") { choose(["kind": "published", "direction": "desc"]) }
            ForEach(metadata["sortKeys"].object.sorted { $0.key < $1.key }, id: \.key) { key, value in
                Button(localized(value["title"]) ?? key) {
                    choose(["kind": "key", "id": .string(key), "direction": value["order"].string.map(JSON.string) ?? "desc"])
                }
            }
            if let direction = current["direction"].string {
                Divider()
                Button(direction == "desc" ? "改为升序" : "改为降序") {
                    choose(current.setting(["direction"], .string(direction == "desc" ? "asc" : "desc")))
                }
            }
        } label: {
            Text("排序：\(sortName)").font(.footnote.weight(.regular)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
    }
}

/// A plugin's picture: its icon when it ships one, else a letter of its name. The preset index has
/// no icons, and one glyph repeated down a list would tell the rows apart less than this does.
struct StoreArt: View {
    let name: String
    var icon: String?
    var size: CGFloat = 44

    private var letter: String {
        let bare = (name.components(separatedBy: "/").last ?? name).replacingOccurrences(of: #"^dsh-"#, with: "", options: .regularExpression)
        return String(bare.prefix(1)).uppercased()
    }

    var body: some View {
        if let icon {
            PluginIcon(source: icon, size: size - 12)
        } else {
            Text(letter)
                .font(.system(size: size * 0.41, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: size, height: size)
                .background(Palette.bubble, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

private struct StoreRow: View {
    @Environment(AppModel.self) private var app
    let entry: StoreEntry
    let model: PluginStoreModel
    let wide: Bool
    let install: (MarketChoice) -> Void

    private var metadata: JSON { model.market.result?["metadata"] ?? .null }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                StoreEntryDetail(listing: entry, model: model, install: install)
            } label: {
                HStack(spacing: 12) {
                    StoreArt(name: entry.name, icon: entry.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.displayName).font(.callout).foregroundStyle(Palette.ink).lineLimit(1)
                            ForEach(entry.labels, id: \.self) { id in
                                if let title = localized(metadata["labels"][id]["title"]) { PluginTag(text: title) }
                            }
                        }
                        if let summary = entry.summary {
                            Text(summary).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                        Text(meta).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            action
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: wide ? 86 : 74)
    }

    private var meta: String {
        [entry.versionNumber, entry.author, entry.date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        switch entry.status {
        case "installed": installedLink(String(localized: "已安装"))
        case "update-available": installedLink(String(localized: "有新版本"))
        case "provided": installedLink(String(localized: "随 DSH 提供"))
        default:
            if !entry.installable {
                note(String(localized: "不兼容"))
            } else {
                Button {
                    if let version = entry.version { install(MarketChoice(entry: entry.json, version: version)) }
                } label: {
                    Text("安装")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(Palette.control, in: Capsule())
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .disabled(model.market.fromCache)
                .opacity(model.market.fromCache ? 0.4 : 1)
                .accessibilityLabel("安装 \(entry.displayName)")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.medium)).foregroundStyle(Palette.secondary).fixedSize()
    }

    /// An entry on this device opens its page in 已安装.
    private func installedLink(_ text: String) -> some View {
        NavigationLink {
            PluginDetailView(name: entry.name)
        } label: {
            note(text).hitTarget()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 已安装

/// Everything 设置 → 插件 lists, this store's way round: what the user added comes first.
private struct StoreInstalledPage: View {
    @Environment(AppModel.self) private var app
    let showDiscover: () -> Void

    private var manager: PluginManagerModel { app.plugins }

    var body: some View {
        List {
            if manager.status == .unavailable {
                Text("当前无法安装或启停插件。").font(.footnote).foregroundStyle(Palette.secondary).groupedRow()
            } else if manager.packages.isEmpty, manager.status != .ready {
                HStack { Spacer(); ProgressView(); Spacer() }.groupedRow()
            } else {
                Section {
                    StoreWebUINote(compact: true)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                installed
                builtIn
                experimental
            }
        }
        .groupedList()
        .refreshable { await manager.manualRefresh() }
    }

    private var installed: some View {
        Section("已安装插件") {
            if manager.installedPackages.isEmpty {
                Button(action: showDiscover) {
                    HStack {
                        Text("还没有安装任何插件").foregroundStyle(Palette.secondary)
                        Spacer()
                        Text("去发现").foregroundStyle(Palette.ink)
                    }
                    .font(.footnote)
                }
            }
            ForEach(manager.installedPackages) { StorePackageRow(package: $0) }
        }
        .groupedRow()
    }

    @ViewBuilder
    private var builtIn: some View {
        let items = OfficialPluginItem.available(app.settings)
        if !items.isEmpty {
            Section("内置功能") {
                ForEach(items) { item in
                    NavigationLink {
                        OfficialPluginPage(page: item.page)
                    } label: {
                        HStack(spacing: 12) {
                            PluginIcon(source: nil, size: 32, glyph: item.glyph)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout).foregroundStyle(Palette.ink)
                                Text(item.summary).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .groupedRow()
        }
    }

    @ViewBuilder
    private var experimental: some View {
        if !manager.extensions.isEmpty {
            Section("实验性插件") {
                ForEach(manager.extensions) { StorePackageRow(package: $0) }
                if manager.hasMore {
                    NavigationLink("查看全部") { StoreAllExtensions() }
                }
            }
            .groupedRow()
        }
    }
}

/// 实验性插件 → 查看全部.
private struct StoreAllExtensions: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section { ForEach(app.plugins.allExtensions) { StorePackageRow(package: $0) } }.groupedRow()
        }
        .groupedList()
        .navigationTitle("实验性插件")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An installed or official package; its switch and removal are on the detail page it opens.
private struct StorePackageRow: View {
    @Environment(AppModel.self) private var app
    let package: PluginPackage

    var body: some View {
        NavigationLink {
            PluginDetailView(name: package.name).storeWebButton()
        } label: {
            HStack(spacing: 12) {
                if package.official {
                    PluginIcon(source: package.icon, size: 32)
                } else {
                    StoreArt(name: package.name, icon: package.icon)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.title).font(.callout).foregroundStyle(Palette.ink).lineLimit(1)
                    if let summary = package.summary {
                        Text(summary).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if app.plugins.isBusy(package) {
                    ProgressView()
                } else if let state {
                    Text(state).font(.footnote).foregroundStyle(package.stalled ? Palette.removed : Palette.secondary).fixedSize()
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var state: String? {
        guard package.availability != "missing" else { return nil }
        if package.stalled { return String(localized: "未运行") }
        return package.enabled ? String(localized: "已启用") : String(localized: "已停用")
    }
}

// MARK: - 索引源

/// The index list, written whole with `setIndexes`. The preset is an ordinary source the user may
/// remove; a row brings it back.
struct StoreSourcesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: PluginStoreModel
    @State private var draft = ""

    private var market: PluginMarketModel { model.market }
    private var urls: [String] { (market.indexes ?? []).compactMap { $0["url"].string } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(market.indexes ?? [], id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(title(index)).foregroundStyle(Palette.ink).lineLimit(1)
                                if index["url"].string == PluginStoreCatalog.presetIndex { PluginTag(text: String(localized: "预置")) }
                            }
                            Text(index["url"].string ?? "").font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                            if let error = index["error"].string { Text(error).font(.caption).foregroundStyle(Palette.removed) }
                        }
                    }
                    .onDelete { offsets in
                        var next = urls
                        next.remove(atOffsets: offsets)
                        Task { _ = await market.saveSources(next, adding: false, app) }
                    }
                    if !model.hasPreset {
                        Button {
                            Task { await model.restorePreset(app) }
                        } label: {
                            Label("恢复预置市场", systemImage: "arrow.counterclockwise").foregroundStyle(Palette.ink)
                        }
                        .disabled(market.saving)
                    }
                } footer: {
                    Text("打开「发现」时，App 会访问这里列出的地址。左滑可移除。")
                }
                .groupedRow()
                Section {
                    // A string, not a key: a key's URL would read as a link, in link colour.
                    TextField(String("https://example.com/index.json"), text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: draft) { _, _ in market.clearSourceFailure() }
                    if let failure = failureText { Text(failure).font(.caption).foregroundStyle(Palette.removed) }
                    Button("添加") {
                        let url = draft.trimmingCharacters(in: .whitespaces)
                        Task {
                            if await market.saveSources(urls + [url], adding: true, app) { draft = "" }
                        }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || market.saving)
                } header: {
                    Text("添加索引源")
                } footer: {
                    Text("索引由第三方提供。只添加你信任的来源：其中的插件安装后以你的权限运行。")
                }
                .groupedRow()
            }
            .groupedList()
            .navigationTitle("索引源")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .tint(Palette.ink)
    }

    /// A source lists its host until it is read; the market on screen has been.
    private func title(_ index: JSON) -> String {
        if index["url"].string == market.url, let title = localized(market.result?["title"] ?? .null) { return title }
        return market.label(index)
    }

    private var failureText: String? {
        switch market.sourceFailure {
        case .invalid?: String(localized: "请使用 http 或 https 地址，且不要包含用户名、密码或 # 片段")
        case .duplicate?: String(localized: "已添加过这个索引源")
        case .unavailable?: String(localized: "当前环境无法保存索引源")
        case .other(let reason)?: String(localized: "无法保存索引源：\(reason)")
        case nil: nil
        }
    }
}
