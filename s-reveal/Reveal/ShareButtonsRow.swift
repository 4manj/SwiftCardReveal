import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import OSLog

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Single pill-shaped Share button shown below the card 2 seconds after the
/// reveal. On iOS we prebuild the share controller so the tap only has to
/// present it; macOS keeps the simpler `ShareLink` fallback.

struct ShareButtonsRow: View {
    #if os(iOS)
    @State private var preparedShareSheet: PreparedShareSheet?
    @State private var sharePresentationID: UInt = 0
    @State private var lastTapStartedAt: CFAbsoluteTime = 0
    #else
    /// Pre-decoded share-sheet thumbnail for the macOS `ShareLink` fallback.
    @State private var preview: Image = Self.fallbackPreview
    #endif

    var body: some View {
        #if os(iOS)
        Button(action: handleShareTap) {
            label
        }
        .buttonStyle(GlassPressStyle())
        .background(
            PreparedShareSheetPresenter(
                controller: preparedShareSheet?.controller,
                presentationID: sharePresentationID,
                tapStartedAt: lastTapStartedAt
            )
        )
        .task(priority: .userInitiated) {
            await warmShareSheetIfNeeded()
        }
        #else
        ShareLink(
            item: Self.shareItem,
            preview: SharePreview(
                "My Polymarket Position",
                image: preview
            )
        ) {
            label
        }
        .buttonStyle(GlassPressStyle())
        .simultaneousGesture(
            // .simultaneousGesture so it doesn't intercept the ShareLink's
            // own tap recognition; just fires haptic alongside.
            TapGesture().onEnded {
                #if os(iOS)
                // Centralized warm Core Haptics engine. Cold-starting a fresh
                // UIImpactFeedbackGenerator on each tap added perceptible
                // latency before the share sheet animation began.
                RevealHaptics.shared.playCardPress()
                #endif
            }
        )
        .task(priority: .userInitiated) {
            // Warm the shareItem static + pre-decode the preview thumbnail
            // before the user can plausibly tap. ShareButtonsRow only mounts
            // 2 s after the reveal (RevealOrchestrator.showButtons), so this
            // task always wins the race.
            _ = Self.shareItem
            if let warmed = await Self.decodeThumbnail() {
                preview = warmed
            }
        }
        #endif
    }

