import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var settings: DockSettings
    @EnvironmentObject private var store: DockStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var addingLink = false
    @State private var customLink = false
    @AppStorage("darkSiteIcons") private var darkSiteIcons = true

    var body: some View {
        Form {
            Section("Style") {
                Picker("Style du Dock", selection: $settings.style) {
                    ForEach(DockStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            if settings.style == .widgets {
                widgetsSection
                foldersSection
                linksSection
                widgetAppearanceSection
            } else {
                classicSection
            }

            Section {
                Toggle("Masquer automatiquement le Dock", isOn: $settings.autoHide)
                Toggle("Remplacer le Dock de macOS", isOn: $settings.hideSystemDock)
                Toggle("Ouvrir BuzzDock au démarrage du Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("Comportement")
            } footer: {
                Text("Quitter BuzzDock (clic droit sur un widget, ou icône de la barre des menus) fait revenir le Dock de macOS. Lanceur : ⌃⌥ Espace.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Importer les apps du Dock macOS") { store.importSystemDock() }
                    Spacer()
                    Button("Tout remettre par défaut") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 560, idealHeight: 720)
    }

    // MARK: Widgets : ordre et affichage

    private var widgetsSection: some View {
        Section {
            ForEach(Array(settings.widgets.enumerated()).filter { $0.element.kind != .shortcuts && $0.element.kind != .aiUsage }, id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Image(systemName: item.kind.symbol)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(item.kind.title)
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up").accessibilityLabel("Monter") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down").accessibilityLabel("Descendre") }
                        .buttonStyle(.borderless)
                        .disabled(index == settings.widgets.count - 1)
                    Toggle(item.kind.title, isOn: Binding(
                        get: { settings.widgets[index].enabled },
                        set: { settings.widgets[index].enabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Widgets")
        } footer: {
            Text("De gauche à droite dans le Dock. Les flèches changent l'ordre, l'interrupteur affiche ou masque.")
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard settings.widgets.indices.contains(target) else { return }
        settings.widgets.swapAt(index, target)
    }

    // MARK: Dossiers

    private var foldersSection: some View {
        Section {
            ForEach(store.folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    TextField("Nom", text: Binding(
                        get: { folder.name },
                        set: { store.renameFolder(folder.id, to: $0) }
                    ))
                    .textFieldStyle(.plain)
                    Text("\(folder.paths.count) apps")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Button { store.moveFolder(folder.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                    Button { store.moveFolder(folder.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                    Button(role: .destructive) { store.deleteFolder(folder.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Nouveau dossier") { store.createFolder() }
                Spacer()
                Button("Recréer les dossiers automatiques") { store.rebuildDefaultFolders() }
            }
        } header: {
            Text("Dossiers d'apps")
        } footer: {
            Text("Comme sur iPhone : clic sur un dossier pour l'ouvrir, le renommer ou y ajouter des apps. Glisser une app sur une autre crée un dossier.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Raccourcis web

    private var linksSection: some View {
        Section {
            ForEach(store.dockLinks) { link in
                linkRow(link, place: "Dock", movable: true)
            }
            ForEach(store.folders) { folder in
                ForEach(folder.links) { link in
                    linkRow(link, place: folder.name, movable: false)
                }
            }
            Toggle("Icônes de sites en version sombre (comme iOS en mode sombre)", isOn: $darkSiteIcons)
                .onChange(of: darkSiteIcons) { _, _ in
                    IconCache.forgetAll()
                    NotificationCenter.default.post(name: .buzzIconsChanged, object: nil)
                }
            if addingLink && customLink {
                WebLinkForm(
                    onAdd: { link in
                        store.addDockLink(link)
                        addingLink = false
                        customLink = false
                    },
                    onCancel: { customLink = false }
                )
            } else if addingLink {
                WebAppGallery(
                    onPick: { link in store.addDockLink(link) },
                    onCustom: { customLink = true }
                )
                Button("Terminé") { addingLink = false }
            } else {
                HStack {
                    Button("Ajouter une app web au Dock…") { addingLink = true }
                    Spacer()
                    Button("Créer le dossier Réseaux sociaux") { store.createSocialFolder() }
                }
            }
        } header: {
            Text("Raccourcis web")
        } footer: {
            Text("Comme « Sur l'écran d'accueil » sur iPhone : l'icône du site, ouvert dans le navigateur choisi. Astuce : glisse l'adresse depuis la barre de Chrome sur le Dock ou sur un dossier.")
                .foregroundStyle(.secondary)
        }
    }

    private func linkRow(_ link: WebLink, place: String, movable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WebLinkIcon(link: link, size: 26)
                TextField("Nom", text: Binding(
                    get: { link.name },
                    set: { var copy = link; copy.name = $0; store.updateLink(copy) }
                ))
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                Text(place).font(.caption).foregroundStyle(.secondary)
                if movable {
                    Button { store.moveDockLink(link.id, by: -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                    Button { store.moveDockLink(link.id, by: 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                }
                Button(role: .destructive) { store.removeLink(link.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                TextField("Adresse", text: Binding(
                    get: { link.url },
                    set: {
                        var copy = link
                        copy.url = $0
                        store.updateLink(copy)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { WebIconCache.shared.forget(link) }
                Picker("", selection: Binding(
                    get: { link.browser },
                    set: { var copy = link; copy.browser = $0; store.updateLink(copy) }
                )) {
                    Text("Navigateur par défaut").tag(String?.none)
                    ForEach(Browsers.installed) { b in Text(b.name).tag(Optional(b.bundleID)) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            if Browsers.supportsAppWindow(link.browser) {
                Toggle(Browsers.appModeLabel(link.browser), isOn: Binding(
                    get: { link.appWindow },
                    set: { var copy = link; copy.appWindow = $0; store.updateLink(copy) }
                ))
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Apparence

    private var widgetAppearanceSection: some View {
        Section("Apparence") {
            Picker("Matière", selection: $settings.material) {
                ForEach(DockMaterial.allCases) { material in
                    Text(material.label).tag(material)
                }
            }
            .pickerStyle(.segmented)
            if settings.material == .glass {
                Slider(value: $settings.glassTint, in: 0...0.6, step: 0.05) { Text("Teinte du verre") }
                Toggle("Fusion liquide des tuiles", isOn: $settings.liquidMerge)
            }
            Slider(value: $settings.tileSize, in: 44...96, step: 2) { Text("Taille") }
            Slider(value: $settings.magnification, in: 1...2, step: 0.05) { Text("Effet loupe des apps") }
            Slider(value: $settings.tileCorner, in: 2...30, step: 1) { Text("Arrondi des tuiles") }
            if settings.material == .tinted {
                Slider(value: $settings.tileOpacity, in: 0...0.9, step: 0.05) { Text("Opacité des tuiles") }
                Slider(value: $settings.barOpacity, in: 0...1, step: 0.05) { Text("Opacité de la barre") }
                ColorPicker("Couleur à gauche", selection: Binding(
                    get: { settings.barColorStart.color },
                    set: { settings.barColorStart = RGBA($0) }
                ))
                ColorPicker("Couleur à droite", selection: Binding(
                    get: { settings.barColorEnd.color },
                    set: { settings.barColorEnd = RGBA($0) }
                ))
            }
            Toggle("Horloge sur 24 heures", isOn: $settings.clock24h)
        }
    }

    private var classicSection: some View {
        Section("Dock classique") {
            Slider(value: $settings.iconSize, in: 32...96, step: 2) { Text("Taille des icônes") }
            Slider(value: $settings.magnification, in: 1...2, step: 0.05) { Text("Effet loupe") }
            Toggle("Afficher les apps ouvertes", isOn: $settings.showRunningApps)
            Toggle("Afficher les Téléchargements", isOn: $settings.showDownloads)
            Toggle("Afficher la Corbeille", isOn: $settings.showTrash)
        }
    }
}
