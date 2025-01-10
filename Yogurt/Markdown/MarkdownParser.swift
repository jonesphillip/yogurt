import AppKit
import Markdown

class MarkdownParser {
  private var currentFontSize: CGFloat

  init(fontSize: CGFloat = TextStyle.baseFontSize) {
    self.currentFontSize = fontSize
  }

  func parseAndStyle(_ text: String, textStorage: NSTextStorage, range: NSRange? = nil) {
    // First, apply default styling to the entire range
    let defaultFont = NSFont.systemFont(ofSize: currentFontSize)
    let wholeRange = range ?? NSRange(location: 0, length: text.count)

    textStorage.setAttributes(
      [
        .font: defaultFont,
        .foregroundColor: NSColor.textColor,
      ], range: wholeRange)

    // Parse and apply markdown styling
    let document = Document(parsing: text)
    var visitor = MarkdownStylizer(
      fontSize: currentFontSize,
      textStorage: textStorage,
      text: text,
      baseRange: wholeRange.location
    )
    visitor.visit(document)
  }

  func updateFontSize(_ size: CGFloat) {
    currentFontSize = size
  }

  func styleTextInRange(_ range: NSRange, in textStorage: NSTextStorage) {
    guard let textRange = Range(range, in: textStorage.string) else { return }
    let text = String(textStorage.string[textRange])

    parseAndStyle(text, textStorage: textStorage, range: range)
  }
}

struct MarkdownStylizer: MarkupWalker {
  private var textStorage: NSTextStorage
  private var fontSize: CGFloat
  private var text: String
  private var baseRange: Int

  init(fontSize: CGFloat, textStorage: NSTextStorage, text: String, baseRange: Int = 0) {
    self.fontSize = fontSize
    self.textStorage = textStorage
    self.text = text
    self.baseRange = baseRange
  }

  mutating func visitHeading(_ heading: Heading) {
    let headingText = heading.plainText
    let headingSize = fontSize + CGFloat(6 - heading.level) * 2
    let font = NSFont.boldSystemFont(ofSize: headingSize)

    // Find the exact heading with its prefix
    let prefix = String(repeating: "#", count: heading.level)
    let fullHeadingPattern = "\(prefix)\\s+\(NSRegularExpression.escapedPattern(for: headingText))"

    // Use regex to find all occurrences
    if let regex = try? NSRegularExpression(pattern: fullHeadingPattern) {
      let range = NSRange(location: 0, length: text.count)
      regex.enumerateMatches(in: text, range: range) { match, _, _ in
        guard let match = match else { return }

        // Calculate the range of just the text portion (after the # and space)
        let markerLength = prefix.count + 1  // +1 for the space
        let textStart = match.range.location + markerLength
        let textLength = match.range.length - markerLength
        let adjustedRange = NSRange(location: textStart + baseRange, length: textLength)

        textStorage.addAttributes(
          [
            .font: font,
            .foregroundColor: NSColor.textColor,
          ], range: adjustedRange)
      }
    }

    descendInto(heading)
  }

  mutating func visitEmphasis(_ emphasis: Emphasis) {
    let emphasisText = emphasis.plainText
    guard let italicFont = NSFont.systemFont(ofSize: fontSize).withTraits(.italicFontMask) else {
      descendInto(emphasis)
      return
    }

    // Look for text surrounded by single asterisks
    let pattern = "\\*\(NSRegularExpression.escapedPattern(for: emphasisText))\\*"
    if let regex = try? NSRegularExpression(pattern: pattern) {
      let range = NSRange(location: 0, length: text.count)
      regex.enumerateMatches(in: text, range: range) { match, _, _ in
        guard let match = match else { return }

        // Get the range of just the text without the markers
        let textStart = match.range.location + 1
        let textLength = match.range.length - 2
        let adjustedRange = NSRange(location: textStart + baseRange, length: textLength)

        textStorage.addAttributes(
          [
            .font: italicFont
          ], range: adjustedRange)
      }
    }

    descendInto(emphasis)
  }

