import AppKit
import SwiftUI

struct MarkdownEditor: View {
  @Binding var text: String
  @State private var fontSize: CGFloat = 16
  let noteId: String

  @Binding var textViewRef: TextViewReference

  var body: some View {
    MarkdownTextContainer(
      text: $text, fontSize: fontSize,
      noteId: noteId,
      onTextViewCreated: { tv in
        textViewRef.textView = tv
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

class TextViewReference {
  var textView: MarkdownTextView?
}

struct TextStyle {
  static let listIndent: CGFloat = 20
  static let baseFontSize: CGFloat = 16
}

struct MarkdownTextContainer: NSViewRepresentable {
  @Binding var text: String
  var fontSize: CGFloat
  var noteId: String
  var onTextViewCreated: ((MarkdownTextView) -> Void)? = nil

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder

    scrollView.drawsBackground = true
    scrollView.autoresizingMask = [.width, .height]
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)

    let containerSize = NSSize(
      width: scrollView.frame.width,
      height: CGFloat.greatestFiniteMagnitude
    )
    let textContainer = NSTextContainer(containerSize: containerSize)
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)

    let textView = MarkdownTextView(frame: .zero, textContainer: textContainer)
    textView.noteId = noteId
    textView.font = .systemFont(ofSize: fontSize)
    textView.string = text
    textView.styleText()
    textView.delegate = context.coordinator
    textView.textContainerInset = NSSize(width: 10, height: 10)

    textView.isRichText = true
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
    textView.textColor = .textColor

    scrollView.documentView = textView

    onTextViewCreated?(textView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? MarkdownTextView else { return }

    // Force refresh if note ID changed
    if textView.noteId != noteId {
      textView.noteId = noteId
      textView.string = ""

      // Set content and force style in the next run loop
      DispatchQueue.main.async {
        textView.string = text
        textView.forceStyleText()
      }
      return
    }

    // Regular update for same note
    if textView.string != text {
      // Reset to default state before setting new content
      let defaultFont = NSFont.systemFont(ofSize: TextStyle.baseFontSize)
      textView.typingAttributes = [
        .font: defaultFont,
        .foregroundColor: NSColor.textColor,
      ]

      // Set new content
      textView.string = text

      // Set cursor to beginning of note
      textView.setSelectedRange(NSRange(location: 0, length: 0))

      // Apply styling
      DispatchQueue.main.async {
        textView.forceStyleText()
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
}

class MarkdownTextView: NSTextView, NSTextViewDelegate {
  private var currentFontSize: CGFloat = TextStyle.baseFontSize
  var noteId: String = ""

  override init(frame: NSRect, textContainer: NSTextContainer?) {
    // Create the storage first
    let storage = MarkdownStorage(fontSize: TextStyle.baseFontSize)

    // Create a layout manager
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)

    // Create a text container if none provided
    let container = textContainer ?? NSTextContainer(containerSize: frame.size)
    container.widthTracksTextView = true
    layoutManager.addTextContainer(container)

    super.init(frame: frame, textContainer: container)
    setupTextView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupTextView()
  }

  private func setupTextView() {
    isRichText = true
    isEditable = true
    isSelectable = true
    allowsUndo = true
    isAutomaticQuoteSubstitutionEnabled = true
    isAutomaticLinkDetectionEnabled = true
    textContainerInset = NSSize(width: 5, height: 5)

    delegate = self
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    if let url = link as? URL {
      NSWorkspace.shared.open(url)
      return true
    }
    return false
  }

  func updateFontSize(_ newSize: CGFloat) {
    currentFontSize = newSize
    guard let storage = textStorage as? MarkdownStorage else { return }
    storage.updateFontSize(newSize)
  }

  override func paste(_ sender: Any?) {
    super.paste(sender)
    refreshStyles()
  }

  func refreshStyles() {
    guard let storage = textStorage as? MarkdownStorage else { return }
    storage.refreshStyles()
  }
  func forceStyleText() {
    refreshStyles()
  }

  func styleText() {
    refreshStyles()
  }

  override func insertNewline(_ sender: Any?) {
    let currentLine = currentLineRange()
    let lineText = (string as NSString).substring(with: currentLine)

    // Check if we're in a list item
    let (marker, number) = extractListMarker(from: lineText)
    if !marker.isEmpty {
      let markerLength = marker.count + 1  // +1 for the space after marker
      let contentStart = lineText.index(lineText.startIndex, offsetBy: markerLength)
      let content = String(lineText[contentStart...]).trimmingCharacters(
        in: .whitespacesAndNewlines)

      if content.isEmpty {
        // Empty list item - remove the marker from current line
        let emptyRange = NSRange(location: currentLine.location, length: markerLength)
        textStorage?.replaceCharacters(in: emptyRange, with: "")
      } else {
        // Create new list item with incremented number if ordered list
        let newMarker: String
        if let number = number {
          newMarker = "\(number + 1). "
        } else {
          newMarker = "\(marker) "
        }
        insertText("\n\(newMarker)", replacementRange: selectedRange())
      }
    } else {
      super.insertNewline(sender)
    }
  }

  private func extractListMarker(from line: String) -> (marker: String, number: Int?) {
    // Check for unordered list markers
    if line.hasPrefix("- ") {
      return ("-", nil)
    }
    if line.hasPrefix("* ") {
      return ("*", nil)
    }

    let trimmed = line.trimmingCharacters(in: .whitespaces)

    // Check for ordered list (numbers)
    let pattern = "^(\\d+)\\."
    if let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.count))
    {
      let nsString = trimmed as NSString
      let numberStr = nsString.substring(with: match.range(at: 1))
      if let number = Int(numberStr) {
        return ("\(number).", number)
      }
    }

    return ("", nil)  // Empty marker indicates no list
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command) {
      switch event.charactersIgnoringModifiers {
      case "=", "+":
        updateFontSize(min(currentFontSize + 2, 32))
        return true
      case "-" where !event.modifierFlags.contains(.shift):
        updateFontSize(max(currentFontSize - 2, 10))
        return true
      case "0":
        updateFontSize(TextStyle.baseFontSize)
        return true
      case "b":
        toggleStyle("**")
        return true
      case "i":
        toggleStyle("*")
        return true
      case "-" where event.modifierFlags.contains(.shift):
        insertText("- ", replacementRange: currentLineRange())
        return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  private func toggleStyle(_ marker: String) {
    guard let selectedRange = selectedRanges.first as? NSRange else { return }
    let selectedText = (string as NSString).substring(with: selectedRange)
    insertText("\(marker)\(selectedText)\(marker)", replacementRange: selectedRange)
  }

  private func currentLineRange() -> NSRange {
    return (string as NSString).lineRange(for: selectedRange())
  }
}

extension NSFont {
  func withTraits(_ traits: NSFontTraitMask) -> NSFont? {
    guard let familyName = familyName else { return nil }
    return NSFontManager.shared.font(
      withFamily: familyName,
      traits: traits,
      weight: 0,
      size: pointSize)
  }
}

class Coordinator: NSObject, NSTextViewDelegate {
  var parent: MarkdownTextContainer

  init(_ parent: MarkdownTextContainer) {
    self.parent = parent
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? MarkdownTextView else { return }
    parent.text = textView.string
  }
}
