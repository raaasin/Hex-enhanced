import Foundation
import HexCore

enum TextFormattingPromptBuilder {
  static var systemPrompt: String {
    HexSettings.defaultTextFormattingPrompt
  }

  static func userPrompt(original: String, instruction: String) -> String {
    """
    Apply the instruction to the original selected text.

    Instruction:
    \(instruction)

    Original selected text:
    \(original)
    """
  }
}
