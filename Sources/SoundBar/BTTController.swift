import AppKit

/// Answers requirement 3: once the visualiser has been stopped, has BetterTouchTool got the Touch
/// Bar back?
///
/// The signal that actually works is BetterTouchTool's own `BTTTouchBarVisible` preference. It is
/// live state, not a stored setting — measured on this machine:
///
///     before quitting AVTouchBar: 0
///     after quitting AVTouchBar:  1
///
/// BTT clears it while another application presents a system-modal Touch Bar and sets it again when
/// the strip is handed back. Reading it costs nothing and needs no permission, which makes it a far
/// better primary check than BTT's scripting interface.
///
/// `get_active_touch_bar_group` is still queried, but only to name the group for the user, and only
/// if Automation has been approved — SoundBar never depends on it.
final class BTTController {

    static let bundleID = "com.hegenberg.BetterTouchTool"
    private static let visibleKey = "BTTTouchBarVisible"

    enum TouchBarState: CustomStringConvertible {
        /// BTT reports its Touch Bar as visible. `group` is nil when it could not be queried.
        case hasTouchBar(group: String?)
        /// BTT is running but something else still owns the Touch Bar.
        case doesNotHaveTouchBar
        case notRunning
        /// BTT's preference could not be read at all.
        case unknown(String)

        var description: String {
            switch self {
            case .hasTouchBar(let group):
                switch group {
                case .some(let name) where !name.isEmpty:
                    return "BetterTouchTool has the Touch Bar (group: \(name))."
                case .some:
                    return "BetterTouchTool has the Touch Bar (root group)."
                case .none:
                    return "BetterTouchTool has the Touch Bar."
                }
            case .doesNotHaveTouchBar:
                return "BetterTouchTool does not have the Touch Bar — something else is still "
                     + "presenting on it."
            case .notRunning:
                return "BetterTouchTool is not running, so nothing will take the Touch Bar back."
            case .unknown(let detail):
                return "Could not determine BetterTouchTool's Touch Bar state: \(detail)"
            }
        }

        var isHealthy: Bool { if case .hasTouchBar = self { return true }; return false }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Reads BTT's live Touch Bar visibility. Synchronises first, because another process's
    /// preferences are cached and would otherwise return a stale value.
    private func touchBarVisibleInBTT() -> Bool? {
        CFPreferencesAppSynchronize(Self.bundleID as CFString)
        guard let value = CFPreferencesCopyAppValue(Self.visibleKey as CFString,
                                                    Self.bundleID as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Checks whether BTT has the Touch Bar. Cheap and permission-free; the optional group name is
    /// fetched afterwards and never blocks the answer.
    func verifyOwnsTouchBar(_ completion: @escaping (TouchBarState) -> Void) {
        guard isRunning else {
            Log.warn("btt", "BetterTouchTool is not running")
            DispatchQueue.main.async { completion(.notRunning) }
            return
        }
        guard let visible = touchBarVisibleInBTT() else {
            DispatchQueue.main.async { completion(.unknown("\(Self.visibleKey) is not readable")) }
            return
        }
        guard visible else {
            Log.warn("btt", "BetterTouchTool does not have the Touch Bar (\(Self.visibleKey)=0)")
            DispatchQueue.main.async { completion(.doesNotHaveTouchBar) }
            return
        }
        // BTT has it. Try to name the group, but do not let a missing Automation grant turn a
        // healthy result into a failure.
        DispatchQueue.global(qos: .utility).async {
            let group = self.queryActiveGroup()
            Log.info("btt", "BetterTouchTool has the Touch Bar (group: \(group ?? "unknown"))")
            DispatchQueue.main.async { completion(.hasTouchBar(group: group)) }
        }
    }

    /// Polls BTT's visibility flag until it flips to true, for use straight after stopping the
    /// visualiser — the handover is not instantaneous.
    func waitForTouchBarHandback(timeout: TimeInterval = 4.0,
                                 _ completion: @escaping (TouchBarState) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard isRunning else { completion(.notRunning); return }
            if touchBarVisibleInBTT() == true {
                verifyOwnsTouchBar(completion)
                return
            }
            guard Date() < deadline else {
                Log.warn("btt", "BetterTouchTool did not reclaim the Touch Bar within \(timeout)s")
                completion(.doesNotHaveTouchBar)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
    }

    /// The group BTT currently shows, or nil if it could not be asked. An empty string is BTT's
    /// root group, which is the ordinary case.
    private func queryActiveGroup() -> String? {
        let source = """
        tell application id "\(Self.bundleID)"
            get_active_touch_bar_group
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743 is "the user has not approved Automation for this app". Not fatal here.
            Log.debug("btt", "could not read the active group (\(number)); reporting without it")
            return nil
        }
        let group = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ["null", "missing value"].contains(group.lowercased()) ? "" : group
    }
}
