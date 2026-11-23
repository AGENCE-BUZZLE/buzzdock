import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

extension Notification.Name {
    static let buzzOpenLauncher = Notification.Name("fr.buzzle.buzzdock.openLauncher")
}

/// Hauteur réservée au dessus de la barre pour les étiquettes de survol.
let widgetLabelHeadroom: CGFloat = 70
/// Marge latérale de la fenêtre autour de la barre.
let widgetSideMargin: CGFloat = 14

// MARK: Barre

struct WidgetDockView: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore

    var body: some View {
        let k = settings.tileSize / 64
        VStack(spacing: 0) {
            Color.clear.frame(height: widgetLabelHeadroom)
            bar(
                HStack(alignment: .bottom, spacing: 8 * k) {
                    ForEach(settings.enabledWidgets) { kind in
                        widget(kind)
                            // les blocs qui portent des pastilles passent devant leurs voisins
                            .zIndex(kind == .apps || kind == .running ? 1 : 0)
                    }
                }
                .padding(8 * k),
                k: k
            )
        }
        // calque des pastilles de dossier : au-dessus du verre, à cheval sur le coin (comme sur iPhone)
        .overlayPreferenceValue(BadgeAnchorsKey.self) { anchors in
            GeometryReader { proxy in
                ForEach(anchors) { anchor in
                    let rect = proxy[anchor.bounds]
                    BadgeBubble(text: anchor.text, size: 54 * (settings.tileSize / 64))
                        .position(x: rect.maxX - 2, y: rect.minY + 2)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, widgetSideMargin)
        .padding(.bottom, 4)
        .fixedSize()
        .modifier(DockScheme())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(name: "dockRoot")
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.enabledWidgets)
    }

    /// Liquid Glass : les tuiles flottent dans un conteneur de verre (sans barre de fond).
    /// Teinté : barre en dégradé derrière les tuiles.
    @ViewBuilder
    private func bar<Row: View>(_ row: Row, k: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if settings.material == .glass {
                GlassEffectContainer(spacing: settings.liquidMerge ? 18 * k : 4 * k) { row }
            } else {
                row.background(WidgetBarBackground())
            }
        } else {
            row.background(WidgetBarBackground())
        }
        #else
        row.background(WidgetBarBackground())
        #endif
    }

    @ViewBuilder
    private func widget(_ kind: WidgetKind) -> some View {
        switch kind {
        case .clock:
            ClockWidget().widgetMenu(kind)
        case .nowPlaying:
            NowPlayingWidget().widgetMenu(kind)
        case .cpu:
            CPUWidget().widgetMenu(kind)
        case .battery:
            BatteryWidget().widgetMenu(kind)
        case .aiUsage:
            EmptyView()   // widget retiré (16/11/2026)
        case .network:
            NetworkWidget().widgetMenu(kind)
        case .month:
            MonthWidget().widgetMenu(kind)
        case .apps:
            ForEach(store.folders) { folder in
                FolderTile(folder: folder)
                    .zIndex(store.badge(for: folder) != nil ? 2 : 0)
            }
            if store.folders.isEmpty {
                NewFolderTile()
            }
        case .shortcuts:
            EmptyView()   // les raccourcis web vivent dans le bloc des apps
        case .running:
            RunningAppsGroup()
        case .downloads:
            // Téléchargements et Corbeille : un seul bloc, comme à droite du Dock d'Apple
            UtilitiesGroup(showDownloads: true, showTrash: settings.enabledWidgets.contains(.trash))
                .widgetMenu(kind)
        case .trash:
            if !settings.enabledWidgets.contains(.downloads) {
                UtilitiesGroup(showDownloads: false, showTrash: true).widgetMenu(kind)
            }
        }
    }
}

struct WidgetBarBackground: View {
    @EnvironmentObject private var settings: DockSettings

    var body: some View {
        let k = settings.tileSize / 64
        let radius = (settings.tileCorner + 8) * k
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            DockBackground(cornerRadius: radius)
            shape
                .fill(LinearGradient(
                    colors: [settings.barColorStart.color, settings.barColorEnd.color],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .opacity(settings.barOpacity)
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
        }
    }
}

// MARK: Briques communes

/// Une tuile sombre aux coins arrondis. `width` est exprimée pour une tuile de 64 pt de haut.
struct Tile<Content: View>: View {
    @EnvironmentObject private var settings: DockSettings
    let width: CGFloat
    /// Agrandissement réel (le verre, le contenu et les arrondis grandissent ensemble)
    var zoom: CGFloat = 1
    @ViewBuilder let content: () -> Content

    var body: some View {
        let k = settings.tileSize / 64 * zoom
        let shape = RoundedRectangle(cornerRadius: settings.tileCorner * k, style: .continuous)
        content()
            .frame(width: width * k, height: 64 * k)
            .clipShape(shape)
            .modifier(TileSurface(cornerRadius: settings.tileCorner * k))
            .contentShape(shape)
    }
}

/// Mode Teinté : fond sombre choisi, on force le thème sombre. Liquid Glass : on suit le système
/// (le verre prend la couleur du fond d'écran, le texte doit pouvoir passer en noir).
struct DockScheme: ViewModifier {
    @EnvironmentObject private var settings: DockSettings

    func body(content: Content) -> some View {
        if settings.material == .tinted {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

/// Fond d'une tuile : bulle de Liquid Glass (macOS 26) ou aplat sombre.
struct TileSurface: ViewModifier {
    @EnvironmentObject private var settings: DockSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        surface(content, shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0), lineWidth: 1))
    }

    @ViewBuilder
    private func surface(_ content: Content, _ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            // « Réduire la transparence » : fond opaque du système
            content.background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        } else {
            material(content, shape)
        }
    }

