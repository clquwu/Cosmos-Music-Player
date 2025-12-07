import Foundation
import SwiftUI
import UIKit

enum BackgroundColor: String, CaseIterable, Codable {
    case violet = "b11491"
    case red = "e74c3c"
    case blue = "3498db" 
    case green = "27ae60"
    case orange = "f39c12"
    case pink = "e91e63"
    case teal = "1abc9c"
    case purple = "9b59b6"
    
    var name: String {
        switch self {
        case .violet: return "Violet (Default)"
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .purple: return "Purple"
        }
    }
    
    var color: Color {
        return Color(hex: self.rawValue)
    }
}

enum DSDPlaybackMode: String, CaseIterable, Codable {
    case auto = "auto"
    case pcm = "pcm"
    case dop = "dop"

    var displayName: String {
        switch self {
        case .auto: return Localized.dsdModeAuto
        case .pcm: return Localized.dsdModePCM
        case .dop: return Localized.dsdModeDoP
        }
    }

    var description: String {
        switch self {
        case .auto: return Localized.dsdModeAutoDescription
        case .pcm: return Localized.dsdModePCMDescription
        case .dop: return Localized.dsdModeDoDescription
        }
    }
}

struct DeleteSettings: Codable {
    var hasShownDeletePopup: Bool = false
    var minimalistIcons: Bool = false
    var backgroundColorChoice: BackgroundColor = .violet
    var forceDarkMode: Bool = false
    var dsdPlaybackMode: DSDPlaybackMode = .pcm
    var lastLibraryScanDate: Date? = nil

    static func load() -> DeleteSettings {
        guard let data = UserDefaults.standard.data(forKey: "DeleteSettings"),
              let settings = try? JSONDecoder().decode(DeleteSettings.self, from: data) else {
            return DeleteSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "DeleteSettings")
        }
    }
}

// MARK: - Color Extension for Widget
extension Color {
    func toHex() -> String {
        #if canImport(UIKit)
        let components = UIColor(self).cgColor.components
        let r = Float(components?[0] ?? 0)
        let g = Float(components?[1] ?? 0)
        let b = Float(components?[2] ?? 0)

        return String(format: "%02lX%02lX%02lX",
                      lroundf(r * 255),
                      lroundf(g * 255),
                      lroundf(b * 255))
        #else
        return "b11491" // Default violet
        #endif
    }
}
