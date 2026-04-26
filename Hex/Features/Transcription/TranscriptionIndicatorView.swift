//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.

import AppKit
import Inject
import MarkdownUI
import Pow
import SwiftUI

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject
  
  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case askRecording
    case askThinking
    case askAnswer
    case askError
    case formatterArmed
    case formatting
    case prewarming
  }

  var status: Status
  var meter: Meter
  var errorText: String?
  var askText: String?

  let transcribeBaseColor: Color = .blue
  let formatterBaseColor: Color = .orange
  let askBaseColor: Color = .purple
  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return .red.mix(with: .black, by: 0.5).mix(with: .red, by: meter.averagePower * 3)
    case .transcribing: return transcribeBaseColor.mix(with: .black, by: 0.5)
    case .askRecording: return askBaseColor.mix(with: .black, by: 0.35).mix(with: askBaseColor, by: meter.averagePower * 2)
    case .askThinking, .askAnswer, .askError: return askBaseColor.mix(with: .black, by: 0.4)
    case .formatterArmed: return formatterBaseColor.mix(with: .black, by: 0.45)
    case .formatting: return formatterBaseColor.mix(with: .black, by: 0.45)
    case .prewarming: return transcribeBaseColor.mix(with: .black, by: 0.5)
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return Color.red.mix(with: .white, by: 0.1).opacity(0.6)
    case .transcribing: return transcribeBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    case .askRecording, .askThinking, .askAnswer, .askError: return askBaseColor.mix(with: .white, by: 0.15).opacity(0.7)
    case .formatterArmed: return formatterBaseColor.mix(with: .white, by: 0.1).opacity(0.65)
    case .formatting: return formatterBaseColor.mix(with: .white, by: 0.1).opacity(0.65)
    case .prewarming: return transcribeBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    }
  }

  private var innerShadowColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.clear
    case .recording: return Color.red
    case .transcribing: return transcribeBaseColor
    case .askRecording, .askThinking, .askAnswer, .askError: return askBaseColor
    case .formatterArmed: return formatterBaseColor
    case .formatting: return formatterBaseColor
    case .prewarming: return transcribeBaseColor
    }
  }

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56
  private let askCardMinWidth: CGFloat = 300
  private let askCardMaxWidth: CGFloat = 420
  private let askCardHeight: CGFloat = 180

  private var bubbleText: String? {
    if let askText, isAskStatus, hasVisibleAskText {
      return askText
    }
    if let errorText {
      return errorText
    }
    if status == .prewarming {
      return "Model prewarming..."
    }
    return nil
  }

  private var modeSymbolName: String? {
    switch status {
    case .askRecording, .askThinking, .askAnswer, .askError:
      return "bubble.left.and.exclamationmark.bubble.right.fill"
    case .formatterArmed:
      return "wand.and.stars"
    case .formatting:
      return "sparkles"
    default:
      return nil
    }
  }

  private var modeSymbolColor: Color {
    isAskStatus ? askBaseColor.mix(with: .white, by: 0.65) : formatterBaseColor.mix(with: .white, by: 0.65)
  }

  private var bubbleBackground: Color {
    if status == .askError {
      return askBaseColor.mix(with: .black, by: 0.55).opacity(0.95)
    }
    if isAskStatus {
      return askBaseColor.mix(with: .black, by: 0.65).opacity(0.96)
    }
    return errorText == nil ? Color.black.opacity(0.82) : Color.red.mix(with: .black, by: 0.6).opacity(0.95)
  }

  private var isAskStatus: Bool {
    switch status {
    case .askRecording, .askThinking, .askAnswer, .askError:
      return true
    default:
      return false
    }
  }

  private var currentVisibleFrame: CGRect {
    NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) })?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
  }

  private var askCardWidth: CGFloat {
    min(askCardMaxWidth, max(askCardMinWidth, currentVisibleFrame.width - 80))
  }

  private var hasVisibleAskText: Bool {
    guard let askText else { return false }
    return !askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var showsAskCardOnly: Bool {
    isAskStatus && (status == .askError || hasVisibleAskText)
  }

  var isHidden: Bool {
    status == .hidden
  }

  @State var transcribeEffect = 0

  var body: some View {
    let averagePower = min(1, meter.averagePower * 3)
    let peakPower = min(1, meter.peakPower * 3)
    ZStack {
      if !showsAskCardOnly {
        Capsule()
          .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
          .overlay {
            Capsule()
              .stroke(strokeColor, lineWidth: 1)
              .blendMode(.screen)
          }
          .overlay(alignment: .center) {
              RoundedRectangle(cornerRadius: cornerRadius)
                .fill((isAskStatus ? askBaseColor : .red).opacity(status == .recording || status == .askRecording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0))
                .blur(radius: 2)
                .blendMode(.screen)
                .padding(6)
          }
          .overlay(alignment: .center) {
              RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(status == .recording || status == .askRecording ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0))
                .blur(radius: 1)
              .blendMode(.screen)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(7)
          }
          .overlay(alignment: .center) {
            GeometryReader { proxy in
              RoundedRectangle(cornerRadius: cornerRadius)
                .fill((isAskStatus ? askBaseColor : .red).opacity(status == .recording || status == .askRecording ? (peakPower < 0.1 ? (peakPower / 0.1) * 0.5 : 0.5) : 0))
                .frame(width: max(proxy.size.width * (peakPower + 0.6), 0), height: proxy.size.height, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
                .blur(radius: 4)
                .blendMode(.screen)
            }.padding(6)
          }
          .cornerRadius(cornerRadius)
          .shadow(
            color: (status == .recording || status == .askRecording) ? (isAskStatus ? askBaseColor : .red).opacity(averagePower) : .red.opacity(0),
            radius: 4
          )
          .shadow(
            color: (status == .recording || status == .askRecording) ? (isAskStatus ? askBaseColor : .red).opacity(averagePower * 0.5) : .red.opacity(0),
            radius: 8
          )
          .animation(.interactiveSpring(), value: meter)
          .frame(
            width: status == .recording || status == .askRecording ? expandedWidth : status == .formatting || status == .askThinking ? 24 : 16,
            height: baseWidth
          )
          .opacity(status == .hidden ? 0 : 1)
          .scaleEffect(status == .hidden ? 0.0 : 1)
          .blur(radius: status == .hidden ? 4 : 0)
          .animation(.bouncy(duration: 0.3), value: status)
          .changeEffect(.glow(color: (isAskStatus ? askBaseColor : .red).opacity(0.5), radius: 8), value: status)
          .changeEffect(.shine(angle: .degrees(0), duration: 0.6), value: transcribeEffect)
          .compositingGroup()
          .task(id: status == .transcribing || status == .formatting || status == .askThinking) {
            while (status == .transcribing || status == .formatting || status == .askThinking), !Task.isCancelled {
              transcribeEffect += 1
              try? await Task.sleep(for: .seconds(0.25))
            }
          }
      }

      if !showsAskCardOnly, let modeSymbolName {
        Image(systemName: modeSymbolName)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(modeSymbolColor)
          .opacity(status == .formatting ? 0.95 : 0.8)
          .scaleEffect(status == .formatting ? 1.02 : 1)
          .allowsHitTesting(false)
      }
      
      if status != .hidden, let bubbleText {
        Group {
          if isAskStatus {
            ScrollView(.vertical, showsIndicators: true) {
              if status == .askError {
                Text(bubbleText)
                  .font(.system(size: 12, weight: .medium, design: .monospaced))
                  .foregroundColor(.white)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .multilineTextAlignment(.leading)
                  .textSelection(.enabled)
              } else {
                askMarkdownBody(bubbleText)
              }
            }
            .frame(width: askCardWidth, height: askCardHeight, alignment: .top)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(bubbleBackground))
          } else {
            Text(bubbleText)
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(.white)
              .multilineTextAlignment(.leading)
              .lineLimit(3)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                RoundedRectangle(cornerRadius: 6)
                  .fill(bubbleBackground)
              )
              .frame(maxWidth: 240, alignment: .leading)
          }
        }
          .offset(x: isAskStatus ? 0 : 14, y: isAskStatus ? -112 : -26)
          .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
          .zIndex(2)
      }
    }
    .enableInjection()
  }

  @ViewBuilder
  private func askMarkdownBody(_ text: String) -> some View {
    Markdown(text)
      .markdownTheme(.askOverlay)
      .frame(maxWidth: .infinity, alignment: .leading)
      .multilineTextAlignment(.leading)
  }
}

