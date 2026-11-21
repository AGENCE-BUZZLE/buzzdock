import SwiftUI
import AppKit

/// Fenêtre plein écran du lanceur : prend le clavier sans activer l'app (comme Spotlight).
final class LauncherPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    private let store: DockStore
    private var panel: LauncherPanel?

    init(store: DockStore) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }

        let panel = LauncherPanel(frame: screen.frame)
        panel.delegate = self
        let view = LauncherView(
            apps: AppCatalog.scan(),
            onOpen: { [weak self] app in
                guard let self else { return }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: app.url, configuration: config)
                self.hide()
            },
            onPin: { [weak self] app in self?.store.pin(app.url) },
            folders: store.folders,
            onAddToFolder: { [weak self] app, folderID in
                guard let self else { return }
                if let folderID { self.store.add(app.url, to: folderID) } else { self.store.createFolder(with: [app.url]) }
            },
            onClose: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.alphaValue = 0
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // Clic dans une autre app : on referme.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }
}

struct LauncherView: View {
    let apps: [AppInfo]
    let onOpen: (AppInfo) -> Void
    let onPin: (AppInfo) -> Void
    let folders: [AppFolder]
    let onAddToFolder: (AppInfo, UUID?) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var category: String?
    @FocusState private var searchFocused: Bool

    private var categories: [String] {
        let counts = Dictionary(grouping: apps, by: \.category).mapValues(\.count)
        return counts.keys
            .filter { $0 != "Autres" }
            .sorted { counts[$0, default: 0] > counts[$1, default: 0] }
            + (counts["Autres"] != nil ? ["Autres"] : [])
    }

    private var filtered: [AppInfo] {
        let byCategory = category.map { c in apps.filter { $0.category == c } } ?? apps
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return byCategory }
        return byCategory
            .filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                // Les noms qui commencent par la recherche passent devant
                let pa = a.name.lowercased().hasPrefix(q.lowercased())
                let pb = b.name.lowercased().hasPrefix(q.lowercased())
                if pa != pb { return pa }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(spacing: 22) {
                searchField
                categoryBar
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 28)], spacing: 30) {
                        ForEach(filtered) { app in
                            LauncherCell(app: app)
                                .onTapGesture { onOpen(app) }
                                .contextMenu {
                                    Menu("Ajouter au dossier") {
                                        ForEach(folders) { folder in
                                            Button(folder.name) { onAddToFolder(app, folder.id) }
                                        }
                                        Divider()
                                        Button("Nouveau dossier") { onAddToFolder(app, nil) }
                                    }
                                    Button("Garder dans le Dock classique") { onPin(app) }
                                    Button("Afficher dans le Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                                    }
                                }
                                .onDrag { NSItemProvider(object: app.url as NSURL) }
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.never)
            }
            .padding(.top, 60)
        }
        .onExitCommand(perform: onClose)
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Rechercher", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit {
                    if let first = filtered.first { onOpen(first) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
    }

    private var categoryBar: some View {
        HStack(spacing: 8) {
            chip("Toutes", selected: category == nil) { category = nil }
            ForEach(categories, id: \.self) { name in
                chip(name, selected: category == name) { category = (category == name) ? nil : name }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.28) : Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(.white)
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}

struct LauncherCell: View {
    let app: AppInfo
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: IconCache.icon(for: app.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .scaleEffect(hovering ? 1.06 : 1)
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Flou plein écran derrière le lanceur.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
