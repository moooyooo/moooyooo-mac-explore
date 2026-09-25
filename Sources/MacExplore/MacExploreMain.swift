import AppKit

@main
@MainActor
struct MacExploreMain {
    static func main() {
        let start = ProcessInfo.processInfo.systemUptime
        let application = ExplorerApplication.shared
        application.setActivationPolicy(.regular)
        let coordinator = AppCoordinator(startTime: start)
        application.delegate = coordinator
        withExtendedLifetime(coordinator) { application.run() }
    }
}
