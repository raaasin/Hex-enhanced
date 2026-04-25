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

  @Test
  func askStreamParserAppendsDeltaSnapshots() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.output_text.delta",
      data: #"{"type":"response.output_text.delta","delta":"Hello"}"#,
      currentText: ""
    )

    #expect(update == .snapshot("Hello"))
  }

  @Test
  func askStreamParserPrefersCompletedResponseSnapshot() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.completed",
      data: #"{"type":"response.completed","output_text":"Hello world"}"#,
      currentText: "Hello"
    )

    #expect(update == .snapshot("Hello world"))
  }

  @Test
  func askStreamParserRecognizesDoneSentinel() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: nil,
      data: "[DONE]",
      currentText: "Hello"
    )

    #expect(update == .finished)
  }
}
