import SwiftUI

class DebugWindowController: NSObject {
  static let shared = DebugWindowController()
  private var windowController: NSWindowController?

  override private init() {
    super.init()
  }

  func showWindow() {
    if let windowController = self.windowController {
      windowController.showWindow(nil)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
      styleMask: [.borderless, .resizable],
      backing: .buffered,
      defer: false
    )

    // Basic window setup
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.level = .floating
    window.isMovableByWindowBackground = true

    let containerView = NSView()
    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = 12
    containerView.layer?.masksToBounds = true

    // Create visual effect view for background
    let visualEffect = NSVisualEffectView()
    visualEffect.material = .hudWindow
    visualEffect.state = .active
    visualEffect.blendingMode = .behindWindow

    // Configure content
    let hostView = NSHostingView(rootView: DebugView())

    // Set up view hierarchy
    containerView.addSubview(visualEffect)
    containerView.addSubview(hostView)
    window.contentView = containerView

    // Make views fill their containers
    visualEffect.translatesAutoresizingMaskIntoConstraints = false
    hostView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      // Visual effect fills container
      visualEffect.topAnchor.constraint(equalTo: containerView.topAnchor),
      visualEffect.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      visualEffect.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      visualEffect.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

      // Host view fills container
      hostView.topAnchor.constraint(equalTo: containerView.topAnchor),
      hostView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      hostView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      hostView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    window.setFrameAutosaveName("EnhancementDebugWindow")

    // Create a window controller to manage the window's lifecycle
    let controller = NSWindowController(window: window)
    window.delegate = self
    self.windowController = controller

    controller.showWindow(nil)

    // Position the window after it's shown
    if let mainWindow = NSApplication.shared.mainWindow {
      let mainFrame = mainWindow.frame
      var debugFrame = window.frame

      // Set size and position
      debugFrame.size.width = 340  // Force the width we want
      debugFrame.size.height = mainFrame.height
      debugFrame.origin.x = mainFrame.maxX + 10
      debugFrame.origin.y = mainFrame.minY

      window.setFrame(debugFrame, display: true)
    } else {
      // If no main window, center on screen
      window.center()
    }
  }

  func toggleWindow() {
    if windowController != nil {
      windowController?.close()
      windowController = nil
    } else {
      showWindow()
    }
  }
}

extension DebugWindowController: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    windowController = nil
  }
}
