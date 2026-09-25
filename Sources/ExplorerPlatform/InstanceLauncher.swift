import AppKit

@MainActor
public enum InstanceLauncher {
    @discardableResult
    public static func launch(applicationURL: URL = Bundle.main.bundleURL, arguments: [String] = [], activates: Bool = true) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = activates
        configuration.arguments = arguments
        return try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }
}
