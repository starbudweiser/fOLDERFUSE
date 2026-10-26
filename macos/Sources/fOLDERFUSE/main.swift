// Point d'entrée : fenêtre AppKit unique (taille fixe) qui héberge l'interface SwiftUI.

import AppKit
import FusionCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.apply()
        buildMenu()

        let host = NSHostingView(rootView: ContentView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "fOLDERFUSE"
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Socle.C.bg)
        model.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        UpdateCheck.start(repo: "fOLDERFUSE", lang: I18n.lang)  // nouvelle version ? (au plus une fois par jour)

        // Vérification visuelle (développement) : FOLDERFUSE_SNAPSHOT=<fichier.png> enregistre la fenêtre et quitte
        if let out = ProcessInfo.processInfo.environment["FOLDERFUSE_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                let view = window.contentView!
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    do {
                        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    } catch {
                        FileHandle.standardError.write(Data("\(error)\n".utf8))
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Ne quitte pas en laissant une copie tourner en arrière-plan.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.fusionRunning else {
            model.cancelBackgroundWork()
            return .terminateNow
        }
        Task {
            let quit = await model.confirmQuit()
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.fusionRunning else { return true }
        NSApp.terminate(nil)  // même confirmation que ⌘Q
        return false
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("À propos de fOLDERFUSE"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Masquer fOLDERFUSE"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: L("Masquer les autres"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Tout afficher"), action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quitter fOLDERFUSE"), action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: L("Fenêtre"))
        winMenu.addItem(withTitle: L("Réduire"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }
}

I18n.setLang(I18n.systemLang())
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
