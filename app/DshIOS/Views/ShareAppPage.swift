import Photos
import SwiftUI

/// 「分享 Fish Pocket」: a poster with the QR code, a poster with the link written out, or the
/// link alone, each sent through the system share sheet; posters also save to the album.
/// Reached from the top of 设置 and from the support card. Everything points at the website
/// (`AppLinks.site`), which sends readers on to the App Store or the public beta.
struct ShareAppPage: View {
    enum Style: CaseIterable, Identifiable {
        case qrPoster, linkPoster, link
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .qrPoster: "二维码海报"
            case .linkPoster: "链接海报"
            case .link: "链接"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @State private var style = Style.qrPoster
    /// Each poster is drawn once, the first time its tab is open.
    @State private var posters: [Style: UIImage] = [:]
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            tabs
            ScrollView {
                preview
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            actions
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .background(Palette.grouped)
        .navigationTitle("分享 Fish Pocket")
        .navigationBarTitleDisplayMode(.inline)
        // Whoever came this far needs no card asking them to.
        .onAppear { SupportPrompt.settle() }
        .task(id: style) { draw(style) }
    }

    /// Centred when the three fit, scrolling on a narrow phone in a longer language.
    private var tabs: some View {
        ViewThatFits(in: .horizontal) {
            tabStrip.padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) { tabStrip.padding(.horizontal, 16) }
        }
        .padding(.vertical, 8)
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(Style.allCases) { item in
                Button { if style != item { Haptics.select() }; style = item } label: {
                    Text(item.title)
                        .font(.subheadline.weight(style == item ? .semibold : .medium))
                        .foregroundStyle(style == item ? Palette.onInk : Palette.secondary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background { if style == item { Capsule().fill(Palette.ink) } }
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(style == item ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch style {
        case .qrPoster, .linkPoster:
            Group {
                if let image = posters[style] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.stroke) }
                        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                        .accessibilityLabel(style == .qrPoster ? Text("Fish Pocket 分享海报，带二维码") : Text("Fish Pocket 分享海报，带链接"))
                } else {
                    ProgressView().frame(height: 320)
                }
            }
            .frame(maxWidth: 300)
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                Text("将发送这段文字")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.secondary)
                Text(AppLinks.shareText)
                    .font(.callout)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.stroke) }
            }
            .frame(maxWidth: 420)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch style {
            case .qrPoster, .linkPoster:
                let poster = posters[style]
                Button { if let poster { save(poster) } } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.capsule(.secondary))
                    .disabled(poster == nil || saving)
                if let poster {
                    let image = Image(uiImage: poster)
                    ShareLink(item: image, preview: SharePreview("Fish Pocket", image: image)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.capsule())
                } else {
                    Button {} label: { Label("分享", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.capsule())
                        .disabled(true)
                }
            case .link:
                Button {
                    copyToPasteboard(AppLinks.site.absoluteString)
                    app.showToast(String(localized: "链接已复制"))
                } label: { Label("复制链接", systemImage: "link") }
                    .buttonStyle(.capsule(.secondary))
                ShareLink(item: AppLinks.shareText) { Label("分享", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.capsule())
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    /// Light whatever the app's appearance: a picture sent on is read on someone else's screen.
    private func draw(_ style: Style) {
        guard posters[style] == nil, style != .link else { return }
        let renderer = ImageRenderer(content: SharePoster(withCode: style == .qrPoster)
            .environment(\.colorScheme, .light)
            .environment(\.locale, locale))
        renderer.scale = 3
        posters[style] = renderer.uiImage
    }

    /// Only adds to the album, so it asks for nothing more than that.
    private func save(_ poster: UIImage) {
        saving = true
        Task {
            defer { saving = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                app.showToast(String(localized: "没有相册权限，可以在系统设置里允许 Fish Pocket 添加照片"))
                Haptics.error()
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: poster) }
                app.showToast(String(localized: "已保存到相册"))
                Haptics.success()
            } catch {
                app.showToast(String(localized: "保存失败：\(error.localizedDescription)"))
                Haptics.error()
            }
        }
    }
}

/// The poster itself (晒 Fish Pocket), drawn at a fixed 360 × 640 so every phone makes the same
/// picture, 1080 × 1920 at 3×: the headline over a dotted page, the mascot peeking out of the
/// website's dark stitched pocket, and in the pocket the plugin markets and the way to the app.
struct SharePoster: View {
    /// The QR code at the foot; otherwise the link written out.
    let withCode: Bool

    private static let ink = Color(red: 0.047, green: 0.047, blue: 0.051)
    private static let pocketInk = Color(red: 0.949, green: 0.949, blue: 0.953)
    private static let body = Color(red: 0.333, green: 0.333, blue: 0.361)
    private static let muted = Color(red: 0.420, green: 0.420, blue: 0.447)
    private static let pocketMuted = Color(red: 0.639, green: 0.639, blue: 0.667)
    private static let halo = Color(red: 0.906, green: 0.929, blue: 0.976)
    private static let dot = Color(red: 0.863, green: 0.863, blue: 0.878)

