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
/// reveal. iOS preloads the bundle JPG into a decoded `UIImage` and presents
/// `UIActivityViewController` directly via the topmost view controller — no
/// SwiftUI representable bridge, no async file-rep copy on tap.
/// macOS keeps the simpler `ShareLink` fallback.

struct ShareButtonsRow: View {
    #if os(iOS)
    @State private var preloadedImage: UIImage?
    @State private var preparedShareController: UIActivityViewController?
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
        .task(priority: .userInitiated) {
            await preloadImageIfNeeded()
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
        .task(priority: .userInitiated) {
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

    // MARK: - macOS share payload (unchanged ShareLink path)

    #if os(macOS)
    private static let shareItem: PnlCardImage = {
        let url = Bundle.main.url(forResource: "pnl-card", withExtension: "jpg")
            ?? Bundle.main.bundleURL
        return PnlCardImage(url: url)
    }()

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
            return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        }.value
    }

    private static let fallbackPreview = Image(systemName: "rectangle.on.rectangle.angled")
    #endif

    // MARK: - iOS preload + present

    #if os(iOS)
    @MainActor
    private func preloadImageIfNeeded() async {
        guard preloadedImage == nil || preparedShareController == nil else { return }
        let started = CFAbsoluteTimeGetCurrent()
        if preloadedImage == nil, let image = await Self.loadDecodedImage() {
            preloadedImage = image
        }
        if preparedShareController == nil,
           let controller = await Self.prepareShareController() {
            preparedShareController = controller
        }
        Self.logDuration("preload image", since: started)
    }

    private static func loadDecodedImage() async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard
                let url = Bundle.main.url(forResource: "pnl-card", withExtension: "jpg"),
                let image = UIImage(contentsOfFile: url.path)
            else { return nil }
            // Force-decode now so the share-sheet preview header doesn't lazy
            // decompress the JPG on the main thread when it appears.
            return image.preparingForDisplay() ?? image
        }.value
    }

    @MainActor
    private func handleShareTap() {
        RevealHaptics.shared.playCardPress()
        let tapStartedAt = CFAbsoluteTimeGetCurrent()

        if let controller = preparedShareController {
            Self.presentTopmost(controller, sourceTapAt: tapStartedAt)
            return
        }

        Task { @MainActor in
            if let controller = await Self.prepareShareController() {
                Self.logDuration("tap -> controller built", since: tapStartedAt)
                preparedShareController = controller
                Self.presentTopmost(controller, sourceTapAt: tapStartedAt)
                return
            }

            let image: UIImage?
            if let cached = preloadedImage {
                image = cached
            } else {
                image = await Self.loadDecodedImage()
            }
            if let image {
                preloadedImage = image
                let fallback = Self.makeFallbackController(with: image)
                Self.logDuration("tap -> controller built", since: tapStartedAt)
                Self.presentTopmost(fallback, sourceTapAt: tapStartedAt)
                return
            }

            Self.log("share prepare failed")
        }
    }

    @MainActor
    private static func prepareShareController() async -> UIActivityViewController? {
        guard let imageURL = Bundle.main.url(forResource: "pnl-card", withExtension: "jpg") else {
            return nil
        }
        let provider = NSItemProvider()
        provider.suggestedName = "polymarket-position.jpg"
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            do {
                completion(try Data(contentsOf: imageURL), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        await warmItemProvider(provider)

        let controller = UIActivityViewController(
            activityItems: [provider],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            if let error {
                Self.log("share completion error: \(error.localizedDescription)")
            } else {
                Self.log("share completion completed=\(completed)")
            }
        }
        controller.loadViewIfNeeded()
        return controller
    }

    private static func warmItemProvider(_ provider: NSItemProvider) async {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { _, _ in
                continuation.resume()
            }
        }
    }

    private static func makeFallbackController(with image: UIImage) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            if let error {
                Self.log("share completion error: \(error.localizedDescription)")
            } else {
                Self.log("share completion completed=\(completed)")
            }
        }
        return controller
    }

    private static func presentTopmost(
        _ vc: UIViewController,
        sourceTapAt tapStartedAt: CFAbsoluteTime
    ) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        guard
            let scene = activeScene,
            let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
            var top = keyWindow.rootViewController
        else {
            log("no presentable window")
            return
        }
        while let presented = top.presentedViewController {
            top = presented
        }

        // Popover anchor for iPad / Catalyst — required or `present` throws
        // on regular-width size classes.
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX,
                y: top.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        logDuration("tap -> present(animated:) call", since: tapStartedAt)
        top.present(vc, animated: true) {
            logDuration("tap -> share sheet visible", since: tapStartedAt)
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

/// macOS-only Transferable wrapper. Same `.jpeg` `FileRepresentation` that
/// makes `ShareLink` render the gallery-style preview header.
#if os(macOS)
private struct PnlCardImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { item in
            SentTransferredFile(item.url)
        }
        .suggestedFileName("polymarket-position.jpg")
    }
}
#endif

private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.snappy(duration: 0.25, extraBounce: 0.08),
                       value: configuration.isPressed)
    }
}
