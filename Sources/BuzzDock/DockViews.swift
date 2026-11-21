import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DockRootView: View {
    @EnvironmentObject private var store: DockStore
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var hover: HoverModel
    let onOpenLauncher: () -> Void

    var body: some View {
        if settings.style == .widgets {
            WidgetDockView()
        } else {
            classic
        }
    }

    private var classic: some View {
        let slots = store.slots
        let m = DockMetrics(slots: slots, settings: settings)
        let centers = m.restingCenters
        let hovered = m.hoveredIndex(mouseX: hover.mouseX)

        return HStack(alignment: .bottom, spacing: m.spacing) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                let scale = m.scale(forCenter: centers[index], mouseX: hover.mouseX)
                slotView(slot, size: m.base * scale, showLabel: hovered == index, metrics: m)
            }
        }
        .padding(.horizontal, m.padding)
        .padding(.bottom, m.padding)
        // Le fond suit la largeur réelle des icônes (il s'élargit avec l'effet loupe)
        .background(alignment: .bottom) {
            DockBackground(cornerRadius: m.cornerRadius)
                .frame(height: m.barHeight)
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    if store.draggingID != nil {
                        store.draggingID = nil
                        return true
                    }
                    // Une app déposée sur la barre s'épingle à la fin
                    loadURLs(providers) { urls in urls.forEach { store.pin($0) } }
                    return true
                }
        }
        .padding(.bottom, m.bottomGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.82), value: hover.mouseX)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: slots.map(\.id))
    }

    @ViewBuilder
    private func slotView(_ slot: DockSlot, size: CGFloat, showLabel: Bool, metrics m: DockMetrics) -> some View {
        switch slot {
        case .launcher:
            LauncherButton(size: size, showLabel: showLabel, indicatorHeight: m.indicatorHeight, action: onOpenLauncher)
        case .app(let entry):
            AppIconView(entry: entry, size: size, showLabel: showLabel, indicatorHeight: m.indicatorHeight)
        case .separator:
            Rectangle()
                .fill(Color.primary.opacity(0.25))
                .frame(width: m.separatorWidth, height: m.base * 0.8)
                .padding(.bottom, m.indicatorHeight + m.base * 0.1)
        case .downloads:
            DownloadsStackView(size: size, showLabel: showLabel, indicatorHeight: m.indicatorHeight)
        case .trash:
            TrashView(size: size, showLabel: showLabel, indicatorHeight: m.indicatorHeight)
        }
    }
}

// MARK: Fond « verre »

struct DockBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.04))
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        } else {
            fallback(shape)
        }
        #else
        fallback(shape)
        #endif
    }

    private func fallback(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

// MARK: Icône d'app

struct DockItemChrome<Content: View>: View {
    let label: String
    let size: CGFloat
    let showLabel: Bool
    let isRunning: Bool
    let indicatorHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 2) {
            content()
                .frame(width: size, height: size)
            Circle()
                .fill(Color.primary.opacity(isRunning ? 0.75 : 0))
                .frame(width: 4, height: 4)
                .frame(height: indicatorHeight - 2)
        }
        .overlay(alignment: .top) {
            if showLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .offset(y: -30)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }
}

struct AppIconView: View {
    @EnvironmentObject private var store: DockStore
    let entry: DockEntry
    let size: CGFloat
    let showLabel: Bool
    let indicatorHeight: CGFloat
    @State private var bounce = false

    var body: some View {
        DockItemChrome(
            label: entry.name,
            size: size,
            showLabel: showLabel,
            isRunning: entry.isRunning,
            indicatorHeight: indicatorHeight
        ) {
            Group {
                if entry.url.lastPathComponent == "Calendar.app" {
                    CalendarIcon(size: size)
                } else {
                    Image(nsImage: IconCache.icon(for: entry.id))
                        .resizable()
                        .interpolation(.high)
                }
            }
            .offset(y: bounce ? -size * 0.35 : 0)
        }
        .opacity(store.draggingID == entry.id ? 0.4 : 1)
        .onTapGesture { store.open(entry) }
        .onChange(of: entry.isLaunching) { _, launching in
            if launching { animateBounce() }
        }
        .onDrag {
            store.draggingID = entry.id
            return NSItemProvider(object: entry.url as NSURL)
        }
        .onDrop(of: [UTType.fileURL], delegate: AppDropDelegate(entry: entry, store: store))
        .contextMenu {
            if entry.isRunning {
                Button("Masquer") { store.hide(entry) }
                Button("Quitter") { store.quit(entry) }
                Divider()
            }
            if entry.isPinned {
                Button("Retirer du Dock") { store.unpin(entry) }
            } else {
                Button("Garder dans le Dock") { store.pin(entry.url) }
            }
            Button("Afficher dans le Finder") { store.revealInFinder(entry) }
        }
    }

    /// Rebond de lancement, tant que l'app démarre (3 rebonds au plus).
    private func animateBounce(count: Int = 0) {
        guard count < 3, store.launching.contains(entry.id) else {
            withAnimation(.easeOut(duration: 0.2)) { bounce = false }
            return
        }
        withAnimation(.easeOut(duration: 0.28)) { bounce = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeIn(duration: 0.28)) { bounce = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                animateBounce(count: count + 1)
            }
        }
    }
}

/// Glisser-déposer sur une icône : réorganiser, épingler, ou ouvrir des fichiers avec l'app.
struct AppDropDelegate: DropDelegate {
    let entry: DockEntry
    let store: DockStore

