// Interface : en-tête de marque, sélecteurs Source / Destination, bouton FUSIONNER, barre de progression.
// Tout est plat (Socle) : aplats de couleur, aucun contour, aucune ombre.

import FusionCore
import SwiftUI

// Couleur de marque de fOLDERFUSE (orange pastel) et ses textes (contraste ≥ 7:1)
let BRAND_BG = Color(red: 0xf3 / 255, green: 0x9c / 255, blue: 0x4a / 255)
let BRAND_TEXT = Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255)
let BRAND_TEXT_MUTED = Color(red: 0x3d / 255, green: 0x24 / 255, blue: 0x10 / 255)

// Largeur de la fenêtre : 540 px pour des textes à 100 %, mise à l'échelle des textes Socle (110 %).
let WINDOW_WIDTH = (540 * max(1, Socle.scale)).rounded()

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            header
            HStack(spacing: Socle.M.space2) {
                FolderPicker(title: L("SOURCE"), path: model.source, detail: model.sourceDetail,
                             enabled: !model.running) { model.chooseSource() }
                FolderPicker(title: L("DESTINATION"), path: model.destination, detail: model.destinationDetail,
                             enabled: !model.running) { model.chooseDestination() }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button(model.running ? L("ARRÊTER") : L("FUSIONNER")) { model.fuseClicked() }
                .buttonStyle(FuseButtonStyle(running: model.running))
                .disabled(!model.fuseEnabled)
            ProgressBar(value: model.progress, text: model.progressText, status: model.status)
        }
        .padding(Socle.M.space3)
        .frame(width: WINDOW_WIDTH)
        .background(Socle.C.bg)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(verbatim: "fOLDERFUSE").socle(Socle.T.heading).foregroundStyle(BRAND_TEXT)
            Text(L("Les fichiers de même nom sont remplacés dans la destination."))
                .socle(Socle.T.meta).foregroundStyle(BRAND_TEXT_MUTED)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(Socle.M.space2)
        .background(BRAND_BG, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
    }
}

/// Sélecteur de dossier : titre + chemin choisi (ou invite) + détail, centrés.
struct FolderPicker: View {
    let title: String
    let path: String
    let detail: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Socle.M.space1) {
                Text(title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                if path.isEmpty {
                    Text(L("Choisir un dossier")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                } else {
                    Text(verbatim: shortPath(path)).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText)
                }
                Text(verbatim: detail.isEmpty ? " " : detail).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(Socle.M.space3)
        }
        .buttonStyle(PickerStyle())
        .disabled(!enabled)
        .help(path)
    }

    private func shortPath(_ p: String, maxChars: Int = 30) -> String {
        guard p.count > maxChars else { return p }
        let half = (maxChars - 3) / 2
        return String(p.prefix(half)) + "..." + String(p.suffix(half))
    }
}

struct PickerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(background, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
        }

        private var background: Color {
            if !enabled { return Socle.C.surface }
            if configuration.isPressed { return Socle.C.surfaceSelected }
            return hover ? Socle.C.surfaceHover : Socle.C.surfaceRaised
        }
    }
}

/// FUSIONNER (aplat accent) qui devient ARRÊTER (aplat neutre) pendant l'analyse et la copie.
struct FuseButtonStyle: ButtonStyle {
    let running: Bool

    func makeBody(configuration: Configuration) -> some View {
        if running {
            AnyView(StopBody(configuration: configuration))
        } else {
            AnyView(SocleButtonStyle(.primary).makeBody(configuration: configuration))
        }
    }

    private struct StopBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .socle(Socle.T.buttonFlow)
                .foregroundStyle(enabled ? Socle.C.textStrong : Socle.C.textDisabled)
                .frame(maxWidth: .infinity, minHeight: Socle.M.sizeControlLg)
                .background(background, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }

        private var background: Color {
            if configuration.isPressed && enabled { return Socle.C.controlPressed }
            return hover && enabled ? Socle.C.controlHover : Socle.C.controlStrong
        }
    }
}

enum BarStatus { case none, success, warning, stalled, danger }

/// Barre de progression plate : fond et remplissage en aplats, texte centré.
struct ProgressBar: View {
    let value: Int
    let text: String
    let status: BarStatus

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(fill).frame(width: geo.size.width * CGFloat(min(max(value, 0), 100)) / 100)
                Text(verbatim: text)
                    .socle(Socle.T.body)
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Socle.M.sizeControlLg)
        .clipShape(RoundedRectangle(cornerRadius: Socle.M.radius))
    }

    private var track: Color {
        switch status {
        case .none: Socle.C.control
        case .success: Socle.C.successBg
        case .warning, .stalled: Socle.C.warningBg
        case .danger: Socle.C.dangerBg
        }
    }

    private var fill: Color {
        switch status {
        case .none, .stalled: Socle.C.accentFill
        case .success: Socle.C.successBg
        case .warning: Socle.C.warningBg
        case .danger: Socle.C.dangerBg
        }
    }

    private var foreground: Color {
        switch status {
        case .none: Socle.C.textStrong
        case .success: Socle.C.successSoft
        case .warning, .stalled: Socle.C.warningSoft
        case .danger: Socle.C.dangerSoft
        }
    }
}
