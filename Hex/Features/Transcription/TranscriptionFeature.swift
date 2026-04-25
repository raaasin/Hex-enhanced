//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var formatterSession: FormatterSession?
    var formatterStatusText: String?
    var formatterErrorText: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording
    case captureFormatterContext
    case formatterContextCaptured(FormatterCaptureResult)

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)
    case formatterFlowCompleted(String, URL, TimeInterval)
    case formatterFlowFailed(String, URL?)
    case formatterFlowFallbackToTranscription(String, URL, TimeInterval)
    case clearFormatterFeedback

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingCleanup
    case transcription
    case formatterContextCapture
    case formatterFeedback
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.selectionText) var selectionText
  @Dependency(\.textFormatting) var textFormatting
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      case .captureFormatterContext:
        state.formatterStatusText = "Checking selection"
        state.formatterErrorText = nil
        return captureFormatterContextEffect()

      case let .formatterContextCaptured(captureResult):
        return handleFormatterContextCaptured(&state, captureResult: captureResult)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case let .formatterFlowCompleted(formattedText, audioURL, duration):
        return handleFormatterFlowCompleted(
          &state,
          formattedText: formattedText,
          audioURL: audioURL,
          duration: duration
        )

      case let .formatterFlowFailed(reason, audioURL):
        return handleFormatterFlowFailed(&state, reason: reason, audioURL: audioURL)

      case let .formatterFlowFallbackToTranscription(result, audioURL, duration):
        return handleFormatterFlowFallbackToTranscription(
          &state,
          result: result,
          audioURL: audioURL,
          duration: duration
        )

      case .clearFormatterFeedback:
        state.formatterStatusText = nil
        state.formatterErrorText = nil
        return .none

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

extension TranscriptionFeature {
  struct FormatterSession: Equatable, Sendable {
    var originalSelection: String
  }

  struct FormatterCaptureResult: Equatable, Sendable {
    var session: FormatterSession?
    var frontmostApp: SelectionTextClient.FrontmostApp?
    var didExceedMaxLength: Bool
  }

  enum FormatterFlowError: LocalizedError, Sendable {
    case formattedReplacementFailed

