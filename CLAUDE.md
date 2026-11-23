# BuzzDock : consignes pour Claude

App macOS native (Swift / SwiftUI / AppKit), Dock à widgets. Tout en français (textes, commentaires).

## Design : comme Apple

Pour toute modification d'interface, d'animation ou de geste, applique les skills de `.claude/skills/` :

| Skill | Quand |
|---|---|
| `apple-hig` (Apple Human Interface Guidelines, par dickwu) | référence et audit : chapitres macOS, menus du Dock, menus contextuels, glisser-déposer, couleurs, typographie, matériaux, accessibilité. Lancer un audit avec sa méthode (`references/code-audit.md`). |
| `apple-design` (Emil Kowalski) | mouvement façon WWDC « Designing Fluid Interfaces » : retour dès l'appui, ressorts interruptibles, vélocité, élasticité aux limites. Écrit pour le web : traduire en SwiftUI (`.spring(response:dampingFraction:)`, `.interactiveSpring`, `withAnimation`, `GestureState`). |
| `gestures`, `improve-animations`, `review-animations`, `animation-performance` | gestes, audit et réglage des animations, fluidité |
| `emil-design-eng` | finitions, détails invisibles |
| `write-swift` | Swift moderne, concurrence, performance |

Règles constantes :
- Retour visuel immédiat à l'appui, jamais seulement au relâchement.
- Animations par ressorts, interruptibles, qui partent de la valeur affichée.
- Respecter « Réduire les animations » (`accessibilityReduceMotion`).
- Pas de calcul coûteux dans `body` ni à chaque mouvement de souris (mettre en cache).
- Après un changement d'interface : compiler (`./scripts/build-app.sh`) et vérifier à l'écran.

## Récupérer les skills

`apple-hig` est un sous-module (le texte des HIG appartient à Apple, on ne le recopie pas) :

```bash
git submodule update --init
```
