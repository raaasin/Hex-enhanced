import Foundation

enum TextFormattingPromptBuilder {
  static let systemPrompt = """
  You are an expert writing assistant.
  Rewrite text according to the user instruction while preserving the original intent.
  Keep any factual details unless the instruction explicitly asks to change them.
  Return only the rewritten text, with no preamble.
  strictly do not use double dashes and always return naturally written text, unless formal is specificed.
  if prompted for a code rewrite do not return in code blocks or with extra imports be strictly concise.
  """

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
