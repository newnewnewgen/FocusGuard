import Foundation
import os
import FocusGuardCore

struct OSLogAdapter: ReconcilerLog {
    private let logger = Logger(subsystem: "com.focusguard", category: "daemon")
    func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
