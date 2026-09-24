import AppIntents
import SwiftUI
import WidgetKit

/// Boutons de Navette pour le Centre de contrôle et la barre des menus (macOS 26).
@main
struct NavetteControls: WidgetBundle {
    var body: some Widget {
        HotspotControl()
    }
}

/// « Point d'accès » : comme l'iPhone dans le menu Wi-Fi, un clic allume le point d'accès du
/// téléphone et y connecte le Mac. L'extension est sandboxée : elle se contente d'ouvrir
/// navette://point-acces, et c'est l'app Navette qui fait le travail (Bluetooth, Wi-Fi).
struct HotspotControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "fr.soufiane.navette.controles.point-acces") {
            ControlWidgetButton(action: HotspotIntent()) {
                Label("Point d’accès", systemImage: "personalhotspot")
            }
        }
        .displayName("Point d’accès du téléphone")
        .description("Allume le point d’accès du téléphone et y connecte le Mac.")
    }
}

struct HotspotIntent: AppIntent {
    static let title: LocalizedStringResource = "Activer le point d’accès du téléphone"

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "navette://point-acces")!))
    }
}