    @ViewBuilder
    private func material(_ content: Content, _ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if settings.material == .glass {
                content.glassEffect(
                    .regular.tint(Color.black.opacity(settings.glassTint)),
                    in: shape
                )
            } else {
                content.background(shape.fill(Color.black.opacity(settings.tileOpacity)))
            }
        } else {
            content.background(shape.fill(Color.black.opacity(settings.tileOpacity)))
        }
        #else
        content.background(shape.fill(Color.black.opacity(settings.tileOpacity)))
        #endif
    }
}

/// Survol calculé à partir de la position réelle de la souris (fournie par le contrôleur du Dock) :
/// il ne peut pas rester bloqué quand la souris quitte la barre.
struct HoverLabel: ViewModifier {
    @EnvironmentObject private var hover: HoverModel
    @EnvironmentObject private var settings: DockSettings
    let text: String
    var lift: Bool = false
    @State private var span: ClosedRange<CGFloat>?

    func body(content: Content) -> some View {
        let hovering: Bool = {
            guard let span, let x = hover.mouseX else { return false }
            return span.contains(x)
        }()
        return content
            // Le verre de macOS est dessiné à part et ne suit pas un zoom : soulèvement en mode Teinté seulement
            .scaleEffect(lift && hovering ? 1.15 : 1, anchor: .bottom)
            .background(
                GeometryReader { geo in
                    let frame = geo.frame(in: .named("dockRoot"))
                    Color.clear
                        .onAppear { span = frame.minX...frame.maxX }
                        .onChange(of: frame) { _, value in span = value.minX...value.maxX }
                }
            )
            .overlay(alignment: .top) {
                if hovering, !text.isEmpty {
                    DockLabel(text: text)
                        .offset(y: lift ? -40 : -34)
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovering)
    }
}

/// Effet loupe commun à TOUT le Dock (apps, dossiers, pile, Corbeille) : même courbe, même ressort.
/// Mesure l'emprise de l'élément au repos et donne au contenu son facteur d'agrandissement.
struct Loupe<Content: View>: View {
    @EnvironmentObject private var hover: HoverModel
    @EnvironmentObject private var settings: DockSettings
    let label: String
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var span: ClosedRange<CGFloat>?

    var body: some View {
        let k = settings.tileSize / 64
        let center = span.map { ($0.lowerBound + $0.upperBound) / 2 }
        let scale = center.map { WidgetLayout.loupeScale(center: $0, mouseX: hover.mouseX, k: k, magnification: settings.magnification) } ?? 1
        let hovered: Bool = {
            guard let span, let x = hover.mouseX else { return false }
            return span.contains(x)
        }()
        content(scale)
            .background(
                GeometryReader { geo in
                    let frame = geo.frame(in: .named("dockRoot"))
                    Color.clear
                        .onAppear { span = frame.minX...frame.maxX }
                        .onChange(of: frame) { _, value in
                            // emprise au repos seulement, pour que la loupe n'oscille pas
                            if hover.mouseX == nil { span = value.minX...value.maxX }
                        }
                }
            )
            .overlay(alignment: .top) {
                if hovered, !label.isEmpty {
                    DockLabel(text: label).offset(y: -34)
                }
            }
            .animation(WidgetLayout.loupeAnimation, value: hover.mouseX)
    }
}

/// Tuile avec son nom au survol. `zooms` : soumise à la loupe (le verre, le contenu et les arrondis
/// grandissent ensemble) ; sinon elle reste fixe (dossiers, Téléchargements).
struct ZoomingTile<Content: View>: View {
    @EnvironmentObject private var settings: DockSettings
    let label: String
    let width: CGFloat
    var zooms = true
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        if zooms {
            Loupe(label: label) { scale in
                Tile(width: width, zoom: scale) {
                    content(settings.tileSize / 64 * scale)
                }
            }
        } else {
            Tile(width: width) { content(settings.tileSize / 64) }
                .hoverLabel(label)
        }
    }
}

/// Emplacement d'une pastille à dessiner par-dessus tout le Dock (hors du verre, qui la recouvrirait)
struct BadgeAnchor: Identifiable {
    let id: String
    let text: String
    let bounds: Anchor<CGRect>
}

struct BadgeAnchorsKey: PreferenceKey {
    static let defaultValue: [BadgeAnchor] = []
    static func reduce(value: inout [BadgeAnchor], nextValue: () -> [BadgeAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// Retour d'appui immédiat (mouse-down) sans bloquer le clic, le glisser ni l'appui long.
struct PressFeedback: ViewModifier {
    @Binding var pressed: Bool

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

extension View {
    func pressFeedback(_ pressed: Binding<Bool>) -> some View { modifier(PressFeedback(pressed: pressed)) }

    /// L'élément s'enfonce et s'assombrit tant qu'on appuie
    func pressedLook(_ pressed: Bool, reduceMotion: Bool) -> some View {
        self.scaleEffect(pressed && !reduceMotion ? 0.94 : 1, anchor: .bottom)
            .brightness(pressed ? -0.2 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: pressed)
    }
}

/// Pastille rouge de notification, comme sur iPhone
struct BadgeBubble: View {
    let text: String
    let size: CGFloat   // taille de l'icône qui la porte

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.24, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, size * 0.09)
            .frame(minWidth: size * 0.36, minHeight: size * 0.36)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            .fixedSize()
            .allowsHitTesting(false)
            .transition(.scale.combined(with: .opacity))
    }
}

/// Étiquette du nom au survol, comme celle du Dock d'Apple.
struct DockLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .fixedSize()
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

struct WidgetMenu: ViewModifier {
    @EnvironmentObject private var settings: DockSettings
    let kind: WidgetKind

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Masquer « \(kind.title) »") { settings.setWidget(kind, enabled: false) }
            Divider()
            Button("Personnaliser le Dock…") {
                NotificationCenter.default.post(name: .buzzOpenSettings, object: nil)
            }
            Button("Quitter BuzzDock") { NSApp.terminate(nil) }
        }
    }
}

extension View {
    func hoverLabel(_ text: String, lift: Bool = false) -> some View { modifier(HoverLabel(text: text, lift: lift)) }
    func widgetMenu(_ kind: WidgetKind) -> some View { modifier(WidgetMenu(kind: kind)) }
}