    private var label: some View {
        Text("Share")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.48),
                                .white.opacity(0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                Capsule()
                    .trim(from: 0.05, to: 0.45)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                    .padding(2)
                    .opacity(0.7)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 7)
            .shadow(color: .pink.opacity(0.10), radius: 20, x: 0, y: 14)
    }

    private static let shareImageURL: URL = {
        let url = Bundle.main.url(forResource: "pnl-card", withExtension: "jpg")
            ?? Bundle.main.bundleURL
        return url
    }()

    /// Transferable wrapper around the bundled card JPG. Sharing a bare `URL`
    /// got the file-style preview row; declaring an explicit `.jpeg`
    /// `FileRepresentation` is what tells iOS "this is photo data" and
    /// triggers the tall image preview header at the top of the share sheet —
    /// the same one Photos.app shows.
    private static let shareItem: PnlCardImage = {
        let url = shareImageURL
        return PnlCardImage(url: url)
    }()

    /// Off-main-thread thumbnail decode. Uses ImageIO's thumbnail path with
    /// `kCGImageSourceShouldCacheImmediately` so the bitmap is fully decoded
    /// before it ever reaches SwiftUI — no lazy decompression on tap.
    /// 512 px is well above what the share sheet thumbnail renders at, but
    /// keeps the bitmap small enough to decode in well under 50 ms.
    private static func decodeThumbnail() async -> Image? {
        await Task.detached(priority: .userInitiated) {
            guard
                let url = Bundle.main.url(forResource: "pnl-card", withExtension: "jpg"),
                let src = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            guard
                let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            else { return nil }

            #if os(macOS)
            return Image(nsImage: NSImage(cgImage: cg, size: .zero))
            #else
            return Image(uiImage: UIImage(cgImage: cg))
            #endif
        }.value
    }

    private static let fallbackPreview = Image(systemName: "rectangle.on.rectangle.angled")

    #if os(iOS)
    private func handleShareTap() {
        RevealHaptics.shared.playCardPress()

        let tapStartedAt = CFAbsoluteTimeGetCurrent()
        lastTapStartedAt = tapStartedAt
        Self.log("tap -> haptic fired")

        if preparedShareSheet == nil {
            let buildStartedAt = CFAbsoluteTimeGetCurrent()
            preparedShareSheet = Self.makePreparedShareSheet()
            Self.logDuration(
                "tap fallback build",
                since: buildStartedAt
            )
        }

        guard preparedShareSheet != nil else {
            Self.log("tap -> no prepared controller available")
            return
        }

        sharePresentationID &+= 1
        Self.logDuration("tap -> presentation request", since: tapStartedAt)
    }

    @MainActor
    private func warmShareSheetIfNeeded() async {
        guard preparedShareSheet == nil else { return }

        let warmStartedAt = CFAbsoluteTimeGetCurrent()
        Self.log("warm start")
        _ = Self.shareItem

        let provider = Self.makeJPEGItemProvider(url: Self.shareImageURL)
        let providerWarmStartedAt = CFAbsoluteTimeGetCurrent()
        await Self.warmFileRepresentation(provider)
        Self.logDuration("warm item provider file representation", since: providerWarmStartedAt)

        let controllerBuildStartedAt = CFAbsoluteTimeGetCurrent()
        preparedShareSheet = Self.makePreparedShareSheet(using: provider)
        Self.logDuration("warm activity controller init", since: controllerBuildStartedAt)
        Self.logDuration("warm total", since: warmStartedAt)
    }

    private static func makePreparedShareSheet(
        using provider: NSItemProvider? = nil
    ) -> PreparedShareSheet? {
        let provider = provider ?? makeJPEGItemProvider(url: shareImageURL)
        let controller = UIActivityViewController(
            activityItems: [provider],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            if let error {
                log("share completion error: \(error.localizedDescription)")
            } else {
                log("share completion completed=\(completed)")
            }
        }

        // Force eager UIKit setup while the button is merely visible, not
        // when the user taps.
        _ = controller.view
        return PreparedShareSheet(controller: controller)
    }

    private static func makeJPEGItemProvider(url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "polymarket-position.jpg"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    private static func warmFileRepresentation(_ provider: NSItemProvider) async {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { _, error in
                if let error {
                    log("warm file representation error: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "aman.s-reveal",
        category: "ShareSheet"
    )

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    static func logDuration(_ label: String, since start: CFAbsoluteTime) {
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        logger.log("\(label, privacy: .public): \(milliseconds, format: .fixed(precision: 1)) ms")
    }
    #endif
}

/// Photo-typed share payload. `FileRepresentation(exportedContentType: .jpeg)`
/// is the signal iOS uses to decide between the file-row preview and the tall
/// gallery-style image preview — without it, sharing a bundle URL falls back
/// to the file-row look.
private struct PnlCardImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { item in
            SentTransferredFile(item.url)
        }
        .suggestedFileName("polymarket-position.jpg")
    }
}

private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.snappy(duration: 0.25, extraBounce: 0.08),
                       value: configuration.isPressed)
    }
}

#if os(iOS)
private struct PreparedShareSheet {
    let controller: UIActivityViewController
}

private struct PreparedShareSheetPresenter: UIViewControllerRepresentable {
    let controller: UIActivityViewController?
    let presentationID: UInt
    let tapStartedAt: CFAbsoluteTime

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostViewController {
        HostViewController()
    }

    func updateUIViewController(_ uiViewController: HostViewController, context: Context) {
        guard presentationID != 0 else { return }
        guard context.coordinator.lastPresentedID != presentationID else { return }
        guard let controller else { return }
        guard uiViewController.presentedViewController == nil else { return }

        context.coordinator.lastPresentedID = presentationID
        ShareButtonsRow.logDuration("tap -> presenter update", since: tapStartedAt)

        DispatchQueue.main.async {
            guard uiViewController.presentedViewController == nil else { return }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = uiViewController.view
                popover.sourceRect = CGRect(
                    x: uiViewController.view.bounds.midX,
                    y: uiViewController.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            ShareButtonsRow.logDuration("tap -> present(animated:) call", since: tapStartedAt)
            uiViewController.present(controller, animated: true) {
                ShareButtonsRow.logDuration("tap -> share sheet visible", since: tapStartedAt)
            }
        }
    }

    final class Coordinator {
        var lastPresentedID: UInt = 0
    }

    final class HostViewController: UIViewController {
        override func loadView() {
            view = UIView(frame: .zero)
            view.isHidden = true
            view.isUserInteractionEnabled = false
        }
    }
}
#endif