    func dropEntered(info: DropInfo) {
        Task { @MainActor in
            guard let dragging = store.draggingID, dragging != entry.id else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                store.movePin(dragging, to: entry.id)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        Task { @MainActor in
            if let dragging = store.draggingID {
                // Une app ouverte non épinglée glissée dans la rangée s'épingle à cet endroit
                if store.pinIndex(of: dragging) == nil {
                    store.pin(URL(fileURLWithPath: dragging), at: store.pinIndex(of: entry.id))
                }
                store.draggingID = nil
                return
            }
            loadURLs(providers) { urls in
                let apps = urls.filter { $0.pathExtension == "app" }
                let files = urls.filter { $0.pathExtension != "app" }
                let index = store.pinIndex(of: entry.id)
                apps.forEach { store.pin($0, at: index) }
                if !files.isEmpty { store.open(files: files, with: entry) }
            }
        }
        return true
    }
}

/// Charge les URL de fichiers d'un glisser-déposer, puis rappelle sur le fil principal.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(urls) }
    }
}

// MARK: Bouton du lanceur

struct LauncherButton: View {
    static let tileColors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .blue, .indigo, .purple]
    let size: CGFloat
    let showLabel: Bool
    let indicatorHeight: CGFloat
    let action: () -> Void

    var body: some View {
        DockItemChrome(label: "Applications", size: size, showLabel: showLabel, isRunning: false, indicatorHeight: indicatorHeight) {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.98), Color(white: 0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(size * 0.15), spacing: size * 0.06), count: 3),
                              spacing: size * 0.06) {
                        ForEach(0..<9, id: \.self) { i in
                            RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                                .fill(Self.tileColors[i])
                                .frame(width: size * 0.15, height: size * 0.15)
                        }
                    }
                )
                .padding(size * 0.08)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .onTapGesture(perform: action)
        .contextMenu {
            Button("Ouvrir le lanceur", action: action)
            Divider()
            Button("Quitter BuzzDock (le Dock de macOS revient)") { NSApp.terminate(nil) }
        }
    }
}

// MARK: Icône Calendrier avec la date du jour (comme le Dock d'Apple)

struct CalendarIcon: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let date = context.date
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(Color.white)
                .overlay(
                    VStack(spacing: -size * 0.04) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "fr_FR"))).capitalized)
                            .font(.system(size: size * 0.16, weight: .semibold))
                            .foregroundStyle(Color.red)
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: size * 0.46, weight: .regular))
                            .foregroundStyle(Color.black.opacity(0.85))
                    }
                )
                .padding(size * 0.085)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }
}

// MARK: Pile Téléchargements

struct DownloadsStackView: View {
    @EnvironmentObject private var store: DockStore
    let size: CGFloat
    let showLabel: Bool
    let indicatorHeight: CGFloat
    @State private var isOpen = false

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var body: some View {
        DockItemChrome(label: "Téléchargements", size: size, showLabel: showLabel && !isOpen, isRunning: false, indicatorHeight: indicatorHeight) {
            Image(nsImage: IconCache.icon(for: folder.path))
                .resizable()
                .interpolation(.high)
        }
        .onTapGesture { isOpen.toggle() }
        .onChange(of: isOpen) { _, open in store.isInteracting = open }
        .onReceive(NotificationCenter.default.publisher(for: .buzzClosePopovers)) { _ in isOpen = false }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DownloadsGrid(folder: folder) { isOpen = false }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { urls in
                for url in urls {
                    let target = folder.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.moveItem(at: url, to: target)
                }
            }
            return true
        }
    }
}

struct DownloadsGrid: View {
    let folder: URL
    let onClose: () -> Void
    @State private var files: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Téléchargements")
                .font(.headline)
            if files.isEmpty {
                Text("Aucun fichier récent")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 10), count: 4), spacing: 12) {
                    ForEach(files, id: \.self) { url in
                        VStack(spacing: 4) {
                            Image(nsImage: IconCache.icon(for: url.path))
                                .resizable()
                                .frame(width: 48, height: 48)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 84)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NSWorkspace.shared.open(url)
                            onClose()
                        }
                        .onDrag { NSItemProvider(object: url as NSURL) }
                    }
                }
            }
            Divider()
            Button("Ouvrir dans le Finder") {
                NSWorkspace.shared.open(folder)
                onClose()
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { files = Self.recentFiles(in: folder) }
    }

    /// Les 12 fichiers les plus récemment ajoutés.
    static func recentFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        func date(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }
        return Array(items.sorted { date($0) > date($1) }.prefix(12))
    }
}

// MARK: Corbeille

struct TrashView: View {
    @EnvironmentObject private var store: DockStore
    let size: CGFloat
    let showLabel: Bool
    let indicatorHeight: CGFloat

    private var trashURL: URL {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    var body: some View {
        DockItemChrome(label: "Corbeille", size: size, showLabel: showLabel, isRunning: false, indicatorHeight: indicatorHeight) {
            Image(nsImage: NSImage(named: NSImage.trashEmptyName) ?? NSImage())
                .resizable()
                .interpolation(.high)
        }
        .onTapGesture { NSWorkspace.shared.open(trashURL) }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            if let dragging = store.draggingID, let index = store.pinIndex(of: dragging) {
                // Une icône du Dock glissée sur la corbeille est retirée du Dock
                let path = store.pins[index].path
                store.unpin(DockEntry(id: path, url: URL(fileURLWithPath: path), name: "", isPinned: true, isRunning: false, isFrontmost: false, isLaunching: false))
                store.draggingID = nil
                return true
            }
            loadURLs(providers) { urls in
                for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
            return true
        }
    }
}
