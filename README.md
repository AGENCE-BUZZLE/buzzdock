# BuzzDock

Un Dock à widgets pour macOS, en Swift / SwiftUI, qui remplace le Dock d'Apple.

## Ce qu'il fait

- **Dock à widgets** en Liquid Glass (macOS 26) : horloge, morceau en cours (Spotify, Musique), processeur, batterie, réseau, jours du mois.
- **Apps** : apps gardées et apps ouvertes, effet loupe, rebond au lancement, point sous les apps ouvertes, pastilles rouges de notification.
- **Dossiers façon iPhone** : grille 3 × 3, ouverture au clic, renommage, glisser une app sur une autre pour créer un dossier.
- **Apps web** : un site devient une vraie app (icône du site, sa propre fenêtre, notifications, pastille), avec une galerie de 25 apps prêtes à ajouter (Instagram, WhatsApp, Gmail, Notion, ChatGPT…).
- **Menu des apps** comme le Dock d'Apple (clic droit) et **aperçus des fenêtres** (appui long).
- **Téléchargements et Corbeille** dans un même bloc.
- **Lanceur plein écran** : ⌃⌥ Espace.
- Tout se personnalise : clic droit sur un widget › « Personnaliser le Dock… ».

## Prérequis

- macOS 14 ou plus récent (macOS 26 pour le Liquid Glass)
- Xcode 16 ou plus récent (Xcode 26 pour le Liquid Glass)

## Compiler et installer

```bash
git clone <adresse-de-ce-dépôt> buzzdock
cd buzzdock
./scripts/build-app.sh
cp -R build/BuzzDock.app /Applications/
open /Applications/BuzzDock.app
```

Pour fabriquer un DMG : `./scripts/build-dmg.sh` (résultat dans `build/BuzzDock.dmg`).

Pour développer : `open Package.swift` dans Xcode, schéma **BuzzDock**, ⌘R.

## Signature

`scripts/build-app.sh` signe automatiquement avec le premier certificat « Apple Development » trouvé sur le Mac, sinon en local (ad hoc).

- Pour choisir un autre certificat : `SIGN_IDENTITY="Developer ID Application: Ton nom (TEAMID)" ./scripts/build-app.sh`
- Une signature stable (certificat) évite que macOS redemande les autorisations à chaque nouvelle compilation.
- Pour distribuer à d'autres Mac sans alerte, il faut un certificat « Developer ID Application » puis une notarisation Apple (`xcrun notarytool`).
- Pense à changer l'identifiant `fr.buzzle.buzzdock` dans `Resources/Info.plist` si tu publies ta propre version.

## Autorisations macOS

Demandées au fil de l'utilisation :

| Autorisation | Pour quoi |
|---|---|
| Accessibilité | liste et ouverture des fenêtres, pastilles de notification, « Nouvelle fenêtre » |
| Enregistrement de l'écran | vignettes des fenêtres (appui long) |
| Automatisation (Spotify, Musique, Finder, System Events) | morceau en cours, Corbeille pleine, ouverture à la connexion |

## Si le Dock d'Apple ne revient pas

BuzzDock remet le Dock d'Apple en quittant. Après un plantage :

```bash
defaults delete com.apple.dock autohide-delay; defaults delete com.apple.dock no-bouncing; killall Dock
```

## Organisation du code

| Fichier | Rôle |
|---|---|
| `Sources/BuzzDock/App.swift` | point d'entrée, barre des menus, cycle de vie |
| `DockController.swift` | fenêtre du Dock, position, masquage automatique, souris |
| `DockStore.swift` | apps gardées et ouvertes, dossiers, raccourcis, pastilles |
| `WidgetDock.swift` | Dock à widgets, loupe, dossiers, apps, Téléchargements, Corbeille |
| `WidgetProviders.swift` | processeur, batterie, réseau, morceau en cours |
| `WebLinks.swift` | raccourcis et apps web, icônes des sites, galerie |
| `DockMenu.swift` | menu des apps, fenêtres (Accessibilité), pastilles |
| `WindowPreview.swift` | aperçus des fenêtres |
| `DockPopup.swift` | fenêtres surgissantes au-dessus du Dock |
| `Launcher.swift` | lanceur plein écran |
| `SettingsView.swift`, `DockSettings.swift` | réglages |
| `SystemDockService.swift` | masquage et restauration du Dock d'Apple |
| `Sources/BuzzWebApp/main.swift` | coquille WebKit des apps web générées |