private func openApp(bundleID: String) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

// MARK: Horloge

struct ClockWidget: View {
    @EnvironmentObject private var settings: DockSettings

    var body: some View {
        let k = settings.tileSize / 64
        TimelineView(.everyMinute) { context in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: context.date)
            let hour = parts.hour ?? 0
            let minute = parts.minute ?? 0
            let shownHour = settings.clock24h ? hour : (hour % 12 == 0 ? 12 : hour % 12)
            HStack(spacing: 6 * k) {
                FlipCard(text: String(format: "%02d", shownHour), badge: settings.clock24h ? nil : (hour < 12 ? "AM" : "PM"))
                FlipCard(text: String(format: "%02d", minute), badge: nil)
            }
        }
        .onTapGesture { openApp(bundleID: "com.apple.clock") }
        .hoverLabel("Horloge")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Horloge")
        .accessibilityValue(Date().formatted(date: .omitted, time: .shortened))
        .accessibilityAddTraits(.isButton)
    }
}

struct FlipCard: View {
    @EnvironmentObject private var settings: DockSettings
    let text: String
    let badge: String?

    var body: some View {
        let k = settings.tileSize / 64
        Tile(width: 64) {
            ZStack(alignment: .topLeading) {
                Text(text)
                    .font(.system(size: 36 * k, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentTransition(.numericText())
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(height: 1.5 * k)
                    .frame(maxHeight: .infinity)
                if let badge {
                    Text(badge)
                        .font(.system(size: max(10, 8 * k), weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(5 * k)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: text)
    }
}

// MARK: Morceau en cours

struct NowPlayingWidget: View {
    @EnvironmentObject private var settings: DockSettings
    @ObservedObject private var player = NowPlaying.shared

    var body: some View {
        let k = settings.tileSize / 64
        Tile(width: 220) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1 * k) {
                    Text(player.track?.title ?? "Rien en lecture")
                        .font(.system(size: 14 * k, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(player.track?.artist ?? "Spotify ou Musique")
                        .font(.system(size: 13 * k, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = player.elapsed(at: context.date)
                        let duration = max(player.track?.duration ?? 0, 1)
                        VStack(spacing: 3 * k) {
                            HStack {
                                Text(Self.format(elapsed))
                                Spacer()
                                Text(Self.format(player.track?.duration ?? 0))
                            }
                            .font(.system(size: max(10, 9.5 * k), weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.18))
                                    Capsule().fill(Color.white)
                                        .frame(width: geo.size.width * CGFloat(min(elapsed / duration, 1)))
                                }
                            }
                            .frame(height: 3 * k)
                        }
                    }
                }
                .padding(.leading, 12 * k)
                .padding(.trailing, 6 * k)
                .padding(.vertical, 9 * k)
                .frame(maxWidth: .infinity, alignment: .leading)

                VinylDisc(artwork: player.artwork, isPlaying: player.track?.isPlaying == true, size: 74 * k)
                    .frame(width: 62 * k)
                    .offset(x: 16 * k)
            }
        }
        .onTapGesture { player.playPause() }
        .contextMenu {
            Button("Lecture / Pause") { player.playPause() }
            Button("Morceau suivant") { player.next() }
            Button("Morceau précédent") { player.previous() }
            Divider()
            Button("Masquer « Morceau en cours »") { settings.setWidget(.nowPlaying, enabled: false) }
            Button("Personnaliser le Dock…") { NotificationCenter.default.post(name: .buzzOpenSettings, object: nil) }
        }
        .hoverLabel(player.track?.player ?? "Morceau en cours")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Morceau en cours")
        .accessibilityValue(player.track.map { "\($0.title), \($0.artist)" } ?? "rien en lecture")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Lecture ou pause") { player.playPause() }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct VinylDisc: View {
    let artwork: NSImage?
    let isPlaying: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying || reduceMotion)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 9) * 40
            ZStack {
                Circle().fill(Color(white: 0.9))
                ForEach(0..<5, id: \.self) { ring in
                    Circle()
                        .stroke(Color(white: 0.78), lineWidth: 0.6)
                        .padding(size * (0.05 + CGFloat(ring) * 0.055))
                }
                Group {
                    if let artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: size * 0.42, height: size * 0.42)
                .clipShape(Circle())
                Circle().fill(Color(white: 0.15)).frame(width: size * 0.05, height: size * 0.05)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
        }
    }
}

// MARK: Jauges

struct GaugeTile: View {
    @EnvironmentObject private var settings: DockSettings
    let value: Double
    let color: Color
    let symbol: String

    var body: some View {
        let k = settings.tileSize / 64
        Tile(width: 64) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5 * k)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0.001), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 5 * k, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1 * k) {
                    Image(systemName: symbol)
                        .font(.system(size: max(10, 10 * k), weight: .semibold))
                        .foregroundStyle(color)
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 13.5 * k, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .padding(7 * k)
            .animation(.easeOut(duration: 0.6), value: value)
        }
    }
}

struct CPUWidget: View {
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        GaugeTile(value: stats.cpu, color: Color(nsColor: .systemCyan), symbol: "cpu")
            .onTapGesture { openApp(bundleID: "com.apple.ActivityMonitor") }
            .hoverLabel("Processeur")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Processeur")
            .accessibilityValue("\(Int((stats.cpu * 100).rounded())) %")
            .accessibilityAddTraits(.isButton)
    }
}

struct BatteryWidget: View {
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        if let battery = stats.battery {
            GaugeTile(
                value: battery,
                color: battery < 0.2 ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange),
                symbol: stats.charging ? "battery.100percent.bolt"
                    : battery < 0.13 ? "battery.0percent" : battery < 0.38 ? "battery.25percent"
                    : battery < 0.63 ? "battery.50percent" : battery < 0.88 ? "battery.75percent" : "battery.100percent"
            )
            .onTapGesture {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .hoverLabel(stats.charging ? "Batterie · en charge" : "Batterie")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Batterie")
            .accessibilityValue("\(Int((battery * 100).rounded())) %" + (stats.charging ? ", en charge" : ""))
            .accessibilityAddTraits(.isButton)
        }
    }
}

