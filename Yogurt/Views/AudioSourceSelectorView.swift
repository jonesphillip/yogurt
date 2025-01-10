import AVFoundation
import CoreAudio
import Foundation
import OSLog
import SwiftUI

struct AudioSourceSelectorView: NSViewRepresentable {
  let audioManager: AudioSourceManager
  let onSelect: (AudioSource?) -> Void
  private let browserFinder = DefaultBrowserFinder()

  func makeNSView(context: Context) -> NSView {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.target = context.coordinator
    button.action = #selector(Coordinator.menuAction(_:))

    if let buttonCell = button.cell as? NSButtonCell {
      buttonCell.imagePosition = .imageOnly
    }

    updateMenu(button)
    return button
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let button = nsView as? NSPopUpButton else { return }
    updateMenu(button)
  }

  private func updateMenu(_ button: NSPopUpButton) {
    let menu = NSMenu()
    let isDefaultChrome = browserFinder.isDefaultBrowserChrome

    // Display item (when menu is collapsed)
    let firstItem = NSMenuItem()

    // Filter out Safari GPU process when Safari exists
    let processesToDisplay = audioManager.availableProcesses.filter { process in
      if process.name == "Safari Graphics and Media" {
        // Only include GPU process if Safari itself isn't in the list
        return !audioManager.availableProcesses.contains { $0.name == "Safari" }
      }
      return true
    }

    if let selectedProcess = audioManager.selections.selectedProcess {
      if selectedProcess.id == "system-audio" {
        firstItem.image = NSImage(
          systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
      } else if selectedProcess.name == "Safari Graphics and Media" {
        if let safariIcon = getSafariIcon() {
          safariIcon.size = NSSize(width: 24, height: 24)
          firstItem.image = safariIcon
        }
      } else if let bundleURL = selectedProcess.bundleURL {
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 24, height: 24)
        firstItem.image = icon
      }
    } else if isDefaultChrome {
      if let firstProcess = processesToDisplay.first(where: { $0.isSupported }) {
        if let bundleURL = firstProcess.bundleURL {
          let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
          icon.size = NSSize(width: 24, height: 24)
          firstItem.image = icon
        }
      } else {
        firstItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
      }
    } else {
      if let icon = getSelectedIcon() {
        icon.size = NSSize(width: 24, height: 24)
        firstItem.image = icon
      } else {
        firstItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
      }
    }
    menu.addItem(firstItem)

    let applicationsHeader = NSMenuItem()
    applicationsHeader.attributedTitle = NSAttributedString(
      string: "Applications",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    applicationsHeader.isEnabled = false
    menu.addItem(applicationsHeader)

    let allAppsItem = NSMenuItem(title: "All Applications", action: nil, keyEquivalent: "")
    allAppsItem.toolTip = "Captures audio from all applications"

    allAppsItem.image = NSImage(
      systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
    allAppsItem.representedObject = AudioSourceSelection(
      type: .process, source: AudioSource.allApplications)
    if audioManager.selections.selectedProcess?.id == "system-audio" {
      allAppsItem.state = .on
    }
    menu.addItem(allAppsItem)

    if !isDefaultChrome {
      let defaultItem = NSMenuItem(title: "Default Browser", action: nil, keyEquivalent: "")
      if let safariIcon = getSafariIcon() {
        safariIcon.size = NSSize(width: 16, height: 16)
        defaultItem.image = safariIcon
      }
      defaultItem.target = nil
      defaultItem.representedObject = AudioSourceSelection(type: .process, source: nil)
      if audioManager.selections.selectedProcess == nil {
        defaultItem.state = .on
      }
      menu.addItem(defaultItem)
    }

    if !processesToDisplay.isEmpty {
      for process in processesToDisplay {
        let item = NSMenuItem()

        if process.id == "system-audio" {
          continue
        }

        let displayName = process.name == "Safari Graphics and Media" ? "Safari" : process.name

        if !process.isSupported {
          item.attributedTitle = NSAttributedString(
            string: "\(displayName) (Unsupported)",
            attributes: [
              .foregroundColor: NSColor.disabledControlTextColor,
              .font: NSFont.systemFont(ofSize: 13),
            ]
          )
        } else {
          item.title = displayName
        }

        // Use Safari icon for GPU process
        if process.name == "Safari Graphics and Media" {
          if let safariIcon = getSafariIcon() {
            safariIcon.size = NSSize(width: 16, height: 16)
            item.image = safariIcon
          }
        } else if let bundleURL = process.bundleURL {
          let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
          icon.size = NSSize(width: 16, height: 16)
          item.image = icon
        }

        item.target = nil
        item.representedObject = AudioSourceSelection(type: .process, source: process)
        item.isEnabled = process.isSupported

        if process.id == audioManager.selections.selectedProcess?.id {
          item.state = .on
        }

        menu.addItem(item)
      }
    }

    menu.addItem(NSMenuItem.separator())

    let inputsHeader = NSMenuItem()
    inputsHeader.attributedTitle = NSAttributedString(
      string: "Input Devices",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    inputsHeader.isEnabled = false
    menu.addItem(inputsHeader)

    // Input devices...
    for input in audioManager.availableInputDevices {
      let item = NSMenuItem(title: input.name, action: nil, keyEquivalent: "")
      item.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
      item.target = nil
      item.representedObject = AudioSourceSelection(type: .inputDevice, source: input)
      if input.id == audioManager.selections.selectedInput?.id {
        item.state = .on
      }
      menu.addItem(item)
    }

    button.menu = menu
  }

  private func getSelectedIcon() -> NSImage? {
    if let selectedProcess = audioManager.selections.selectedProcess,
      let bundleURL = selectedProcess.bundleURL
    {
      return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
    return getSafariIcon()
  }

  private func getSafariIcon() -> NSImage? {
    if let safariURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.Safari")
    {
      return NSWorkspace.shared.icon(forFile: safariURL.path)
    }
    return nil
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  // Helper struct to wrap selection type and source
  private struct AudioSourceSelection {
    let type: AudioSourceType
    let source: AudioSource?
  }

  class Coordinator: NSObject {
    var parent: AudioSourceSelectorView

    init(_ parent: AudioSourceSelectorView) {
      self.parent = parent
    }

    @objc func menuAction(_ sender: NSPopUpButton) {
      guard let item = sender.selectedItem,
        let selection = item.representedObject as? AudioSourceSelection
      else { return }

      if let source = selection.source, !source.isSupported {
        return
      }

      switch selection.type {
      case .process:
        parent.onSelect(selection.source)  // nil means default browser
      case .inputDevice:
        parent.onSelect(selection.source)
      }
    }
  }
}
