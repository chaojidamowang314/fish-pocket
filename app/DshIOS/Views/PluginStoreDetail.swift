import SwiftUI

/// One plugin of a market: what it does, whether this DSH accepts it, and where it comes from.
struct StoreEntryDetail: View {
    @Environment(AppModel.self) private var app
    let listing: StoreEntry
    let model: PluginStoreModel
    let install: (MarketChoice) -> Void

    @State private var showWeb = false

    private var entry: StoreEntry { model.latest(listing) }

    /// Whether the installed plugin is switched on and running, as the plugin list reports it.
    private var runState: (text: String, problem: Bool)? {
        guard let package = app.plugins.package(listing.name), package.installed else { return nil }
        if !package.enabled { return (String(localized: "已停用：插件没有生效"), false) }
        if package.problem { return (String(localized: "已启用，但没有在运行"), true) }
        return (String(localized: "已启用，正在运行。它的界面可在网页版中查看。"), false)
    }
    private var metadata: JSON { model.market.result?["metadata"] ?? .null }
    /// The plugin list answers first after an install; the market's next read says the same.
    private var onDevice: Bool {
        app.plugins.package(listing.name)?.installed == true || ["installed", "update-available", "provided"].contains(entry.status ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 12)
                if let version = entry.version, !entry.installable { compatibilityNote(version["compatibility"]) }
                StoreWebUINote().padding(.horizontal, 16).padding(.top, 20)
                StoreCaption("介绍")
                readme
                StoreCaption("来源")
                facts
                if entry.json["versions"].array.count > 1 {
                    StoreCaption("版本")
                    versions
                }
            }
            .padding(.bottom, 32)
            .readableWidth()
        }
        .background(Palette.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StoreArt(name: entry.name, icon: entry.icon, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name == entry.displayName ? entry.shortName : entry.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    let line = [entry.json["author"].string ?? entry.scope, entry.category(in: metadata)].compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty { Text(line).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1) }
                }
            }
            primaryAction
            if let summary = entry.summary {
                Text(summary).font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if onDevice {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    NavigationLink {
                        PluginDetailView(name: entry.name).storeWebButton()
                    } label: {
                        Text(entry.status == "update-available" ? "有新版本，查看已安装" : "查看已安装").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.capsule(.secondary, height: 48))
                    Button { showWeb = true } label: {
                        Label("网页版", systemImage: "globe").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.capsule(.secondary, height: 48))
                }
                if let runState {
                    Text(runState.text).font(.footnote).foregroundStyle(runState.problem ? Palette.removed : Palette.secondary)
                }
            }
            .fullScreenCover(isPresented: $showWeb) { WebFallbackView() }
        } else if entry.installable, let version = entry.version {
            Button("安装 \(entry.versionNumber)") { install(MarketChoice(entry: entry.json, version: version)) }
                .buttonStyle(.capsule(height: 48))
        }
    }

    private func compatibilityNote(_ compatibility: JSON) -> some View {
        Text("此版本与当前的 DSH \(compatibility["runtimeVersion"].string ?? "") 不兼容，它要求 DSH \(compatibility["requirements"].object.values.compactMap(\.string).joined(separator: ", "))")
            .font(.footnote)
            .foregroundStyle(Palette.waiting)
            .padding(.horizontal, 20)
            .padding(.top, 16)
    }

    // MARK: Documents and facts

    private var readme: some View {
        NavigationLink {
            StoreReadmePage(entry: entry, url: model.market.url ?? "")
        } label: {
            HStack {
                Text("查看 README").font(.callout).foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var facts: some View {
        let source = entry.version?["source"] ?? .null
        return VStack(spacing: 0) {
            if let date = entry.version?["publishTimestamp"].double {
                fact("发布时间", Date(timeIntervalSince1970: date).formatted(date: .long, time: .omitted))
            }
            if let homepage = entry.json["homepage"].string, let url = URL(string: homepage) { link("主页", url) }
            if let repository = entry.json["repository"]["url"].string, let url = URL(string: repository) { link("源代码", url) }
            if source["type"].string == "git" {
                fact("仓库", source["url"].string ?? "")
                fact("提交", String((source["commit"].string ?? "").prefix(12)))
            } else {
                fact("软件包", "\(entry.name)@\(entry.versionNumber)")
                if let registry = source["registry"].string { fact("注册表", registry) }
            }
            if let market = localized(model.market.result?["title"] ?? .null) { fact("插件市场", market) }
        }
        .padding(.vertical, 4)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func fact(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.callout).foregroundStyle(Palette.ink).fixedSize()
            Spacer(minLength: 0)
            Text(value).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }

    private func link(_ title: LocalizedStringKey, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 16) {
                Text(title).font(.callout).foregroundStyle(Palette.ink).fixedSize()
                Spacer(minLength: 0)
                Text(url.host().map { $0 + url.path() } ?? url.absoluteString).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private var versions: some View {
        VStack(spacing: 0) {
            ForEach(entry.json["versions"].array, id: \.self) { version in
                let number = version["version"].string ?? ""
                let compatibility = version["compatibility"]
                let allowed = compatibility["compatible"].bool == true || compatibility["exempted"].bool == true
                let installed = entry.json["installation"]["installedVersion"].string == number
                HStack(spacing: 8) {
                    Text(number).font(.callout.monospaced()).foregroundStyle(Palette.ink)
                    if entry.json["defaultVersion"].string == number { PluginTag(text: String(localized: "推荐"), tone: Palette.running) }
                    if installed { PluginTag(text: String(localized: "当前已安装")) }
                    if !allowed { PluginTag(text: String(localized: "不兼容"), tone: Palette.removed) }
                    Spacer(minLength: 0)
                    if allowed, !installed, entry.status != "provided" {
                        Button("安装") { install(MarketChoice(entry: entry.json, version: version)) }
                            .buttonStyle(.capsule(.secondary, height: 34, fill: false))
                    }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
            }
        }
        .padding(.vertical, 4)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// A section title over a card.
private struct StoreCaption: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 34)
            .padding(.top, 22)
            .padding(.bottom, 7)
    }
}

/// The package's long description, as the Host reads it from the version's source.
private struct StoreReadmePage: View {
    @Environment(AppModel.self) private var app
    let entry: StoreEntry
    let url: String
    @State private var markdown: String?
    @State private var missing = false
    @State private var failed = false

    var body: some View {
        Group {
            if let markdown {
                ScrollView {
                    MarkdownView(text: markdown).padding(20).readableWidth()
                }
            } else if missing {
                ContentUnavailableView("没有说明文档", systemImage: "doc.text")
            } else if failed {
                ContentUnavailableView {
                    Label("无法读取说明文档", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("重试") { Task { await load() } }.buttonStyle(.capsule(.outline, height: 44, fill: false))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .navigationTitle(entry.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Many READMEs lay themselves out in HTML, which reads as noise here: the words stay, the
    /// tags go, as they do in the web client. Code keeps its angle brackets.
    private static func withoutHTML(_ markdown: String) -> String {
        markdown.components(separatedBy: "```").enumerated().map { index, part in
            guard index.isMultiple(of: 2) else { return part }
            return part
                .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"</?[a-zA-Z][^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n[ \t]*(\n[ \t]*)+"#, with: "\n\n", options: .regularExpression)
        }
        .joined(separator: "```")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        failed = false
        let language = AppLanguage.isChinese ? "zh" : "en"
        do {
            let detail = try await app.client.call("pluginMarket/readEntryDetail", [
                "url": .string(url),
                "name": .string(entry.name),
                "version": .string(entry.versionNumber),
                "language": .string(language),
            ])
            if detail["status"].string == "found", let text = detail["markdown"].string {
                markdown = Self.withoutHTML(text)
            } else {
                missing = true
            }
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

/// 安装「{name}」？ with where it comes from, then the install sheet.
struct StoreInstallConfirm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let choice: MarketChoice
    let marketTitle: String?
    /// The sheet is as tall as what it says, which depends on the plugin.
    @State private var height: CGFloat = 360

    private var entry: StoreEntry { StoreEntry(json: choice.entry) }

    var body: some View {
        let number = choice.version["version"].string ?? ""
        let source = choice.version["source"]
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StoreArt(name: entry.name, icon: entry.icon, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("安装「\(entry.displayName)」？").font(.headline).foregroundStyle(Palette.ink).lineLimit(2)
                    Text(number).font(.footnote.monospaced()).foregroundStyle(Palette.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let author = entry.json["author"].string { line("作者", Text(author)) }
                if let marketTitle { line("市场", Text(marketTitle)) }
                line("软件包", Text(source["type"].string == "npm" ? "\(entry.name)@\(number)" : (source["url"].string ?? "")).font(.footnote.monospaced()))
            }
            if choice.version["compatibility"]["exempted"].bool == true {
                Text("此版本与当前 DSH 不兼容，但你已为它设置了兼容性豁免").font(.footnote).foregroundStyle(Palette.waiting)
            }
            // 这是装插件的主入口，警告要说全：插件和智能体走同一条路，本机能力对它一样开放。
            Label(
                "插件在本机以你的权限运行，也能用本机能力（\(NativeCapability.installWarningSummary)）。请确认你信任它的来源。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.buttonStyle(.capsule(.outline))
                Button("安装") {
                    let install = choice.version["install"]
                    let title = entry.displayName
                    dismiss()
                    Task {
                        // Our sheet must be gone before the install sheet presents.
                        try? await Task.sleep(for: .milliseconds(400))
                        app.pluginInstall.installFrom(spec: install["spec"].string ?? "", registry: install["registry"].string, title: title, version: number)
                    }
                }
                .buttonStyle(.capsule())
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
        .presentationDetents([.height(height)])
        .tint(Palette.ink)
    }

    private func line(_ title: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(Palette.secondary).frame(width: 52, alignment: .leading)
            value.foregroundStyle(Palette.ink).lineLimit(2)
        }
        .font(.subheadline)
    }
}

/// Plugin interfaces are web pages the native app doesn't render (App Store review); the plugin
/// itself may still be running, and 网页版 shows its interface.
struct StoreWebUINote: View {
    var compact = false
    @State private var showWeb = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            Image(systemName: "info.circle").font(.subheadline).foregroundStyle(Palette.secondary)
            if compact {
                Text("插件自带的界面不会在 App 里显示，可在网页版中查看。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("网页版") { showWeb = true }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("插件界面不在 App 里显示").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("按 App Store 审核要求，插件自带的界面不会出现在 App 的原生界面中，但插件本身可能仍在运行。要查看它的界面，请打开网页版（设置 → 高级 → 网页版）。")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                    Button("打开网页版") { showWeb = true }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 10 : 14)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous))
        .fullScreenCover(isPresented: $showWeb) { WebFallbackView() }
    }
}

/// A web version button for pages that show one plugin, so its interface is a tap away.
private struct StoreWebButton: ViewModifier {
    @State private var showWeb = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWeb = true } label: { Label("网页版", systemImage: "globe") }
                }
            }
            .fullScreenCover(isPresented: $showWeb) { WebFallbackView() }
    }
}

extension View {
    func storeWebButton() -> some View { modifier(StoreWebButton()) }
}