struct NetworkWidget: View {
    @EnvironmentObject private var settings: DockSettings
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        let k = settings.tileSize / 64
        Tile(width: 104) {
            VStack(alignment: .leading, spacing: 4 * k) {
                Image(systemName: "globe")
                    .font(.system(size: 13 * k, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemTeal))
                    .frame(maxWidth: .infinity)
                Label(SystemStats.formatSpeed(stats.downBytesPerSecond), systemImage: "arrow.down")
                Label(SystemStats.formatSpeed(stats.upBytesPerSecond), systemImage: "arrow.up")
            }
            .labelStyle(CompactLabelStyle(spacing: 3 * k))
            .font(.system(size: max(10, 10.5 * k), weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
        }
        .onTapGesture { openApp(bundleID: "com.apple.ActivityMonitor") }
        .hoverLabel("Réseau")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Réseau")
        .accessibilityValue("réception \(SystemStats.formatSpeed(stats.downBytesPerSecond)), envoi \(SystemStats.formatSpeed(stats.upBytesPerSecond))")
    }
}

struct CompactLabelStyle: LabelStyle {
    let spacing: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.foregroundStyle(Color(nsColor: .systemTeal))
            configuration.title
        }
    }
}

// MARK: Jours du mois

struct MonthWidget: View {
    @EnvironmentObject private var settings: DockSettings

