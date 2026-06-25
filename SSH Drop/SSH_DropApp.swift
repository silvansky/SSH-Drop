import SwiftUI

@main
struct SSH_DropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = TransferManager.shared

    var body: some Scene {
        Window("SSH Drop", id: "main") {
            ContentView(manager: manager)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
