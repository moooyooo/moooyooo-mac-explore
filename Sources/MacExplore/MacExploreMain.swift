import AppKit
import ExplorerCore

@main
@MainActor
struct MacExploreMain {
    static func main() {
        let start = ProcessInfo.processInfo.systemUptime
        LanguageSettings.bootstrap()
        let application = ExplorerApplication.shared
        application.setActivationPolicy(.regular)
        let coordinator = AppCoordinator(startTime: start)
        application.delegate = coordinator
        withExtendedLifetime(coordinator) { application.run() }
    }
}