    var body: some View {
        let k = settings.tileSize / 64
        Tile(width: 190) {
            TimelineView(.everyMinute) { context in
                let calendar = Calendar.current
                let day = calendar.component(.day, from: context.date)
                let days = calendar.range(of: .day, in: .month, for: context.date)?.count ?? 30
                VStack(alignment: .leading, spacing: 5 * k) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(9 * k), spacing: 4.5 * k), count: 11),
                        alignment: .leading,
                        spacing: 3.5 * k
                    ) {
                        ForEach(0..<days, id: \.self) { index in
                            Circle()
                                .fill(index < day - 1 ? Color.white.opacity(0.2) : Color.white)
                                .frame(width: 9 * k, height: 9 * k)
                        }
                    }
                    HStack {
                        Text(context.date.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                        Spacer()
                        Text(days - day == 1 ? "1 jour restant" : "\(days - day) j restants")
                    }
                    .font(.system(size: max(10, 9.5 * k), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12 * k)
                .padding(.vertical, 7 * k)
            }
        }
        .onTapGesture { openApp(bundleID: "com.apple.iCal") }
        .hoverLabel("Calendrier")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jours du mois")
        .accessibilityValue(Date().formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Dossiers d'apps (façon iPhone)

struct FolderTile: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    let folder: AppFolder
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Le dossier ouvert, dans la fenêtre placée au-dessus du Dock
    private func openFolder() {
        store.isInteracting = true
        let store = self.store
        let settings = self.settings
        let id = folder.id
        DockPopup.shared.toggle(id: id.uuidString, anchorX: NSEvent.mouseLocation.x,
                                onClose: { store.isInteracting = false }) {
            FolderPopover(folderID: id, onClose: { DockPopup.shared.close() })
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
    @State private var isTargeted = false

    var body: some View {
        let k = settings.tileSize / 64
        let apps = store.apps(in: folder)
        let links = Array(folder.links.prefix(max(0, 9 - apps.count)))
        ZoomingTile(label: folder.name, width: 64, zooms: false) { k in
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(15 * k), spacing: 3.5 * k), count: 3), spacing: 3.5 * k) {
                ForEach(apps.prefix(9), id: \.self) { url in
                    Image(nsImage: IconCache.icon(for: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15 * k, height: 15 * k)
                }
                ForEach(links) { link in
                    WebLinkIcon(link: link, size: 16.5 * k)
                        .frame(width: 15 * k, height: 15 * k)
                }
            }
            // grille 3 × 3 fixe, remplie depuis le haut à gauche (comme les dossiers iPhone)
            .frame(width: 15 * 3 * k + 3.5 * 2 * k, height: 15 * 3 * k + 3.5 * 2 * k, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: settings.tileCorner * k, style: .continuous)
                .strokeBorder(Color.white.opacity(isTargeted ? 0.8 : 0), lineWidth: 2)
        )
        // pastille : dessinée dans le calque au-dessus de tout le Dock (voir BadgeLayer)
        .anchorPreference(key: BadgeAnchorsKey.self, value: .bounds) { bounds in
            store.badge(for: folder).map { [BadgeAnchor(id: folder.id.uuidString, text: $0, bounds: bounds)] } ?? []
        }
        .animation(.spring(response: 0.25), value: isTargeted)
        .pressedLook(pressed, reduceMotion: reduceMotion)
        .onTapGesture { openFolder() }
        .pressFeedback($pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dossier \(folder.name)")
        .accessibilityValue("\(folder.paths.count + folder.links.count) éléments"
            + (store.badge(for: folder).map { ", \($0) notifications" } ?? ""))
        .accessibilityAddTraits(.isButton)
        .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $isTargeted) { providers in
            if store.dropDragged(into: folder.id) { return true }
            loadURLs(providers) { urls in
                for url in urls {
                    if url.isFileURL {
                        store.add(url, to: folder.id)
                    } else {
                        // adresse glissée depuis le navigateur : nouveau raccourci web
                        store.addLink(WebLink(name: WebLink.guessName(for: url), url: url.absoluteString), to: folder.id)
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button("Ouvrir « \(folder.name) »") { openFolder() }
            Button("Nouveau dossier") { store.createFolder() }
            Divider()
            Button("Personnaliser le Dock…") { NotificationCenter.default.post(name: .buzzOpenSettings, object: nil) }
            Button("Quitter BuzzDock") { NSApp.terminate(nil) }
            Divider()
            Button("Supprimer le dossier…", role: .destructive) { confirmDelete() }
        }
    }

    private func confirmDelete() {
        guard !(folder.paths.isEmpty && folder.links.isEmpty) else {
            store.deleteFolder(folder.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Supprimer le dossier « \(folder.name) » ?"
        alert.informativeText = "Les apps ne sont pas supprimées, seulement le dossier."
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.deleteFolder(folder.id) }
    }
}

struct NewFolderTile: View {
    @EnvironmentObject private var store: DockStore
    @EnvironmentObject private var settings: DockSettings

    var body: some View {
        let k = settings.tileSize / 64
        Tile(width: 64) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 20 * k, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onTapGesture { store.createFolder() }
        .hoverLabel("Nouveau dossier")
    }
}

/// Le dossier ouvert : nom modifiable, grille d'apps, ajout d'apps.
struct FolderPopover: View {
    @EnvironmentObject private var store: DockStore
    let folderID: UUID
    let onClose: () -> Void
    @State private var adding = false
    @State private var addingLink = false
    @State private var customLink = false
    @State private var query = ""
    @State private var catalog: [AppInfo] = []

    private var folder: AppFolder? { store.folders.first { $0.id == folderID } }

    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private enum Mode { case grid, apps, webApps, customLink }
    private var mode: Mode {
        if addingLink { return customLink ? .customLink : .webApps }
        return adding ? .apps : .grid
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            switch mode {
            case .grid: grid
            case .apps: picker
            case .webApps:
                WebAppGallery(
                    onPick: { link in store.addLink(link, to: folderID) },
                    onCustom: { customLink = true }
                )
            case .customLink:
                WebLinkForm(
                    onAdd: { link in
                        store.addLink(link, to: folderID)
                        addingLink = false
                        customLink = false
                    },
                    onCancel: { customLink = false }
                )
            }
        }
        .padding(18)
        .frame(width: 400)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: mode)
    }

    /// En-tête façon iOS : nom du dossier au centre (clic pour renommer), bouton rond à droite.
    private var header: some View {
        ZStack {
            if renaming {
                TextField("Nom du dossier", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
                    .padding(.horizontal, 40)
            } else {
                Text(folder?.name ?? "")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 40)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draftName = folder?.name ?? ""
                        renaming = true
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .help("Clic pour renommer")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Renommer le dossier")
            }
            HStack {
                if mode != .grid {
                    // retour à la grille
                    Button {
                        if mode == .customLink { customLink = false } else { adding = false; addingLink = false }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retour")
                }
                Spacer()
                if mode == .grid {
                    Menu {
                        Button {
                            adding = true
                            if catalog.isEmpty { catalog = AppCatalog.scan() }
                        } label: { Label("Ajouter des apps", systemImage: "square.grid.2x2") }
                        Button { addingLink = true } label: { Label("Ajouter une app web", systemImage: "globe") }
                        Divider()
                        Button { startRename() } label: { Label("Renommer", systemImage: "pencil") }
                        Button {
                            onClose()
                            NotificationCenter.default.post(name: .buzzOpenLauncher, object: nil)
                        } label: { Label("Toutes les apps", systemImage: "square.grid.3x3") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.quaternary, in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Ajouter")
                } else {
                    Button("OK") { adding = false; addingLink = false; customLink = false }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .frame(height: 30)
    }

    private func startRename() {
        draftName = folder?.name ?? ""
        renaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard renaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { store.renameFolder(folderID, to: name) }
        renaming = false
    }

    private var grid: some View {
        let apps = folder.map { store.apps(in: $0) } ?? []
        let links = folder?.links ?? []
        return Group {
            if apps.isEmpty && links.isEmpty {
                Text("Dossier vide\nAjoute des apps avec + ou glisse-les sur le dossier.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: 8), count: 4), spacing: 14) {
                    ForEach(apps, id: \.self) { url in
                        let entry = store.entry(for: url)
                        VStack(spacing: 4) {
                            Image(nsImage: IconCache.icon(for: url.path))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 54, height: 54)
                                .overlay(alignment: .topTrailing) {
                                    if let badge = store.badges[entry.id] { BadgeBubble(text: badge, size: 54).offset(x: 4, y: -2) }
                                }
                            Text(entry.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Circle()
                                .fill(Color.primary.opacity(entry.isRunning ? 0.7 : 0))
                                .frame(width: 4, height: 4)
                        }
                        .frame(width: 80)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.open(entry)
                            onClose()
                        }
                        .onDrag {
                            store.draggingID = DockStore.key(url)
                            store.dragSourceFolder = folderID
                            return NSItemProvider(object: url as NSURL)
                        }
                        .contextMenu {
                            Button(store.isOnBar(url) ? "Retirer du Dock" : "Garder dans le Dock") {
                                store.isOnBar(url) ? store.removeFromBar(DockStore.key(url)) : store.keepOnBar(url)
                            }
                            Button("Retirer du dossier") { store.remove(url, from: folderID) }
                            Menu("Déplacer vers") {
                                ForEach(store.folders.filter { $0.id != folderID }) { other in
                                    Button(other.name) { store.move(url, from: folderID, to: other.id) }
                                }
                            }
                            Button("Afficher dans le Finder") { store.revealInFinder(entry) }
                        }
                    }
                    ForEach(links) { link in
                        VStack(spacing: 4) {
                            WebLinkIcon(link: link, size: 60)
                                .frame(width: 54, height: 54)
                            Text(link.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Circle().fill(Color.clear).frame(width: 4, height: 4)
                        }
                        .frame(width: 80)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.openLink(link)
                            onClose()
                        }
                        .onDrag {
                            store.draggingID = "link:\(link.id.uuidString)"
                            store.dragSourceFolder = folderID
                            return NSItemProvider(object: (link.resolvedURL ?? URL(string: "https://example.com")!) as NSURL)
                        }
                        .contextMenu { WebLinkMenu(link: link) }
                    }
                }
            }
        }
    }

    private var picker: some View {
        let filtered = query.isEmpty ? catalog : catalog.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return VStack(spacing: 8) {
            TextField("Rechercher une app", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { app in
                        let inFolder = store.contains(app.url, in: folderID)
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.icon(for: app.url.path))
                                .resizable()
                                .frame(width: 22, height: 22)
                            Text(app.name)
                            Spacer()
                            Image(systemName: inFolder ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(inFolder ? Color.accentColor : .secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if inFolder { store.remove(app.url, from: folderID) } else { store.add(app.url, to: folderID) }
                        }
                    }
                }
            }
            .frame(height: 300)
        }
    }
}

// MARK: Bloc des apps (apps gardées, raccourcis web, apps ouvertes)

/// Le bloc des apps, avec l'effet loupe du Dock d'Apple : l'élément sous la souris grossit,
/// ses voisins un peu moins ; les icônes prennent vraiment la place, la barre s'élargit depuis son centre.
/// Apps et raccourcis web y sont traités pareil (réorganiser, ranger dans un dossier, retirer).
struct RunningAppsGroup: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    @EnvironmentObject private var hover: HoverModel
    /// Bord gauche du groupe AU REPOS (mesuré seulement quand la souris n'est pas sur le Dock)
    @State private var restingMinX: CGFloat = 0

    var body: some View {
        let k = settings.tileSize / 64
        let width = WidgetLayout.iconWidth * k
        let gap = WidgetLayout.iconGap * k
        let pad = WidgetLayout.groupPadding * k
        let slots = store.barSlots
        let centers = slots.indices.map { restingMinX + pad + CGFloat($0) * (width + gap) + width / 2 }
        let scales = centers.map {
            WidgetLayout.loupeScale(center: $0, mouseX: hover.mouseX, k: k, magnification: settings.magnification)
        }
        let hovered = hover.mouseX.flatMap { x in centers.firstIndex { abs($0 - x) <= (width + gap) / 2 } }
        let _ = DockHitRegistry.shared.update(centers: centers.map { CGFloat($0) }, slots: slots, halfWidth: CGFloat((width + gap) / 2))

        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                Group {
                    switch slot {
                    case .app(let entry):
                        RunningAppIcon(entry: entry, scale: scales[index], showLabel: hovered == index)
                    case .link(let link):
                        BarLinkIcon(link: link, scale: scales[index], showLabel: hovered == index)
                    }
                }
                .opacity(store.draggingID == slot.id ? 0.35 : 1)
                // une icône avec pastille passe devant sa voisine de droite (sinon la pastille est cachée)
                .zIndex(store.badges[slot.id] != nil ? 2 : Double(scales[index]))
                .onDrop(of: [UTType.fileURL, UTType.url], delegate: BarDropDelegate(slot: slot, store: store))
                .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, pad)
        .frame(height: 64 * k, alignment: .bottom)
        .background(
            GeometryReader { geo in
                let minX = geo.frame(in: .named("dockRoot")).minX
                Color.clear
                    .onAppear { restingMinX = minX }
                    .onChange(of: minX) { _, value in
                        if hover.mouseX == nil { restingMinX = value }
                    }
            }
        )
        .modifier(TileSurface(cornerRadius: settings.tileCorner * k))
        // Dépôt dans le bloc, hors d'une icône : à la fin de la barre
        .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: nil) { providers in
            if store.dropDraggedOnBar(at: nil) { return true }
            loadURLs(providers) { urls in store.dropExternal(urls, at: nil) }
            return true
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: slots.map(\.id))
        .animation(WidgetLayout.loupeAnimation, value: hover.mouseX)
    }
}

/// Glisser-déposer sur un élément du bloc des apps.
struct BarDropDelegate: DropDelegate {
    let slot: BarSlot
    let store: DockStore

    func dropEntered(info: DropInfo) {
        Task { @MainActor in
            // réorganisation en direct entre éléments gardés
            guard let dragging = store.draggingID, dragging != slot.id,
                  store.dragSourceFolder == nil,
                  store.barIndex(of: dragging) != nil, store.barIndex(of: slot.id) != nil else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                store.moveBarItem(dragging, to: slot.id)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL, UTType.url])
        Task { @MainActor in
            let index = store.barIndex(of: slot.id)
            if let dragging = store.draggingID {
                if store.barIndex(of: dragging) != nil && store.dragSourceFolder == nil {
                    store.draggingID = nil   // déjà réorganisé pendant le glisser
                } else {
                    _ = store.dropDraggedOnBar(at: index)
                }
                return
            }
            loadURLs(providers) { urls in
                // des documents déposés sur une app s'ouvrent avec elle
                if case .app(let entry) = slot {
                    let files = urls.filter { $0.isFileURL && $0.pathExtension != "app" }
                    if !files.isEmpty { store.open(files: files, with: entry) }
                }
                store.dropExternal(urls.filter { !$0.isFileURL || $0.pathExtension == "app" }, at: index)
            }
        }
        return true
    }
}

/// Un raccourci web dans le bloc des apps : même taille, même loupe, même comportement qu'une app.
struct BarLinkIcon: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    let link: WebLink
    var scale: CGFloat = 1
    var showLabel = false
    @State private var pressed = false

    var body: some View {
        let k = settings.tileSize / 64
        let size = WidgetLayout.iconWidth * k
        VStack(spacing: 3 * k) {
            WebLinkIcon(link: link, size: size * scale)
                .scaleEffect(pressed ? 0.92 : 1, anchor: .bottom)
                .brightness(pressed ? -0.25 : 0)
                .animation(.spring(response: 0.18, dampingFraction: 1), value: pressed)
            Capsule().fill(Color.clear).frame(width: 5 * k, height: 3 * k)
        }
        .frame(height: 64 * k, alignment: .bottom)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if showLabel {
                DockLabel(text: link.name).offset(y: -30 - size * (scale - 1))
            }
        }
        .onTapGesture { store.openLink(link) }
        .pressFeedback($pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.name)
        .accessibilityAddTraits(.isButton)
        .onDrag {
            store.draggingID = "link:\(link.id.uuidString)"
            return NSItemProvider(object: (link.resolvedURL ?? URL(string: "https://example.com")!) as NSURL)
        }
        .contextMenu {
            WebLinkMenu(link: link)
            Button("Retirer du Dock") { store.removeLink(link.id) }
        }
    }
}

/// Taille du Dock à widgets calculée à l'avance : la fenêtre ne change jamais de taille au survol.
@MainActor
enum WidgetLayout {
    static let iconWidth: CGFloat = 54
    static let iconGap: CGFloat = 6
    static let groupPadding: CGFloat = 6

