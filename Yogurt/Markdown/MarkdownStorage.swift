import AppKit
import Combine

class MarkdownStorage: NSTextStorage {
  // Backing store for actual text content
  private var backingStore = NSTextStorage()

  // Parser for markdown styling
  private var markdownParser: MarkdownParser

  // Current font size
  private var currentFontSize: CGFloat

  // Debouncer for style updates
  private var updateTimer: Timer?
  private let updateDelay: TimeInterval = 0.1

  // Track edited ranges for incremental updates
  private var pendingEditedRange: NSRange?

  override var string: String {
    return backingStore.string
  }

  init(fontSize: CGFloat = TextStyle.baseFontSize) {
    self.currentFontSize = fontSize
    self.markdownParser = MarkdownParser(fontSize: fontSize)
    super.init()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  required init(itemProviderData data: Data, typeIdentifier: String) throws {
    fatalError("init(itemProviderData:typeIdentifier:) has not been implemented")
  }

  required init(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType)
  {
    fatalError("init(pasteboardPropertyList:ofType:) has not been implemented")
  }

  // MARK: - NSTextStorage Override Methods

  override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
    -> [NSAttributedString.Key: Any]
  {
    return backingStore.attributes(at: location, effectiveRange: range)
  }

  override func replaceCharacters(in range: NSRange, with str: String) {
    beginEditing()
    backingStore.replaceCharacters(in: range, with: str)

    // Calculate change in length
    let changeInLength = (str as NSString).length - range.length
    edited([.editedCharacters], range: range, changeInLength: changeInLength)

    // Track the edited range for styling
    let effectiveRange = NSRange(location: range.location, length: str.count)
    scheduleUpdateForRange(effectiveRange)

    endEditing()
  }

  override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    beginEditing()
    backingStore.setAttributes(attrs, range: range)
    edited([.editedAttributes], range: range, changeInLength: 0)
    endEditing()
  }

  // We need to override the editedRange property from NSTextStorage
  override var editedRange: NSRange {
    return pendingEditedRange ?? NSRange(location: NSNotFound, length: 0)
  }

  override var editedMask: NSTextStorageEditActions {
    return pendingEditedRange != nil ? .editedAttributes : []
  }

  // MARK: - Style Management

  func updateFontSize(_ newSize: CGFloat) {
    currentFontSize = newSize
    markdownParser.updateFontSize(newSize)
    refreshStyles()
  }

  func refreshStyles() {
    scheduleUpdateForRange(NSRange(location: 0, length: string.count))
  }

  private func scheduleUpdateForRange(_ range: NSRange) {
    // Merge with existing range if there is one
    if let existing = pendingEditedRange {
      let minLocation = min(existing.location, range.location)
      let maxEnd = max(existing.location + existing.length, range.location + range.length)
      pendingEditedRange = NSRange(location: minLocation, length: maxEnd - minLocation)
    } else {
      pendingEditedRange = range
    }

    // Debounce the update
    updateTimer?.invalidate()
    updateTimer = Timer.scheduledTimer(withTimeInterval: updateDelay, repeats: false) {
      [weak self] _ in
      self?.processUpdates()
    }
  }

  private func processUpdates() {
    guard let range = pendingEditedRange else { return }

    // Clear the tracked range
    pendingEditedRange = nil

    // Get the affected paragraph range
    let paragraphRange = string.paragraphRange(for: range)

    // Apply styles to the paragraph
    beginEditing()
    markdownParser.styleTextInRange(paragraphRange, in: self)
    endEditing()
  }
}

// MARK: - String Extension for Paragraph Range
extension String {
  func paragraphRange(for range: NSRange) -> NSRange {
    let nsString = self as NSString
    return nsString.paragraphRange(for: range)
  }
}
