import SwiftUI

extension EnvironmentValues {
    /// The open conversation, for rows that read its attachments (images) or act on it.
    @Entry var sessionModel: SessionModel?
}

/// Images of one message (C-26): a single image keeps its shape with the long side at
/// 240 (aspect clamped to 1:4…4:1), several show as 64 pt squares. Tap for the viewer.
struct ImageGroup: View {
    let attachments: [Attachment]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let images = attachments.filter { $0.attachmentId != nil }
        if images.count == 1, let only = images.first {
            AttachmentThumb(attachment: only, size: Self.singleSize(only))
        } else if !images.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, attachment in
                    AttachmentThumb(attachment: attachment, size: CGSize(width: 64, height: 64))
                }
            }
        }
    }

    static func singleSize(_ attachment: Attachment) -> CGSize {
        guard let width = attachment.width, let height = attachment.height else { return singleSize(nil) }
        return singleSize(CGSize(width: width, height: height))
    }

    /// The same box for an image whose pixel size is known some other way; nil while it is not.
    static func singleSize(_ pixels: CGSize?) -> CGSize {
        let long: CGFloat = 240
        guard let pixels, pixels.width > 0, pixels.height > 0 else { return CGSize(width: long, height: long * 0.75) }
        let ratio = min(4, max(0.25, pixels.width / pixels.height))
        return ratio >= 1 ? CGSize(width: long, height: long / ratio) : CGSize(width: long * ratio, height: long)
    }
}

/// An image a reply shows with `![alt](path)`. The path is a file in the engine's
/// filesystem, relative to the session's working directory or absolute, and that
/// filesystem is on this device, so the bytes come straight from disk. It looks and
/// opens like a single attachment. A path that is not a readable image shows its alt
/// text instead, which is what the reply showed before images were drawn at all.
struct ReplyImage: View {
    let alt: String
    let destination: String
    @Environment(\.fileLinkScope) private var scope
    @State private var image: UIImage?
    @State private var failed = false
    @State private var viewing = false

    /// Decoded files by path and modification time: lazy rows are rebuilt whenever they
    /// scroll back, and a streaming reply re-renders every frame.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 << 20
        return cache
    }()

    private var name: String { alt.isEmpty ? URL(fileURLWithPath: destination).lastPathComponent : alt }

    var body: some View {
        Group {
            if let image {
                let size = ImageGroup.singleSize(image.size)
                Button { viewing = true } label: {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel(Text(name))
                .accessibilityHint("查看大图")
            } else if failed {
                Text(name).foregroundStyle(Palette.secondary)
            } else {
                let size = ImageGroup.singleSize(nil)
                Palette.field.overlay(ProgressView()).frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .task(id: destination) {
            image = nil
            failed = false
            guard let url = Self.file(destination, root: scope?.root) else { failed = true; return }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let key = "\(url.path)#\(modified)" as NSString
            if let hit = Self.cache.object(forKey: key) { image = hit; return }
            guard let decoded = await Task.detached(priority: .userInitiated, operation: { ZoomableImage.decode(url) }).value else { failed = true; return }
            Self.cache.setObject(decoded, forKey: key, cost: (decoded.cgImage?.bytesPerRow ?? 0) * (decoded.cgImage?.height ?? 0))
            image = decoded
        }
        .fullScreenCover(isPresented: $viewing) {
            if let image { ImageViewer(image: image, name: name) }
        }
    }

    /// Where `destination` is on disk, if it is there. The model writes paths as they are
    /// or percent-encoded, so both readings are tried.
    static func file(_ destination: String, root: String?) -> URL? {
        var path = destination
        if path.lowercased().hasPrefix("file://") { path = String(path.dropFirst(7)) }
        for candidate in [path, path.removingPercentEncoding ?? path] {
            let engine: String
            if candidate.hasPrefix("/") { engine = candidate }
            else if candidate == "~" || candidate.hasPrefix("~/") { engine = EnginePaths.home + candidate.dropFirst() }
            else if let root { engine = (root as NSString).appendingPathComponent(candidate) }
            else { continue }
            let url = EnginePaths.real(engine).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// One attachment image, filled into `size`; 「图片加载失败，轻点重试」 on failure.
struct AttachmentThumb: View {
    let attachment: Attachment
    let size: CGSize
    @Environment(\.sessionModel) private var model
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var viewing = false

    var body: some View {
        Group {
            if let image {
                Button { viewing = true } label: {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(attachment.name ?? String(localized: "图片")))
                .accessibilityHint("查看大图")
            } else if failed {
                Button { failed = false; attempt += 1 } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                        if size.width > 100 { Text("图片加载失败，轻点重试").font(.caption) }
                    }
                    .foregroundStyle(Palette.secondary)
                    .frame(width: size.width, height: size.height)
                    .background(Palette.field)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("图片加载失败，轻点重试")
            } else {
                Palette.field.overlay(ProgressView()).frame(width: size.width, height: size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: size.width > 100 ? 16 : 10, style: .continuous))
        .task(id: attempt) {
            guard image == nil, let id = attachment.attachmentId, let model else { return }
            if let cached = model.cachedImage(id) { image = cached; return }
            if let loaded = await model.image(attachment) { image = loaded } else { failed = true }
        }
        .fullScreenCover(isPresented: $viewing) {
            if let image { ImageViewer(image: image, name: attachment.name) }
        }
    }
}

/// Full-screen image: pinch or double-tap to zoom, drag to pan, share or close.
struct ImageViewer: View {
    let image: UIImage
    var name: String?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = max(1, min(6, lastScale * $0.magnification)) }
                        .onEnded { _ in
                            lastScale = scale
                            if scale == 1 { withAnimation(.snappy) { offset = .zero }; lastOffset = .zero }
                        }
                        .simultaneously(with: DragGesture()
                            .onChanged { value in
                                // At 1x a downward drag closes, as the system photo viewer does.
                                if scale > 1 {
                                    offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                                } else {
                                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                                }
                            }
                            .onEnded { value in
                                if scale <= 1 {
                                    if value.translation.height > 120 { dismiss() } else { withAnimation(.snappy) { offset = .zero } }
                                } else {
                                    lastOffset = offset
                                }
                            })
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
                    }
                    lastScale = scale
                    lastOffset = offset
                }
                .accessibilityLabel(Text(name ?? String(localized: "图片")))
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭")
                Spacer()
                ShareLink(item: Image(uiImage: image), preview: SharePreview(name ?? String(localized: "图片"), image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("分享")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
        }
        .statusBarHidden()
    }
}
