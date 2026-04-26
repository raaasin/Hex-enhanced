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
  func askStreamParserIgnoresCreatedBookkeepingEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.created",
      data: #"{"type":"response.created","response":{"id":"resp_123"}}"#,
      currentText: ""
    )

    #expect(update == nil)
  }

  @Test
  func askStreamParserIgnoresInProgressBookkeepingEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.in_progress",
      data: #"{"type":"response.in_progress","response":{"id":"resp_123","status":"in_progress"}}"#,
      currentText: ""
    )

    #expect(update == nil)
  }

  @Test
  func askStreamParserIgnoresOutputItemAddedBookkeepingEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.output_item.added",
      data: #"{"type":"response.output_item.added","item":{"content":[{"type":"output_text","text":"Hello world"}]}}"#,
      currentText: "Hello"
    )

    #expect(update == nil)
  }

  @Test
  func askStreamParserIgnoresEmptyContentPartAddedEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.content_part.added",
      data: #"{"type":"response.content_part.added","part":{"type":"output_text","text":""}}"#,
      currentText: "Hello"
    )

    #expect(update == nil)
  }

  @Test
  func askStreamParserReadsOutputTextPartDoneEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.content_part.done",
      data: #"{"type":"response.content_part.done","part":{"type":"output_text","text":"Hello world"}}"#,
      currentText: "Hello"
    )

    #expect(update == .snapshot("Hello world"))
  }

  @Test
  func askStreamParserReadsOutputTextDoneEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.output_text.done",
      data: #"{"type":"response.output_text.done","text":"Hello world"}"#,
      currentText: "Hello"
    )

    #expect(update == .snapshot("Hello world"))
  }

  @Test
  func askStreamParserReadsOutputItemDoneEvent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.output_item.done",
      data: #"{"type":"response.output_item.done","item":{"content":[{"type":"output_text","text":"Hello world"}]}}"#,
      currentText: "Hello"
    )

    #expect(update == .snapshot("Hello world"))
  }

  @Test
  func askStreamParserReadsCompletedResponseOutputContent() {
    let update = TextFormattingClientLive.parseAskStreamEvent(
      eventName: "response.completed",
      data: #"{"type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"Hello world"}]}]}}"#,
      currentText: "Hello"
    )

    #expect(update == .snapshot("Hello world"))
  }

  @Test
  func askStreamFramingDispatchesWithoutBlankSeparators() {
    let snapshots = replayAskStreamLines([
      "event: response.output_text.delta",
      #"data: {"type":"response.output_text.delta","delta":"Hello"}"#,
      "event: response.output_text.delta",
      #"data: {"type":"response.output_text.delta","delta":" world"}"#,
      "event: response.completed",
      #"data: {"type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"Hello world"}]}]}}"#,
    ])

    #expect(snapshots == ["Hello", "Hello world"])
  }

  @Test
  func askStreamFramingPreservesCompletedSentinelWithoutBlankSeparators() {
    let snapshots = replayAskStreamLines([
      "event: response.output_text.delta",
      #"data: {"type":"response.output_text.delta","delta":"Hello"}"#,
      "event: response.completed",
      #"data: {"type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"Hello"}]}]}}"#,
    ])

    #expect(snapshots == ["Hello"])
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

  @Test
  func sseLineNormalizationStripsCRFromCRLFLine() {
    #expect(TextFormattingClientLive.normalizedSSELine("event: response.created\r") == "event: response.created")
    #expect(TextFormattingClientLive.normalizedSSELine("\r").isEmpty)
  }

  @Test
  func sseFieldValueTrimsOptionalSpaceAndCRLFRemainder() {
    #expect(
      TextFormattingClientLive.sseFieldValue(in: "event: response.completed\r", prefix: "event:")
        == "response.completed"
    )
    #expect(
      TextFormattingClientLive.sseFieldValue(in: "data: [DONE]\r", prefix: "data:")
        == "[DONE]"
    )
  }

  @Test
  func askEmptyResponseDescriptionIncludesDiagnostics() {
    let error = TextFormattingClientError.emptyResponse(
      debugContext: "event=response.completed accumulatedLen=0 data={\"output\":[]}"
    )

    #expect(
      error.errorDescription == "The text formatting provider returned no formatted text.\n\nAsk stream diagnostics:\nevent=response.completed accumulatedLen=0 data={\"output\":[]}"
    )
  }

  @Test
  func nonAskTransportFailureDescriptionStaysConcise() {
    let error = TextFormattingClientError.transportFailure("timed out")

    #expect(error.errorDescription == "Could not reach the text formatting provider. timed out")
  }

  private func replayAskStreamLines(_ rawLines: [String]) -> [String] {
    var snapshots: [String] = []
    var accumulatedText = ""
    var eventName: String?
    var dataLines: [String] = []

    func dispatchBufferedEvent() {
      let payload = dataLines.joined(separator: "\n")
      let update = TextFormattingClientLive.parseAskStreamEvent(
        eventName: eventName,
        data: payload,
        currentText: accumulatedText
      )

      if case let .snapshot(snapshot) = update {
        accumulatedText = snapshot
        snapshots.append(snapshot)
      }

      eventName = nil
      dataLines.removeAll(keepingCapacity: true)
    }

    for rawLine in rawLines {
      let line = TextFormattingClientLive.normalizedSSELine(rawLine)

      if line.trimmed.isEmpty {
        dispatchBufferedEvent()
        continue
      }

      if line.hasPrefix(":") {
        continue
      }

      if line.hasPrefix("event:") {
        if eventName != nil || !dataLines.isEmpty {
          dispatchBufferedEvent()
        }
        eventName = TextFormattingClientLive.sseFieldValue(in: line, prefix: "event:")
        continue
      }

      if line.hasPrefix("data:") {
        dataLines.append(TextFormattingClientLive.sseFieldValue(in: line, prefix: "data:"))
      }
    }

    dispatchBufferedEvent()
    return snapshots
  }
}
