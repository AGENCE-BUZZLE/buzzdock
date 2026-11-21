import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// Demande d'ouverture des réglages (clic droit sur le Dock)
    static let buzzOpenSettings = Notification.Name("fr.buzzle.buzzdock.openSettings")
}

enum DockStyle: String, CaseIterable, Identifiable {
    case widgets
    case classic

    var id: String { rawValue }
    var label: String { self == .widgets ? "Widgets" : "Classique" }
}

enum DockMaterial: String, CaseIterable, Identifiable {
    case glass
    case tinted

    var id: String { rawValue }
    var label: String { self == .glass ? "Liquid Glass" : "Teinté" }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, nowPlaying, cpu, battery, aiUsage, network, month, apps, shortcuts, running, downloads, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: return "Horloge"
        case .nowPlaying: return "Morceau en cours"
        case .cpu: return "Processeur"
        case .battery: return "Batterie"
        case .network: return "Réseau"
        case .month: return "Jours du mois"
        case .apps: return "Dossiers d'apps"
        case .shortcuts: return "Raccourcis web"
        case .aiUsage: return "(retiré)"
        case .running: return "Apps du Dock (gardées et ouvertes)"
        case .downloads: return "Téléchargements"
        case .trash: return "Corbeille"
        }
    }

    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .nowPlaying: return "music.note"
        case .cpu: return "cpu"
        case .battery: return "battery.75percent"
        case .network: return "network"
        case .month: return "calendar"
        case .apps: return "square.grid.3x3"
        case .shortcuts: return "link"
        case .aiUsage: return "sparkle"
        case .running: return "app.badge"
        case .downloads: return "arrow.down.circle"
        case .trash: return "trash"
        }
    }
}

struct WidgetItem: Codable, Hashable, Identifiable {
    var kind: WidgetKind
    var enabled: Bool
    var id: String { kind.rawValue }

    static let defaults: [WidgetItem] = WidgetKind.allCases.map { WidgetItem(kind: $0, enabled: $0 != .trash) }
}

/// Couleur enregistrable (sRGB).
struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