    /// Largeur d'un widget, pour une tuile de 64 pt de haut (nil = n'affiche rien).
    static func width(of kind: WidgetKind, store: DockStore, settings: DockSettings) -> [CGFloat] {
        switch kind {
        case .clock: return [134]
        case .nowPlaying: return [220]
        case .cpu: return [64]
        case .battery: return SystemStats.shared.battery == nil ? [] : [64]
        case .aiUsage: return []
        case .network: return [104]
        case .month: return [190]
        case .apps: return Array(repeating: 64, count: max(store.folders.count, 1))
        case .shortcuts: return []   // fusionné dans le bloc des apps
        case .running:
            let n = CGFloat(store.barSlots.count)
            return [n * iconWidth + max(n - 1, 0) * iconGap + groupPadding * 2]
        case .downloads:
            let n: CGFloat = settings.enabledWidgets.contains(.trash) ? 2 : 1
            return [n * iconWidth + (n - 1) * iconGap + groupPadding * 2]
        case .trash:
            return settings.enabledWidgets.contains(.downloads) ? [] : [iconWidth + groupPadding * 2]
        }
    }

    /// Taille de la barre au repos, marges et place des étiquettes comprises.
    static func restingSize(settings: DockSettings, store: DockStore) -> CGSize {
        let k = settings.tileSize / 64
        let children = settings.enabledWidgets.flatMap { width(of: $0, store: store, settings: settings) }
        let content = children.reduce(0, +) * k + 8 * k * CGFloat(max(children.count - 1, 0)) + 16 * k
        let height = widgetLabelHeadroom + 64 * k + 16 * k + 4
        return CGSize(width: ceil(content + widgetSideMargin * 2), height: ceil(height))
    }

