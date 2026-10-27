import Foundation

enum Paths {
    static let supportDir = "/Library/Application Support/FocusGuard"   // root:admin 0775
    static let config = supportDir + "/config.json"                      // admin-writable
    static let stateDir = supportDir + "/state"                          // root:wheel 0700
    static let lastGood = stateDir + "/last-good.json"
    static let clockState = stateDir + "/clock-state.json"
    static let hosts = "/etc/hosts"
    static let launchdLabel = "com.focusguard.daemon"
}