    var errorDescription: String? {
      switch self {
      case .formattedReplacementFailed:
        return "Could not insert formatted text"
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Process the key event
          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            // If double-tap lock is triggered, we start recording immediately
            if hotKeyProcessor.state == .doubleTapLock {
              Task { await send(.startRecording) }
            } else {
              Task { await send(.hotKeyPressed) }
            }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording)
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    state.formatterSession = nil
    state.formatterStatusText = nil
    state.formatterErrorText = nil
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .cancel(id: CancelID.formatterFeedback),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        await recording.startRecording()
      }
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      state.formatterStatusText = nil
      state.formatterErrorText = nil
      clearFormatterSession(&state)
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return .run { _ in
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .run { [sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        let capturedURL = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        soundEffect.play(.stopRecording)
        audioURL = capturedURL

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )
        
        let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        
        transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
        await send(.transcriptionResult(result, capturedURL))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func captureFormatterContextEffect() -> Effect<Action> {
    .run { send in
      let frontmostApp = await selectionText.frontmostApp()
      let selectedText = await selectionText.captureSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)

      let captureResult: FormatterCaptureResult
      if let selectedText, !selectedText.isEmpty {
        let isWithinMaxLength = selectionText.isWithinMaxSelectedTextLength(selectedText)
        if isWithinMaxLength {
          captureResult = .init(
            session: .init(
              originalSelection: selectedText
            ),
            frontmostApp: frontmostApp,
            didExceedMaxLength: false
          )
        } else {
          captureResult = .init(
            session: nil,
            frontmostApp: frontmostApp,
            didExceedMaxLength: true
          )
        }
      } else {
        captureResult = .init(
          session: nil,
          frontmostApp: frontmostApp,
          didExceedMaxLength: false
        )
      }

      await send(.formatterContextCaptured(captureResult))
    }
    .cancellable(id: CancelID.formatterContextCapture, cancelInFlight: true)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      state.isTranscribing = false
      state.isPrewarming = false
      clearFormatterSession(&state)
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      state.isTranscribing = false
      state.isPrewarming = false
      state.formatterStatusText = nil
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    state.formatterStatusText = "Checking selection"
    state.formatterErrorText = nil

    return .run { send in
      let frontmostApp = await selectionText.frontmostApp()
      let selectedText = await selectionText.captureSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)

      let captureResult: FormatterCaptureResult
      if let selectedText, !selectedText.isEmpty {
        let isWithinMaxLength = selectionText.isWithinMaxSelectedTextLength(selectedText)
        if isWithinMaxLength {
          captureResult = .init(
            session: .init(
              originalSelection: selectedText
            ),
            frontmostApp: frontmostApp,
            didExceedMaxLength: false
          )
        } else {
          captureResult = .init(
            session: nil,
            frontmostApp: frontmostApp,
            didExceedMaxLength: true
          )
        }
      } else {
        captureResult = .init(
          session: nil,
          frontmostApp: frontmostApp,
          didExceedMaxLength: false
        )
      }

      await send(.formatterContextCaptured(captureResult))

      guard let formatterSession = captureResult.session else {
        await send(.formatterFlowFallbackToTranscription(result, audioURL, duration))
        return
      }

      transcriptionFeatureLogger.notice("Formatter context captured post-transcription; treating transcript as instruction")

      let instruction = result.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !instruction.isEmpty else {
        await send(.formatterFlowFallbackToTranscription(result, audioURL, duration))
        return
      }

      do {
        let formatted = try await textFormatting.format(
          formatterSession.originalSelection,
          instruction
        )

        let didReplaceSelection = await selectionText.replaceSelectedText(formatted)
        if !didReplaceSelection {
          throw FormatterFlowError.formattedReplacementFailed
        }

        transcriptionFeatureLogger.notice("Formatting flow completed with output length \(formatted.count)")
        await send(.formatterFlowCompleted(formatted, audioURL, duration))
      } catch {
        transcriptionFeatureLogger.error("Formatting flow failed: \(error.localizedDescription)")
        await send(.formatterFlowFailed(condensedFormatterError(error), audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleFormatterFlowFallbackToTranscription(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    finalizeStandardTranscription(
      &state,
      result: result,
      audioURL: audioURL,
      duration: duration
    )
  }

  func handleFormatterContextCaptured(
    _ state: inout State,
    captureResult: FormatterCaptureResult
  ) -> Effect<Action> {
    if let frontmostApp = captureResult.frontmostApp {
      state.sourceAppBundleID = frontmostApp.bundleIdentifier
      state.sourceAppName = frontmostApp.localizedName
    }

    if captureResult.didExceedMaxLength {
      state.formatterSession = nil
      state.formatterStatusText = nil
      state.formatterErrorText = "Selected text is too long to format.\nSelect a shorter passage and try again."
      transcriptionFeatureLogger.notice(
        "Skipping formatter arming because selected text exceeded max length"
      )
      return .none
    }

    state.formatterSession = captureResult.session
    state.formatterStatusText = captureResult.session == nil ? nil : "Formatter armed"
    state.formatterErrorText = nil
    return .none
  }

  func handleFormatterFlowCompleted(
    _ state: inout State,
    formattedText: String,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = nil
    state.formatterStatusText = nil
    state.formatterErrorText = nil
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    clearFormatterSession(&state)

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: formattedText,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          shouldPasteResult: false
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleFormatterFlowFailed(
    _ state: inout State,
    reason: String,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = reason
    state.formatterStatusText = nil
    state.formatterErrorText = reason
    clearFormatterSession(&state)

    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }
    return .run { send in
      try? await Task.sleep(for: .seconds(4))
      await send(.clearFormatterFeedback)
    }
    .cancellable(id: CancelID.formatterFeedback, cancelInFlight: true)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    state.formatterStatusText = nil
    state.formatterErrorText = nil
    clearFormatterSession(&state)
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>,
    shouldPasteResult: Bool = true
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    if shouldPasteResult {
      await pasteboard.paste(result)
    }
    soundEffect.play(.pasteTranscript)
  }

  func clearFormatterSession(_ state: inout State) {
    state.formatterSession = nil
  }

  func finalizeStandardTranscription(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.formatterStatusText = nil
    state.formatterErrorText = nil

    transcriptionFeatureLogger.info("Raw transcription: '\(result)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      clearFormatterSession(&state)
      return .none
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    clearFormatterSession(&state)

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func condensedFormatterError(_ error: Error) -> String {
    if let formattingError = error as? TextFormattingClientError,
       let description = formattingError.errorDescription
    {
      return description
    }

    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "Formatting failed" : message
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.formatterStatusText = nil
    state.formatterErrorText = nil
    clearFormatterSession(&state)

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.formatterContextCapture),
      .cancel(id: CancelID.formatterFeedback),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.formatterStatusText = nil
    state.formatterErrorText = nil
    clearFormatterSession(&state)

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.formatterContextCapture),
      .cancel(id: CancelID.formatterFeedback),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      if store.formatterSession != nil {
        return .formatting
      }
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.formatterSession != nil {
      return .formatterArmed
    } else if store.formatterErrorText != nil {
      return .formatterArmed
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter,
      errorText: store.formatterErrorText
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
