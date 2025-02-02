import SwiftUI

let kAppSubsystem = "com.pr.projects.Yogurt"

@main
struct YogurtApp: App {
  @State private var showingConfig = false

  var body: some Scene {
    WindowGroup {
      ContentView()
        .sheet(isPresented: $showingConfig) {
          CloudflareConfigView()
        }
        .onAppear {
          if !CloudflareService.shared.isConfigured {
            showingConfig = true
          }
        }
    }
    .windowStyle(HiddenTitleBarWindowStyle())
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .appSettings) {
        Button("Settings...") {
          showingConfig = true
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()
        Button("View Enhancement Progress") {
          DebugWindowController.shared.toggleWindow()
        }
        .keyboardShortcut("d", modifiers: [.command])
      }
    }
  }
}