    static let loupeAnimation = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.9)

    /// Courbe de la loupe (en cloche, comme le Dock d'Apple), identique pour tous les éléments.
    static func loupeScale(center: CGFloat, mouseX: CGFloat?, k: CGFloat, magnification: Double) -> CGFloat {
        guard let mouseX, magnification > 1.001 else { return 1 }
        let reach = iconWidth * k * 2.6
        let distance = abs(mouseX - center)
        guard distance < reach else { return 1 }
        let t = cos((distance / reach) * .pi / 2)
        return 1 + CGFloat(magnification - 1) * t * t
    }

    /// Place gagnée par la loupe (la fenêtre la réserve d'avance).
    static func magnificationGrowth(settings: DockSettings) -> (width: CGFloat, rise: CGFloat) {
        let k = settings.tileSize / 64
        let extra = CGFloat(max(settings.magnification - 1, 0))
        return (64 * k * extra * 2.6 + 8, 64 * k * extra)
    }
}

struct RunningAppIcon: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    let entry: DockEntry
    var scale: CGFloat = 1
    var showLabel = false
    @State private var isTargeted = false
    @State private var bouncing = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let k = settings.tileSize / 64
        let size = 54 * k
        VStack(spacing: 3 * k) {
            Image(nsImage: IconCache.icon(for: entry.id))
                .resizable()
                .interpolation(.high)
                .frame(width: size * scale, height: size * scale)
                .overlay(alignment: .topTrailing) {
                    if let badge = store.badges[entry.id] {
                        BadgeBubble(text: badge, size: size * scale)
                            .offset(x: size * scale * 0.04, y: size * scale * 0.02)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: store.badges[entry.id])
                .scaleEffect(isTargeted ? 1.1 : (pressed && !reduceMotion ? 0.92 : 1), anchor: .bottom)
                .brightness(pressed ? -0.25 : 0)
                .animation(.spring(response: 0.18, dampingFraction: 1), value: pressed)
                .offset(y: bouncing ? -20 * k : 0)
                .opacity(entry.isRunning ? 1 : 0.85)
            Capsule()
                .fill(Color.primary.opacity(entry.isRunning ? (entry.isFrontmost ? 0.9 : 0.45) : 0))
                .frame(width: (entry.isFrontmost ? 12 : 5) * k, height: 3 * k)
        }
        .frame(height: 64 * k, alignment: .bottom)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if showLabel {
                DockLabel(text: entry.name)
                    .offset(y: -30 - size * (scale - 1) - (bouncing ? 20 * k : 0))
            }
        }
        .animation(.spring(response: 0.25), value: isTargeted)
        .onAppear { if entry.isLaunching { startBounce() } }
        .onChange(of: store.attention[entry.id]) { _, date in
            if date != nil { attentionBounce() }
        }
        .onChange(of: entry.isLaunching) { _, launching in
            launching ? startBounce() : stopBounce()
        }
        .onTapGesture { store.open(entry) }
        .onDrag {
            store.draggingID = entry.id
            return NSItemProvider(object: entry.url as NSURL)
        }
        // Appui long : aperçus des fenêtres (le clic droit garde le menu complet, via le contrôleur)
        // l'icône s'enfonce dès l'appui (mouse-down) et remonte au relâchement, comme le Dock d'Apple
        .onLongPressGesture(minimumDuration: 0.45, perform: {
            WindowPreviewController.shared.show(for: entry, store: store)
        }, onPressingChanged: { pressed = $0 })
        // VoiceOver
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue([entry.isRunning ? "ouverte" : nil, store.badges[entry.id].map { "\($0) notifications" }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Afficher les fenêtres") { WindowPreviewController.shared.show(for: entry, store: store) }
        .accessibilityAction(named: "Menu") { DockMenu.show(for: entry, store: store) }
    }
    /// Nouvelle notification : deux grands rebonds, comme le Dock d'Apple
    private func attentionBounce(_ remaining: Int = 2) {
        guard remaining > 0, !reduceMotion else { return }   // « Réduire les animations » : la pastille suffit
        withAnimation(.easeOut(duration: 0.28)) { bouncing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeIn(duration: 0.28)) { bouncing = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { attentionBounce(remaining - 1) }
        }
    }

    /// Rebond de lancement, tant que l'app démarre (comme le Dock d'Apple).
    private func startBounce() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.3).repeatForever(autoreverses: true)) { bouncing = true }
    }

    private func stopBounce() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { bouncing = false }
    }
}

