import CoreGraphics
import Foundation

/// Géométrie du Dock : tailles de base, effet loupe, taille de la fenêtre.
struct DockMetrics {
    let slots: [DockSlot]
    let base: CGFloat
    let magnification: CGFloat

    var spacing: CGFloat { (base * 0.16).rounded() }
    var padding: CGFloat { (base * 0.22).rounded() }
    var separatorWidth: CGFloat { 1 }
    var indicatorHeight: CGFloat { 6 }
    var bottomGap: CGFloat { 4 }
    var labelHeadroom: CGFloat { 36 }
    var cornerRadius: CGFloat { base * 0.42 }

    @MainActor
    init(slots: [DockSlot], settings: DockSettings) {
        self.slots = slots
        self.base = CGFloat(settings.iconSize)
        self.magnification = CGFloat(max(1, settings.magnification))
    }

    func baseWidth(of slot: DockSlot) -> CGFloat {
        if case .separator = slot { return separatorWidth }
        return base
    }

    /// Largeur de la barre au repos
    var barWidth: CGFloat {
        let items = slots.reduce(0) { $0 + baseWidth(of: $1) }
        return items + spacing * CGFloat(max(slots.count - 1, 0)) + padding * 2
    }

    /// Hauteur de la barre au repos
    var barHeight: CGFloat { base + indicatorHeight + padding * 2 }

    /// La fenêtre garde de la place pour l'icône agrandie et son étiquette.
    var panelWidth: CGFloat { barWidth + base * (magnification - 1) * 3 + 40 }
    var panelHeight: CGFloat {
        base * magnification + indicatorHeight + padding * 2 + labelHeadroom + bottomGap
    }

    /// Centre de chaque emplacement au repos, mesuré depuis le bord gauche de la fenêtre.
    var restingCenters: [CGFloat] {
        var x = (panelWidth - barWidth) / 2 + padding
        var centers: [CGFloat] = []
        for slot in slots {
            let w = baseWidth(of: slot)
            centers.append(x + w / 2)
            x += w + spacing
        }
        return centers
    }

    /// Facteur d'agrandissement d'un emplacement selon la position de la souris (courbe en cloche).
    func scale(forCenter center: CGFloat, mouseX: CGFloat?) -> CGFloat {
        guard let mouseX, magnification > 1.001 else { return 1 }
        let reach = base * 2.6
        let distance = abs(mouseX - center)
        guard distance < reach else { return 1 }
        let t = cos((distance / reach) * .pi / 2)
        return 1 + (magnification - 1) * t * t
    }

    /// Index de l'emplacement survolé (pour afficher son nom).
    func hoveredIndex(mouseX: CGFloat?) -> Int? {
        guard let mouseX else { return nil }
        let half = (base + spacing) / 2
        return restingCenters.firstIndex { abs($0 - mouseX) <= half }
    }
}
