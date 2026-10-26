// Avertit qu'une nouvelle version existe (dernière release GitHub), sans rien télécharger ni installer.
// Fichier commun aux applis Skyrim Tools en Swift : la source est _tools/shared/UpdateCheck.swift, recopiée
// par _tools/sync_shared.sh. Ne pas le modifier dans une appli.
// Au plus une requête par jour ; « Ignorer cette version » n'affiche plus rien jusqu'à la suivante.
import AppKit

@MainActor
enum UpdateCheck {
    static let kitPage = "https://www.nexusmods.com/skyrimspecialedition/mods/196272?tab=files"
    private static let day: TimeInterval = 24 * 3600
    private static let texts: [String: [String]] = [   // titre, message, ouvrir, plus tard, ignorer
        "fr": ["Nouvelle version", "%@ %@ est disponible (vous avez la %@).", "Ouvrir la page Nexus", "Plus tard", "Ignorer cette version"],
        "en": ["New version", "%@ %@ is available (you have %@).", "Open the Nexus page", "Later", "Skip this version"],
        "es": ["Nueva versión", "%@ %@ está disponible (tienes la %@).", "Abrir la página de Nexus", "Más tarde", "Omitir esta versión"],
        "it": ["Nuova versione", "%@ %@ è disponibile (hai la %@).", "Apri la pagina Nexus", "Più tardi", "Ignora questa versione"],
    ]

    static func numbers(_ v: String) -> [Int] {
        let core = v.split(separator: "-").first.map(String.init) ?? v
        var n = core.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.prefix(3).map { $0 }
        while !n.isEmpty && n.count < 3 { n.append(0) }
        return n
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = numbers(latest), b = numbers(current)
        return !a.isEmpty && !b.isEmpty && a.lexicographicallyPrecedes(b) == false && a != b
    }

    static func start(repo: String, lang: String, page: String = kitPage) {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        let defaults = UserDefaults.standard
        let checked = defaults.double(forKey: "updateCheck.checked")
        Task {
            var latest = defaults.string(forKey: "updateCheck.latest") ?? ""
            if checked == 0 || Date().timeIntervalSince1970 - checked >= day {
                guard let fetched = await fetchLatest(repo) else { return }  // hors ligne : réessai au prochain lancement
                latest = fetched
                defaults.set(Date().timeIntervalSince1970, forKey: "updateCheck.checked")
                defaults.set(latest, forKey: "updateCheck.latest")
            }
            guard isNewer(latest, than: current), defaults.string(forKey: "updateCheck.skipped") != latest else { return }
            ask(latest: latest, current: current, lang: lang, page: page)
        }
    }

    private static func fetchLatest(_ repo: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/starbudweiser/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(repo)-update-check", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["tag_name"] as? String
    }

    private static func ask(latest: String, current: String, lang: String, page: String) {
        let t = texts[String(lang.prefix(2))] ?? texts["en"]!
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
        let shown = latest.hasPrefix("v") || latest.hasPrefix("V") ? String(latest.dropFirst()) : latest
        let alert = NSAlert()
        alert.messageText = t[0]
        alert.informativeText = String(format: t[1], name, shown, current)
        alert.addButton(withTitle: t[2])
        alert.addButton(withTitle: t[3])
        alert.addButton(withTitle: t[4])
        switch alert.runModal() {
        case .alertFirstButtonReturn: if let u = URL(string: page) { NSWorkspace.shared.open(u) }
        case .alertThirdButtonReturn: UserDefaults.standard.set(latest, forKey: "updateCheck.skipped")
        default: break
        }
    }
}
