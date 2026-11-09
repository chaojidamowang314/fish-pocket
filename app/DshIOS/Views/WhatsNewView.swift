import SwiftUI

/// 「新功能」 after an update (`WhatsNew.take()`): the version's highlights and a way on.
struct WhatsNewSheet: View {
    let release: WhatsNew.Release
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WhatsNewContent(release: release)
                .safeAreaInset(edge: .bottom) {
                    Button("继续") {
                        Haptics.tap()
                        dismiss()
                    }
                    .buttonStyle(.capsule())
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    // The list fades out under the button instead of meeting an edge.
                    .background {
                        LinearGradient(stops: [.init(color: Palette.grouped.opacity(0), location: 0),
                                               .init(color: Palette.grouped, location: 0.4)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                    }
                }
                .closeButton(dismiss)
        }
    }
}

/// 设置 → 关于 → 新功能: the same page, for whoever closed it or never saw it.
struct WhatsNewPage: View {
    let release: WhatsNew.Release

    var body: some View {
        WhatsNewContent(release: release)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WhatsNewContent: View {
    let release: WhatsNew.Release
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                header
                VStack(spacing: 12) {
                    ForEach(Array(release.features.enumerated()), id: \.element.id) { index, feature in
                        FeatureCard(feature: feature, delay: 0.18 + Double(index) * 0.08)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.grouped)
        .onAppear {
            if reduceMotion { appeared = true } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { appeared = true }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            AppIconMark()
                .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.82)
            Text("新功能")
                .font(.largeTitle.bold())
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 22)
            Text("版本 \(release.label)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Palette.control, in: Capsule())
                .padding(.top, 10)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 10)
    }
}

/// One feature: a card that rises into place after the ones above it, its icon giving a nod.
private struct FeatureCard: View {
    let feature: WhatsNew.Feature
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var nod = 0

    /// White on the grey page; in the dark, a step up from the near-black page.
    private var fill: Color { colorScheme == .dark ? Palette.field : Palette.background }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.onInk)
                .symbolEffect(.bounce, value: nod)
                .frame(width: 46, height: 46)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.stroke.opacity(0.6)) }
        .accessibilityElement(children: .combine)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 22)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .task {
            guard !reduceMotion else {
                appeared = true
                return
            }
            try? await Task.sleep(for: .seconds(delay))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { appeared = true }
            try? await Task.sleep(for: .seconds(0.12))
            nod += 1
        }
    }
}

/// The app's own icon, as the home screen shows it.
private struct AppIconMark: View {
    var size: CGFloat = 84

    var body: some View {
        Group {
            if let image = UIImage(named: "AppIcon") {
                Image(uiImage: image).resizable()
            } else {
                Image("LaunchMark").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}