private extension Theme {
  static let askOverlay = Theme()
    .text {
      ForegroundColor(.white.opacity(0.95))
      FontSize(13)
    }
    .strong {
      FontWeight(.semibold)
      ForegroundColor(.white)
    }
    .emphasis {
      FontStyle(.italic)
      ForegroundColor(.white.opacity(0.95))
    }
    .link {
      ForegroundColor(.purple.mix(with: .white, by: 0.75))
    }
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.9))
      ForegroundColor(.white.opacity(0.95))
      BackgroundColor(.white.opacity(0.12))
    }
    .paragraph { configuration in
      configuration.label
        .relativeLineSpacing(.em(0.2))
        .markdownMargin(top: 0, bottom: 10)
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: .em(0.15))
    }
    .blockquote { configuration in
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.white.opacity(0.28))
          .frame(width: 3)

        configuration.label
      }
      .padding(.vertical, 2)
    }
}

#Preview("HEX") {
  VStack(spacing: 8) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0), errorText: nil, askText: nil)
    TranscriptionIndicatorView(status: .optionKeyPressed, meter: .init(averagePower: 0, peakPower: 0), errorText: nil, askText: nil)
    TranscriptionIndicatorView(status: .formatterArmed, meter: .init(averagePower: 0, peakPower: 0), errorText: nil, askText: nil)
    TranscriptionIndicatorView(status: .formatting, meter: .init(averagePower: 0, peakPower: 0), errorText: nil, askText: nil)
    TranscriptionIndicatorView(status: .askAnswer, meter: .init(averagePower: 0, peakPower: 0), errorText: nil, askText: "A short Ask answer stays in the purple card with markdown support.")
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0), errorText: "Selected text is too long to format.\nSelect a shorter passage and try again.", askText: nil)
  }
  .padding(40)
}
