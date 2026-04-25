import Foundation
import Testing

@testable import Hex

struct TextFormattingSanitizerTests {
  @Test
  func stripsSingleOuterFencedBlockWithLanguage() {
    let value = "```swift\nprint(\"hello\")\n```"

    #expect(
      TextFormattingClientLive.sanitizeOuterMarkdownFence(in: value)
        == "print(\"hello\")"
    )
  }

  @Test
  func stripsSingleOuterFencedBlockWithoutLanguage() {
    let value = "```\nline 1\nline 2\n```"

    #expect(
      TextFormattingClientLive.sanitizeOuterMarkdownFence(in: value)
        == "line 1\nline 2"
    )
  }

  @Test
  func keepsMixedProseAndFenceUnchanged() {
    let value = "Use this:\n```swift\nprint(\"hello\")\n```"

    #expect(TextFormattingClientLive.sanitizeOuterMarkdownFence(in: value) == value)
  }

  @Test
  func keepsInlineBackticksUnchanged() {
    let value = "Use `print(\"hello\")` in Swift."

    #expect(TextFormattingClientLive.sanitizeOuterMarkdownFence(in: value) == value)
  }

  @Test
  func stripsOuterFenceWithCRLFLineEndings() {
    let value = "```swift\r\nprint(\"hello\")\r\n```"

    #expect(
      TextFormattingClientLive.sanitizeOuterMarkdownFence(in: value)
        == "print(\"hello\")"
    )
  }

  @Test
  func keepsTextWithMultipleFenceBoundariesUnchanged() {
    let value = "```swift\nprint(\"hello\")\n```\nextra\n```"

    #expect(TextFormattingClientLive.sanitizeOuterMarkdownFence(in: value) == value)
  }
}
