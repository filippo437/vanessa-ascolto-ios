import SwiftUI

@main
struct VanessaAscoltoApp: App {
    @UIApplicationDelegateAdaptor(VanessaAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var fase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: fase) { nuova in
            // Ogni volta che l'app lascia il primo piano, prenotiamo con iOS il
            // prossimo controllo periodico (vedi VanessaAppDelegate in ContentView.swift):
            // e' questo che fa riprovare Vanessa anche se nessuno la riapre a mano.
            if nuova == .background {
                appDelegate.pianificaProssimaVerifica()
            }
        }
    }
}