/// Réglages persistés dans UserDefaults (fr.buzzle.buzzdock).
@MainActor
final class DockSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // Général
    @Published var style: DockStyle { didSet { defaults.set(style.rawValue, forKey: Keys.style) } }
    @Published var autoHide: Bool { didSet { defaults.set(autoHide, forKey: Keys.autoHide) } }
    @Published var hideSystemDock: Bool { didSet { defaults.set(hideSystemDock, forKey: Keys.hideSystemDock) } }

    // Mode classique
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: Keys.iconSize) } }
    /// 1.0 = pas d'agrandissement, 2.0 = icône doublée sous la souris
    @Published var magnification: Double { didSet { defaults.set(magnification, forKey: Keys.magnification) } }
    @Published var showRunningApps: Bool { didSet { defaults.set(showRunningApps, forKey: Keys.showRunningApps) } }
    @Published var showDownloads: Bool { didSet { defaults.set(showDownloads, forKey: Keys.showDownloads) } }
    @Published var showTrash: Bool { didSet { defaults.set(showTrash, forKey: Keys.showTrash) } }

    // Mode widgets
    @Published var widgets: [WidgetItem] { didSet { save(widgets, Keys.widgets) } }
    @Published var tileSize: Double { didSet { defaults.set(tileSize, forKey: Keys.tileSize) } }
    @Published var tileCorner: Double { didSet { defaults.set(tileCorner, forKey: Keys.tileCorner) } }
    @Published var tileOpacity: Double { didSet { defaults.set(tileOpacity, forKey: Keys.tileOpacity) } }
    @Published var barColorStart: RGBA { didSet { save(barColorStart, Keys.barColorStart) } }
    @Published var barColorEnd: RGBA { didSet { save(barColorEnd, Keys.barColorEnd) } }
    @Published var barOpacity: Double { didSet { defaults.set(barOpacity, forKey: Keys.barOpacity) } }
    @Published var clock24h: Bool { didSet { defaults.set(clock24h, forKey: Keys.clock24h) } }
    @Published var material: DockMaterial { didSet { defaults.set(material.rawValue, forKey: Keys.material) } }
    /// Teinte sombre ajoutée au verre (0 = verre clair)
    @Published var glassTint: Double { didSet { defaults.set(glassTint, forKey: Keys.glassTint) } }
    /// Les tuiles proches fusionnent comme des gouttes
    @Published var liquidMerge: Bool { didSet { defaults.set(liquidMerge, forKey: Keys.liquidMerge) } }

    static let defaultStart = RGBA(r: 0.17, g: 0.17, b: 0.18)
    static let defaultEnd = RGBA(r: 0.07, g: 0.29, b: 0.31)

    private enum Keys {
        static let style = "style"
        static let iconSize = "iconSize"
        static let magnification = "magnification"
        static let autoHide = "autoHide"
        static let hideSystemDock = "hideSystemDock"
        static let showRunningApps = "showRunningApps"
        static let showDownloads = "showDownloads"
        static let showTrash = "showTrash"
        static let widgets = "widgets.v1"
        static let tileSize = "tileSize"
        static let tileCorner = "tileCorner"
        static let tileOpacity = "tileOpacity"
        static let barColorStart = "barColorStart"
        static let barColorEnd = "barColorEnd"
        static let barOpacity = "barOpacity"
        static let clock24h = "clock24h"
        static let material = "material"
        static let glassTint = "glassTint"
        static let liquidMerge = "liquidMerge"
    }

    init() {
        defaults.register(defaults: [
            Keys.style: DockStyle.widgets.rawValue,
            Keys.iconSize: 52.0,
            Keys.magnification: 1.5,
            Keys.autoHide: true,
            Keys.hideSystemDock: true,
            Keys.showRunningApps: true,
            Keys.showDownloads: true,
            Keys.showTrash: true,
            Keys.tileSize: 64.0,
            Keys.tileCorner: 16.0,
            Keys.tileOpacity: 0.45,
            Keys.barOpacity: 0.88,
            Keys.clock24h: true,
            Keys.material: DockMaterial.glass.rawValue,
            Keys.glassTint: 0.15,
            Keys.liquidMerge: false,
        ])
        style = DockStyle(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .widgets
        iconSize = defaults.double(forKey: Keys.iconSize)
        magnification = defaults.double(forKey: Keys.magnification)
        autoHide = defaults.bool(forKey: Keys.autoHide)
        hideSystemDock = defaults.bool(forKey: Keys.hideSystemDock)
        showRunningApps = defaults.bool(forKey: Keys.showRunningApps)
        showDownloads = defaults.bool(forKey: Keys.showDownloads)
        showTrash = defaults.bool(forKey: Keys.showTrash)
        tileSize = defaults.double(forKey: Keys.tileSize)
        tileCorner = defaults.double(forKey: Keys.tileCorner)
        tileOpacity = defaults.double(forKey: Keys.tileOpacity)
        barOpacity = defaults.double(forKey: Keys.barOpacity)
        clock24h = defaults.bool(forKey: Keys.clock24h)
        material = DockMaterial(rawValue: defaults.string(forKey: Keys.material) ?? "") ?? .glass
        glassTint = defaults.double(forKey: Keys.glassTint)
        liquidMerge = defaults.bool(forKey: Keys.liquidMerge)
        barColorStart = Self.load(RGBA.self, Keys.barColorStart, from: defaults) ?? Self.defaultStart
        barColorEnd = Self.load(RGBA.self, Keys.barColorEnd, from: defaults) ?? Self.defaultEnd

        // Les widgets ajoutés dans une version plus récente apparaissent à la fin
        var saved = Self.load([WidgetItem].self, Keys.widgets, from: defaults) ?? WidgetItem.defaults
        // Raccourcis web (ajoutés le 16/11/2026) : visibles, juste après les dossiers
        if !saved.contains(where: { $0.kind == .shortcuts }) {
            let index = (saved.firstIndex { $0.kind == .apps }).map { $0 + 1 } ?? saved.count
            saved.insert(WidgetItem(kind: .shortcuts, enabled: true), at: index)
        }
        for kind in WidgetKind.allCases where !saved.contains(where: { $0.kind == kind }) {
            saved.append(WidgetItem(kind: kind, enabled: false))
        }
        widgets = saved
    }

    var enabledWidgets: [WidgetKind] { widgets.filter(\.enabled).map(\.kind) }

    func setWidget(_ kind: WidgetKind, enabled: Bool) {
        guard let index = widgets.firstIndex(where: { $0.kind == kind }) else { return }
        widgets[index].enabled = enabled
    }

    func resetToDefaults() {
        iconSize = 52
        magnification = 1.5
        autoHide = true
        showRunningApps = true
        showDownloads = true
        showTrash = true
        widgets = WidgetItem.defaults
        tileSize = 64
        tileCorner = 16
        tileOpacity = 0.45
        barOpacity = 0.88
        barColorStart = Self.defaultStart
        barColorEnd = Self.defaultEnd
        clock24h = true
        material = .glass
        glassTint = 0.15
        liquidMerge = false
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
