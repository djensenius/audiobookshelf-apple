#if DEBUG
    import ABSAppModel
    import Foundation

    extension FixtureServer {
        /// Followed by a state (`-ABSConnectionState offline`), forces what the shell's connection indicator shows
        /// on a fixture launch (#691). A fixture launch has no realtime socket (`AppEnvironment`'s `realtime`), so the
        /// indicator is otherwise hidden. Only the indicator changes: the network, the connection banner and the
        /// fixture server's replies don't. The states are `connecting`, `offline`, `serverUnreachable`, `connected`,
        /// `cellular` (connected over unmetered cellular) and `metered` (connected over metered Wi-Fi).
        static let connectionStateArgument = "-ABSConnectionState"

        /// The connection indicator state `arguments` force with ``connectionStateArgument``, or `nil` for none, an
        /// unknown one, or a launch without ``launchArgument``.
        static func connectionState(arguments: [String]) -> ConnectionIndicatorState? {
            guard arguments.contains(launchArgument),
                let index = arguments.lastIndex(of: connectionStateArgument), index + 1 < arguments.endIndex
            else { return nil }
            return switch arguments[index + 1] {
            case "connecting": .connecting
            case "offline": .offline
            case "serverUnreachable": .serverUnreachable
            case "connected": .connected(cellular: false, metered: false)
            case "cellular": .connected(cellular: true, metered: false)
            case "metered": .connected(cellular: false, metered: true)
            default: nil
            }
        }
    }
#endif
