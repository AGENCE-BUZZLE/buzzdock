import SwiftUI
import AppKit
import ScreenCaptureKit

/// Aperçus des fenêtres d'une app (appui long sur son icône) : vignettes cliquables au-dessus du Dock.
/// Les images demandent l'autorisation « Enregistrement de l'écran » ; sans elle, titres seuls.
@MainActor
final class WindowPreviewController {
    static let shared = WindowPreviewController()

    struct Item: Identifiable {
        let id: CGWindowID
        let title: String
        let frame: CGRect
        var image: NSImage?
        let isMinimized: Bool
    }

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private weak var store: DockStore?

    var isVisible: Bool { panel?.isVisible == true }

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    func show(for entry: DockEntry, store: DockStore) {
        hide()
        self.store = store
        guard let app = store.runningApp(for: entry) else {
            DockMenu.show(for: entry, store: store)
            return
        }
        let anchor = NSEvent.mouseLocation
        store.isInteracting = true
        Task { @MainActor in
            let items = await Self.loadItems(of: app)
            guard !items.isEmpty else {
                store.isInteracting = false
                DockMenu.show(for: entry, store: store)
                return
            }
            present(items: items, app: app, entry: entry, anchor: anchor)
        }
    }

    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let panel {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        panel = nil
        store?.isInteracting = false
    }

    private func present(items: [Item], app: NSRunningApplication, entry: DockEntry, anchor: NSPoint) {
        let view = WindowPreviewStrip(
            appName: entry.name,
            items: items,
            canCapture: Self.canCapture,
            onPick: { [weak self] item in
                self?.hide()
                Self.focus(item, of: app)
            },
            onNewWindow: { [weak self] in
                self?.hide()
                WindowService.newWindow(for: app)
            },
            onAllowCapture: { [weak self] in
                self?.hide()
                CGRequestScreenCaptureAccess()
            }
        )
        let host = FirstMouseHostingView(rootView: view)   // le 1er clic choisit déjà la fenêtre
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var x = anchor.x - size.width / 2
        if let visible = screen?.frame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let frame = NSRect(x: x, y: DockPopup.barTop + 10, width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        self.panel = panel

        // un clic ailleurs, ou Échap, referme les aperçus
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.type == .keyDown && event.keyCode == 53 { self.hide(); return }
                if event.type == .leftMouseDown && event.window !== panel { self.hide() }
            }
            return event
        }) { monitors.append(local) }
    }

    // MARK: Fenêtres et vignettes

    private static func loadItems(of app: NSRunningApplication) async -> [Item] {
        let pid = app.processIdentifier
        var items: [Item] = []
        if canCapture, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0
                    && $0.frame.width > 120 && $0.frame.height > 80
                    && !($0.title ?? "").isEmpty
            }
            for window in windows.prefix(12) {
                var image: NSImage?
                if window.isOnScreen {
                    let config = SCStreamConfiguration()
                    let scale = 400 / max(window.frame.width, 1)
                    config.width = Int(window.frame.width * scale * 2)
                    config.height = Int(window.frame.height * scale * 2)
                    config.showsCursor = false
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                        image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                    }
                }
                items.append(Item(id: window.windowID, title: window.title ?? "", frame: window.frame,
                                  image: image, isMinimized: !window.isOnScreen))
            }
        }
        if items.isEmpty {
            // sans l'autorisation : titres des fenêtres par l'Accessibilité
            for (index, window) in WindowService.windows(of: app).enumerated() {
                items.append(Item(id: CGWindowID(index + 1), title: window.title, frame: .zero, image: nil, isMinimized: window.isMinimized))
            }
        }
        return items
    }

    /// Ramène la fenêtre choisie : retrouvée par son titre (et sa taille) dans l'Accessibilité.
    private static func focus(_ item: Item, of app: NSRunningApplication) {
        let windows = WindowService.windows(of: app)
        let match = windows.first { $0.title == item.title } ?? windows.first
        if let match {
            WindowService.focus(match, of: app)
        } else {
            WindowService.activate(app)
        }
    }
}

struct WindowPreviewStrip: View {
    let appName: String
    let items: [WindowPreviewController.Item]
    let canCapture: Bool
    let onPick: (WindowPreviewController.Item) -> Void
    let onNewWindow: () -> Void
    let onAllowCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(appName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Nouvelle fenêtre", action: onNewWindow).buttonStyle(.link).font(.system(size: 12))
            }
            let row = HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    PreviewCard(item: item, onPick: onPick)
                }
            }
            if items.count > 4 {
                // trop de fenêtres pour l'écran : rangée défilante
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .frame(width: min(CGFloat(items.count) * 212, (NSScreen.main?.visibleFrame.width ?? 1400) - 120))
            } else {
                row
            }
            if !canCapture {
                Button("Afficher les aperçus des fenêtres (autoriser l'enregistrement de l'écran)", action: onAllowCapture)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
        .fixedSize()
    }
}

struct PreviewCard: View {
    let item: WindowPreviewController.Item
    let onPick: (WindowPreviewController.Item) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else {
                    Image(systemName: item.isMinimized ? "rectangle.bottomhalf.inset.filled" : "macwindow")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 130)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2)
            )
            Text((item.isMinimized ? "◆ " : "") + item.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200)
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onPick(item) }
    }
}
