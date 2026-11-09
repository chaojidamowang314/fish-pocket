import SwiftUI

/// The last section of 设置, shown only while the app is in Chinese: the QR code of the
/// Fish Pocket WeChat group. A group's code expires after 7 days, so it is not bundled: it is
/// `docs/assets/wechat-group.png` in the repository, the same file the README shows, loaded from
/// GitHub and, where GitHub's raw host is unreachable, from jsDelivr. The row loads it only once
/// it scrolls into view. A code on this very screen cannot be scanned, so it saves to the album
/// for WeChat's 「扫一扫」 to pick from there.
struct WeChatGroupSection: View {
    private enum Phase { case loading, loaded(UIImage), failed }

    @Environment(AppModel.self) private var app
    @State private var phase = Phase.loading
    @State private var saving = false

    static let sources = [
        "https://raw.githubusercontent.com/\(UpdateChecker.repository)/main/docs/assets/wechat-group.png",
        "https://cdn.jsdelivr.net/gh/\(UpdateChecker.repository)@main/docs/assets/wechat-group.png",
    ].compactMap { URL(string: $0) }

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

    /// Once per visit to 设置: the image is small, and the URL cache keeps GitHub's few minutes.
    private func load() async {
        if case .loaded = phase { return }
        phase = .loading
        for url in Self.sources {
            let request = URLRequest(url: url, timeoutInterval: 10)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { continue }
            phase = .loaded(image)
            return
        }
        phase = .failed
    }
}