  mutating func visitStrong(_ strong: Strong) {
    let strongText = strong.plainText
    let boldFont = NSFont.boldSystemFont(ofSize: fontSize)

    // Look for text surrounded by double asterisks
    let pattern = "\\*\\*\(NSRegularExpression.escapedPattern(for: strongText))\\*\\*"
    if let regex = try? NSRegularExpression(pattern: pattern) {
      let range = NSRange(location: 0, length: text.count)
      regex.enumerateMatches(in: text, range: range) { match, _, _ in
        guard let match = match else { return }

        // Get the range of just the text without the markers
        let textStart = match.range.location + 2
        let textLength = match.range.length - 4
        let adjustedRange = NSRange(location: textStart + baseRange, length: textLength)

        textStorage.addAttributes(
          [
            .font: boldFont
          ], range: adjustedRange)
      }
    }

    descendInto(strong)
  }

  mutating func visitListItem(_ listItem: ListItem) {
    // Get text from the list item's children
    let itemText = listItem.children
      .compactMap { ($0 as? Text)?.string }
      .joined(separator: "")

    if itemText.isEmpty {
      descendInto(listItem)
      return
    }

    var searchRange = NSRange(location: 0, length: text.count)
    while let range = text.range(of: itemText, range: Range(searchRange, in: text)!) {
      let nsRange = NSRange(range, in: text)
      let adjustedRange = NSRange(location: nsRange.location + baseRange, length: nsRange.length)

      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.headIndent = TextStyle.listIndent
      paragraphStyle.firstLineHeadIndent = TextStyle.listIndent

      textStorage.addAttributes(
        [
          .paragraphStyle: paragraphStyle
        ], range: adjustedRange)

      searchRange.location = nsRange.upperBound
      searchRange.length = text.count - searchRange.location
      if searchRange.length <= 0 { break }
    }

    descendInto(listItem)
  }

  mutating func visitLink(_ link: Link) {
    let linkText = link.plainText
    let destination = link.destination ?? ""

    // Look for markdown link syntax: [text](url)
    let escapedText = NSRegularExpression.escapedPattern(for: linkText)
    let pattern = "\\[\(escapedText)\\]\\([^)]+\\)"

    if let regex = try? NSRegularExpression(pattern: pattern) {
      let range = NSRange(location: 0, length: text.count)
      regex.enumerateMatches(in: text, range: range) { match, _, _ in
        guard let match = match else { return }

        // Get the range of just the text portion (between [ and ])
        let textStart = match.range.location + 1
        let textLength = linkText.count
        let adjustedRange = NSRange(location: textStart + baseRange, length: textLength)

        if let url = URL(string: destination) {
          textStorage.addAttributes(
            [
              .foregroundColor: NSColor.linkColor,
              .underlineStyle: NSUnderlineStyle.single.rawValue,
              .cursor: NSCursor.pointingHand,
              .link: url,
            ], range: adjustedRange)
        }
      }
    }

    descendInto(link)
  }

  mutating func visitInlineCode(_ code: InlineCode) {
    let codeText = code.plainText

    guard let monospaceFont = NSFont(name: "Menlo", size: fontSize) else {
      descendInto(code)
      return
    }

    var searchRange = NSRange(location: 0, length: text.count)
    while let range = text.range(of: codeText, range: Range(searchRange, in: text)!) {
      let nsRange = NSRange(range, in: text)
      let adjustedRange = NSRange(location: nsRange.location + baseRange, length: nsRange.length)

      textStorage.addAttributes(
        [
          .font: monospaceFont,
          .backgroundColor: NSColor.textColor.withAlphaComponent(0.1),
        ], range: adjustedRange)

      searchRange.location = nsRange.upperBound
      searchRange.length = text.count - searchRange.location
      if searchRange.length <= 0 { break }
    }

    descendInto(code)
  }

  mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
    let blockText = codeBlock.code

    guard let monospaceFont = NSFont(name: "Menlo", size: fontSize) else {
      descendInto(codeBlock)
      return
    }

    var searchRange = NSRange(location: 0, length: text.count)
    while let range = text.range(of: blockText, range: Range(searchRange, in: text)!) {
      let nsRange = NSRange(range, in: text)
      let adjustedRange = NSRange(location: nsRange.location + baseRange, length: nsRange.length)

      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.headIndent = TextStyle.listIndent
      paragraphStyle.firstLineHeadIndent = TextStyle.listIndent

      textStorage.addAttributes(
        [
          .font: monospaceFont,
          .backgroundColor: NSColor.textColor.withAlphaComponent(0.1),
          .paragraphStyle: paragraphStyle,
        ], range: adjustedRange)

      searchRange.location = nsRange.upperBound
      searchRange.length = text.count - searchRange.location
      if searchRange.length <= 0 { break }
    }

    descendInto(codeBlock)
  }
}