    private static let width: CGFloat = 360
    private static let height: CGFloat = 640
    private static let pocketTop: CGFloat = 404

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            dots
            header
                .frame(width: Self.width - 48)
                .offset(x: 24, y: 24)
            Circle()
                .fill(Self.halo)
                .frame(width: 184, height: 184)
                .offset(x: 88, y: 232)
            Image("ShareMascot")
                .resizable()
                .frame(width: 220, height: 220)
                .offset(x: 70, y: 214)
                .accessibilityHidden(true)
            headline
                .frame(width: Self.width - 48, alignment: .leading)
                .offset(x: 24, y: 64)
            pocket
                .frame(width: Self.width - 24, height: Self.height - Self.pocketTop - 12)
                .offset(x: 12, y: Self.pocketTop)
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .clipped()
    }

    /// A faint dot grid under the top half, like the website's page.
    private var dots: some View {
        Canvas { context, size in
            let step: CGFloat = 14
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(Self.dot))
                    x += step
                }
                y += step
            }
        }
        .frame(width: Self.width, height: 420)
        .opacity(0.7)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if let image = UIImage(named: "AppIcon") {
                    Image(uiImage: image).resizable()
                } else {
                    Image("LaunchMark").resizable().scaledToFit()
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(verbatim: "Fish Pocket")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Self.ink)
            Spacer(minLength: 0)
            Text(verbatim: "iPhone · iPad")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Self.muted)
        }
    }

    /// Two lines of the localized headline: the first large, the second a size down, each kept
    /// to one line.
    private var headline: some View {
        let lines = String(localized: "口袋里的\nDeepSeek Harness").split(separator: "\n", maxSplits: 1).map(String.init)
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: lines.first ?? "")
                .font(Self.display(34))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if lines.count > 1 {
                Text(verbatim: lines[1])
                    .font(Self.display(27))
                    .kerning(-0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text("在 iPhone 和 iPad 上本机运行\n不连电脑，不连服务器")
                .font(.system(size: 12.5))
                .foregroundStyle(Self.body)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .foregroundStyle(Self.ink)
    }

    /// The system serif at its heaviest for Latin letters; Chinese falls back to a Mincho, the
    /// serif CJK face every iPhone has.
    private static func display(_ size: CGFloat) -> Font {
        let base = UIFont.systemFont(ofSize: size, weight: .black).fontDescriptor
        let serif = base.withDesign(.serif) ?? base
        let descriptor = serif.addingAttributes([.cascadeList: [UIFontDescriptor(name: "HiraMinProN-W6", size: size)]])
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    private var pocket: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: 26, bottomTrailingRadius: 26, topTrailingRadius: 30, style: .continuous)
        let stitch = UnevenRoundedRectangle(topLeadingRadius: 23, bottomLeadingRadius: 19, bottomTrailingRadius: 19, topTrailingRadius: 23, style: .continuous)
        return ZStack {
            shape
                .fill(Self.ink)
                .shadow(color: Self.ink.opacity(0.18), radius: 15, y: -10)
            stitch
                .strokeBorder(.white.opacity(0.26), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .padding(8)
            VStack(alignment: .leading, spacing: 16) {
                plugins
                Line()
                    .stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(height: 1.5)
                if withCode { code } else { link }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 26, leading: 24, bottom: 24, trailing: 24))
        }
    }

    /// The headline feature after running at all: the community's plugins, on the phone.
    private var plugins: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Self.pocketInk)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("支持第三方插件市场")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Self.pocketInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("浏览、安装社区插件，手机上直接启用")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Self.pocketMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var code: some View {
        HStack(spacing: 16) {
            Image("ShareQRCode")
                .interpolation(.none)
                .resizable()
                .frame(width: 76, height: 76)
                .frame(width: 92, height: 92)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("扫码了解和下载")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Self.pocketInk)
                Text("开源项目\nApp Store 与 TestFlight 均可安装")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Self.pocketMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在浏览器打开，了解和下载")
                .font(.system(size: 12))
                .foregroundStyle(Self.pocketMuted)
            HStack(spacing: 10) {
                Text(verbatim: Self.linkText)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .kerning(-0.2)
                    .foregroundStyle(Self.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Self.ink)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 14))
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("开源项目 · App Store 与 TestFlight 均可安装")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.541, green: 0.541, blue: 0.569))
        }
        .padding(.top, 4)
    }

    /// The link as someone would type it: no scheme.
    private static var linkText: String {
        let link = AppLinks.site.absoluteString
        return link.hasPrefix("https://") ? String(link.dropFirst("https://".count)) : link
    }
}

/// A horizontal rule as a path, so it can be dashed like the pocket's stitching.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
