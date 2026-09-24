import AppKit
import ImageIO
import MetricBus
import SchemaKit
import SensorKit
import SwiftUI

/// Hosts the SwiftUI editor in a plain AppKit window.
///
/// An agent app has no main menu and no windows by default, so the window is
/// created on demand and the app is activated explicitly -- otherwise it appears
/// behind whatever the user was doing and cannot take keyboard focus.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: WidgetStore
    private let preview: StripPreview
    /// A second renderer, because the import sheet previews a widget that is not
    /// the one being edited and both are on screen at once.
    private let importPreview: StripPreview
    private let coordinator = ImportCoordinator()
    private let metrics: [MetricDescriptor]

    init(store: WidgetStore, bus: MetricBus) {
        self.store = store
        self.preview = StripPreview(bus: bus)
        self.importPreview = StripPreview(bus: bus)
        // Snapshot once: the picker's contents should not shift under the user
        // mid-scroll because a volume happened to mount.
        self.metrics = bus.availableMetrics().sorted {
            ($0.group, $0.displayName) < ($1.group, $1.displayName)
        }
        super.init()
    }

    /// Presents a widget that arrived from outside the app.
    func offer(url: URL) {
        show()
        coordinator.offer(url: url)
    }

    func show() {
        if window == nil { window = makeWindow() }
        preview.start()
        importPreview.start()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Stop sampling for the preview, and drop the Dock icon again: this is a
        // menu bar app, and an agent that leaves itself in the Dock after you
        // close its one window is a nuisance.
        preview.stop()
        importPreview.stop()
        store.saveNow()
        NSApp.setActivationPolicy(.accessory)

        // Drop the whole SwiftUI hierarchy rather than keeping it warm. Whether
        // this reclaims anything worth having is a measurement, not a guess --
        // see `--editor-cycle`.
        window?.contentView = nil
        window = nil
    }

    /// Renders the editor's own view hierarchy to a PNG.
    ///
    /// The menu bar cannot be screenshotted without Screen Recording permission,
    /// and neither can a window -- but a view can always draw *itself*. This
    /// makes the editor reviewable the same way the strip already is, which
    /// matters because a UI nobody can look at is a UI nobody can critique.
    func dump(to path: String) -> Bool {
        guard let window, let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        window.display()

        // Renders the Core Animation layer tree.
        //
        // **Partial by design, and worth being honest about.** Three approaches
        // were tried: `cacheDisplay` captured only the preview strip,
        // `dataWithPDF` produced an empty rectangle, and this one captures the
        // strip and the window chrome but not the sidebar, cell row, or
        // inspector. Everything missing lives inside a scroll-backed container,
        // whose contents AppKit composites from a separate backing store that
        // none of these paths can reach.
        //
        // It is kept because the part it *does* capture is the part unique to
        // this app -- the live strip, rendered by the real composer -- which is
        // exactly what needs checking after a change to the drawing code. The
        // rest of the editor is ordinary AppKit controls, and reviewing those
        // means opening the window.
        guard let layer = view.layer else { return false }

        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil,
            width: Int(view.bounds.width * scale),
            height: Int(view.bounds.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.scaleBy(x: scale, y: scale)
        // Layer coordinates run top-down; the bitmap context runs bottom-up.
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
              ) else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Widgets", comment: "Title of the editor window")
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 440)
        window.contentView = NSHostingView(
            rootView: EditorView(
                store: store,
                preview: preview,
                importPreview: importPreview,
                coordinator: coordinator,
                metrics: metrics
            )
        )
        return window
    }
}
