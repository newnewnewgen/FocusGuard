import Foundation

enum Paths {
    static let supportDir = "/Library/Application Support/FocusGuard"
    static let config = supportDir + "/config.json"
    static let lastGood = supportDir + "/last-good.json"
    static let clockState = supportDir + "/clock-state.json"
    static let hosts = "/etc/hosts"
    static let launchdLabel = "com.focusguard.daemon"
}