// MARK: Téléchargements et Corbeille (un seul bloc)

struct UtilitiesGroup: View {
    @EnvironmentObject private var settings: DockSettings
    let showDownloads: Bool
    let showTrash: Bool

    var body: some View {
        let k = settings.tileSize / 64
        HStack(alignment: .bottom, spacing: WidgetLayout.iconGap * k) {
            if showDownloads { DownloadsIcon() }
            if showTrash { TrashIcon() }
        }
        .padding(.horizontal, WidgetLayout.groupPadding * k)
        .frame(height: 64 * k, alignment: .bottom)
        .modifier(TileSurface(cornerRadius: settings.tileCorner * k))
    }
}

/// Le dossier Téléchargements, avec l'icône native de macOS
struct DownloadsIcon: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var body: some View {
        let k = settings.tileSize / 64
        VStack(spacing: 3 * k) {
            Image(nsImage: IconCache.icon(for: folder.path))
                .resizable()
                .interpolation(.high)
                .frame(width: WidgetLayout.iconWidth * k, height: WidgetLayout.iconWidth * k)
                .scaleEffect(isTargeted ? 1.08 : 1, anchor: .bottom)
            Capsule().fill(Color.clear).frame(width: 5 * k, height: 3 * k)
        }
        .frame(height: 64 * k, alignment: .bottom)
        .contentShape(Rectangle())
        .hoverLabel("Téléchargements")
        .animation(.spring(response: 0.25), value: isTargeted)
        .pressedLook(pressed, reduceMotion: reduceMotion)
        .pressFeedback($pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Téléchargements")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            store.isInteracting = true
            let store = self.store
            let folder = self.folder
            DockPopup.shared.toggle(id: "telechargements", anchorX: NSEvent.mouseLocation.x,
                                    onClose: { store.isInteracting = false }) {
                DownloadsGrid(folder: folder) { DockPopup.shared.close() }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadURLs(providers) { urls in
                for url in urls {
                    try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
                }
            }
            return true
        }
    }
}

/// Surveille si la Corbeille contient quelque chose (icône pleine ou vide)
@MainActor
final class TrashMonitor: ObservableObject {
    static let shared = TrashMonitor()
    @Published private(set) var isFull = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "fr.buzzle.buzzdock.trash", qos: .utility)

    private init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        queue.async {
            let full = Self.trashHasItems()
            DispatchQueue.main.async {
                if TrashMonitor.shared.isFull != full { TrashMonitor.shared.isFull = full }
            }
        }
    }

    nonisolated private static func trashHasItems() -> Bool {
        let fm = FileManager.default
        if let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           let items = try? fm.contentsOfDirectory(atPath: trash.path) {
            return items.contains { $0 != ".DS_Store" && $0 != ".localized" }
        }
        // dossier protégé : on demande au Finder (autorisation d'automatisation, une fois)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to count items of trash"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return (Int(text) ?? 0) > 0
    }
}

struct TrashIcon: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var trash = TrashMonitor.shared
    @State private var isTargeted = false

    var body: some View {
        let k = settings.tileSize / 64
        let image = IconCache.named(trash.isFull ? NSImage.trashFullName : NSImage.trashEmptyName)
        VStack(spacing: 3 * k) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: WidgetLayout.iconWidth * k, height: WidgetLayout.iconWidth * k)
                .scaleEffect(isTargeted ? 1.08 : 1, anchor: .bottom)
            Capsule().fill(Color.clear).frame(width: 5 * k, height: 3 * k)
        }
        .frame(height: 64 * k, alignment: .bottom)
        .contentShape(Rectangle())
        .hoverLabel("Corbeille")
        .animation(.spring(response: 0.25), value: isTargeted)
        .pressedLook(pressed, reduceMotion: reduceMotion)
        .pressFeedback($pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trash.isFull ? "Corbeille, contient des éléments" : "Corbeille, vide")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            let url = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            NSWorkspace.shared.open(url)
        }
        .contextMenu {
            Button("Ouvrir") {
                let url = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                NSWorkspace.shared.open(url)
            }
            Divider()
            Button("Personnaliser le Dock…") { NotificationCenter.default.post(name: .buzzOpenSettings, object: nil) }
            Button("Vider la Corbeille…") {
                let alert = NSAlert()
                alert.messageText = "Supprimer définitivement les éléments de la Corbeille ?"
                alert.informativeText = "Cette action est irréversible."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Vider la Corbeille")
                alert.addButton(withTitle: "Annuler")
                alert.buttons.first?.hasDestructiveAction = true
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
                try? process.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { trash.check() }
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $isTargeted) { providers in
            // un élément du Dock glissé sur la Corbeille est retiré du Dock (ou de son dossier)
            if store.dropDraggedOnTrash() { return true }
            loadURLs(providers) { urls in
                for url in urls where url.isFileURL { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                trash.check()
            }
            return true
        }
    }
}
