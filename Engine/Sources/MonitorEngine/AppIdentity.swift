import Foundation

/// What a row is labeled with in the UI: a real app (shown with its icon) or a plain-words system group.
public struct AppIdentity: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case app
        case system
    }

    /// Stable storage key: the bundle identifier for apps, `system.<slug>` for system groups.
    public let key: String
    public let displayName: String
    public let kind: Kind
    public let bundleID: String?
    /// Path to the `.app`, for the icon.
    public let bundlePath: String?
    /// SF Symbol for system groups.
    public let symbolName: String?

    public init(key: String, displayName: String, kind: Kind, bundleID: String? = nil,
                bundlePath: String? = nil, symbolName: String? = nil) {
        self.key = key
        self.displayName = displayName
        self.kind = kind
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.symbolName = symbolName
    }

    public static let macSystem = AppIdentity(
        key: "system.mac", displayName: "Mac system", kind: .system, symbolName: "desktopcomputer")

    static func system(_ slug: String, _ name: String, symbol: String) -> AppIdentity {
        AppIdentity(key: "system.\(slug)", displayName: name, kind: .system, symbolName: symbol)
    }
}

/// Plain-words names for system processes, keyed by executable name.
/// Started from the spec's list and grown from real traffic on this Mac.
enum FriendlyNames {
    static let iCloud = AppIdentity.system("icloud", "iCloud", symbol: "icloud")
    static let updates = AppIdentity.system("updates", "macOS updates", symbol: "arrow.down.app")
    static let housekeeping = AppIdentity.system("network", "Network housekeeping", symbol: "network")
    static let security = AppIdentity.system("security", "Security checks", symbol: "checkmark.shield")
    static let nearby = AppIdentity.system("nearby", "Nearby devices", symbol: "airplayaudio")
    static let messages = AppIdentity.system("messages", "Messages and FaceTime", symbol: "message")
    static let appleServices = AppIdentity.system("appleservices", "Apple services", symbol: "apple.logo")
    static let findMy = AppIdentity.system("findmy", "Find My", symbol: "location.circle")
    static let account = AppIdentity.system("account", "Apple Account", symbol: "person.crop.circle")
    static let diagnostics = AppIdentity.system("diagnostics", "Diagnostics reports", symbol: "stethoscope")
    static let photos = AppIdentity.system("photos", "Photos", symbol: "photo")
    static let airplay = AppIdentity.system("airplay", "AirPlay", symbol: "airplayvideo")

    static let table: [String: AppIdentity] = [
        "nsurlsessiond": .system("background", "Background downloads", symbol: "arrow.down.circle"),
        "cloudd": iCloud,
        "bird": iCloud,
        "fileproviderd": iCloud,
        "cloudphotod": .system("icloudphotos", "iCloud Photos", symbol: "photo.on.rectangle"),
        "softwareupdated": updates,
        "mobileassetd": updates,
        "com.apple.MobileSoftwareUpdate.UpdateBrainService": updates,
        "apsd": .system("notifications", "Notifications", symbol: "bell"),
        "mDNSResponder": housekeeping,
        "netbiosd": housekeeping,
        "configd": housekeeping,
        "airportd": housekeeping,
        "symptomsd": housekeeping,
        "timed": housekeeping,
        "networkserviceproxy": .system("privaterelay", "iCloud Private Relay", symbol: "lock.icloud"),
        "trustd": security,
        "syspolicyd": security,
        "ocspd": security,
        "identityservicesd": messages,
        "IMTransferAgent": messages,
        "imagent": messages,
        "callservicesd": messages,
        "avconferenced": messages,
        "accountsd": .system("accounts", "Internet accounts", symbol: "at"),
        "amsengagementd": appleServices,
        "amsaccountsd": appleServices,
        "amsondevicestoraged": appleServices,
        "searchpartyd": findMy,
        "findmydeviced": findMy,
        "findmylocated": findMy,
        "secd": account,
        "photolibraryd": photos,
        "cloudphotosd": .system("icloudphotos", "iCloud Photos", symbol: "photo.on.rectangle"),
        "mediaanalysisd": photos,
        "photoanalysisd": photos,
        "AirPlayXPCHelper": airplay,
        "mediaremoted": airplay,
        "ReportCrash": diagnostics,
        "SubmitDiagInfo": diagnostics,
        "analyticsd": diagnostics,
        "CalendarAgent": .system("calendar", "Calendar", symbol: "calendar"),
        "remindd": .system("reminders", "Reminders", symbol: "checklist"),
        "ContactsAgent": .system("contacts", "Contacts", symbol: "person.2"),
        "weatherd": .system("weather", "Weather", symbol: "cloud.sun"),
        "newsd": .system("news", "News", symbol: "newspaper"),
        "itunescloudd": .system("media", "Music and TV library", symbol: "music.note"),
        "suggestd": .system("suggestions", "Siri and Spotlight", symbol: "magnifyingglass"),
        "siriknowledged": .system("suggestions", "Siri and Spotlight", symbol: "magnifyingglass"),
        "WiFiAgent": housekeeping,
        "rapportd": nearby,
        "sharingd": nearby,
        "usbmuxd": .system("iphone", "iPhone connection", symbol: "iphone"),
        "remotepairingd": .system("iphone", "iPhone connection", symbol: "iphone"),
        "appstoreagent": .system("appstore", "App Store", symbol: "bag"),
        "storedownloadd": .system("appstore", "App Store", symbol: "bag"),
        "commerce": .system("appstore", "App Store", symbol: "bag"),
        "akd": account,
        "parsecd": .system("suggestions", "Siri and Spotlight", symbol: "magnifyingglass"),
        "assistantd": .system("suggestions", "Siri and Spotlight", symbol: "magnifyingglass"),
        "locationd": .system("location", "Location services", symbol: "location"),
        "geod": .system("maps", "Maps", symbol: "map"),
        "backupd": .system("timemachine", "Time Machine", symbol: "clock.arrow.circlepath"),
    ]

    static func lookup(_ executableName: String) -> AppIdentity? {
        table[executableName]
    }

    /// `nettop` truncates names to 15 characters; match a truncated name against the table.
    static func lookup(truncated name: String) -> AppIdentity? {
        if let exact = table[name] { return exact }
        guard name.count >= 15 else { return nil }
        return table.first { $0.key.hasPrefix(name) }?.value
    }
}
