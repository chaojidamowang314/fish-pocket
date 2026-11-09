import SwiftUI

/// The last section of 设置, shown only while the app is in Chinese: the QR code of the
/// Fish Pocket WeChat group. A group's code expires after 7 days, so it is not bundled. It loads
/// from the website first, `wechat-group.png` beside its page, since GitHub is out of reach in
/// some regions; then from the repository's `docs/assets/wechat-group.png`, the file the README
/// shows. The row loads it only once it scrolls into view. A code on this very screen cannot be
/// scanned, so it saves to the album for WeChat's 「扫一扫」 to pick from there.
struct WeChatGroupSection: View {
    private enum Phase { case loading, loaded(UIImage), failed }

    @Environment(AppModel.self) private var app
    @State private var phase = Phase.loading
    @State private var saving = false

    /// The website lives on VibeVibi, which serves each published version from a directory of its
    /// own; the work's public record names the live one.
    private static let siteWork = URL(string: "https://vibevibi.com/api/works/fish-pocket")!
    private static let github = URL(string: "https://raw.githubusercontent.com/\(UpdateChecker.repository)/main/docs/assets/wechat-group.png")!

    private struct Work: Decodable { let contentUrl: String }

    var body: some View {
        Section {
            code
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .task { await load() }
            switch phase {
            case .loaded(let image):
                Button {
                    saving = true
                    Task {
                        await PhotoAlbum.save(image, app: app)
                        saving = false
                    }
                } label: {
                    Label("保存二维码到相册", systemImage: "square.and.arrow.down").foregroundStyle(Palette.ink)
                }
                .disabled(saving)
            case .failed:
                Link(destination: AppLinks.repository) {
                    HStack {
                        Text("在 GitHub 仓库首页查看").foregroundStyle(Palette.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.faint)
                    }
                }
            case .loading:
                EmptyView()
            }
        } header: {
            Text("微信交流群")
        } footer: {
            Text("保存到相册后，打开微信「扫一扫」，从相册里选这张图片就能加入。")
        }
        .groupedRow()
    }

    @ViewBuilder
    private var code: some View {
        switch phase {
        case .loading:
            ProgressView().frame(height: 160)
        case .loaded(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.stroke) }
                .accessibilityLabel(Text("Fish Pocket 微信交流群的二维码"))
        case .failed:
            Text("二维码没有加载出来，请检查网络。")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    /// Once per visit to 设置. The website's files never change under one version directory, and
    /// GitHub's are cached for a few minutes, so the URL cache does the rest.
    private func load() async {
        if case .loaded = phase { return }
        phase = .loading
        var sources: [URL] = []
        if let data = await Self.get(Self.siteWork, fresh: true),
           let work = try? JSONDecoder().decode(Work.self, from: data),
           let url = URL(string: "wechat-group.png", relativeTo: URL(string: work.contentUrl)) {
            sources.append(url.absoluteURL)
        }
        sources.append(Self.github)
        for url in sources {
            if let data = await Self.get(url), let image = UIImage(data: data) {
                phase = .loaded(image)
                return
            }
        }
        phase = .failed
    }

    /// `fresh` skips the URL cache: the work's record names a new directory after each publish.
    private static func get(_ url: URL, fresh: Bool = false) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: fresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy, timeoutInterval: 10)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
