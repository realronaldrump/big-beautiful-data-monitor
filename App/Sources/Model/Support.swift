import Foundation
import ServiceManagement

/// Launch at login through `SMAppService`, on by default.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Degrade quietly: the setting simply shows as off.
            #if DEBUG
            print("Login item change failed: \(error)")
            #endif
        }
    }

    /// Turns it on once, the first time the app runs from Applications (never for development builds).
    static func enableOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}

/// Relatable equivalents, shown on hover.
enum Equivalent {
    /// Netflix's published estimate for HD video: up to 3 GB an hour
    /// (help.netflix.com/en/node/87, checked October 2026).
    static let hdVideoBytesPerHour = 3e9

    static func hdVideo(_ bytes: UInt64) -> String {
        let minutes = Double(bytes) / hdVideoBytesPerHour * 60
        switch minutes {
        case ..<1:
            return "less than a minute of HD video"
        case ..<1.5:
            return "about a minute of HD video"
        case ..<10:
            return "about \(Int(minutes.rounded())) minutes of HD video"
        case ..<55:
            return "about \(Int((minutes / 5).rounded()) * 5) minutes of HD video"
        case ..<75:
            return "about an hour of HD video"
        default:
            let hours = (minutes / 30).rounded() / 2
            let text = hours == hours.rounded() ? "\(Int(hours))" : String(format: "%.1f", hours)
            return "about \(text) hours of HD video"
        }
    }
}

extension Date {
    /// "2 PM", "midnight", "noon": plain words for an hour.
    var hourName: String {
        let hour = Calendar.current.component(.hour, from: self)
        switch hour {
        case 0: return "midnight"
        case 12: return "noon"
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("j")
            return formatter.string(from: self).replacingOccurrences(of: "\u{202F}", with: " ")
        }
    }
}
