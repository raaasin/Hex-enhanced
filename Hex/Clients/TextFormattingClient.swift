import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let textFormattingLogger = HexLog.app

@DependencyClient
struct TextFormattingClient: Sendable {
  struct Configuration: Equatable, Sendable {
    var model: String = "grok-4-1-fast-non-reasoning"
    var baseURL: URL = URL(string: "https://api.x.ai/v1")!
    var timeout: Duration = .seconds(120)
    var maxOutputTokens: Int = 4096
  }

  var format: @Sendable (_ original: String, _ instruction: String) async throws -> String
  var loadAPIKey: @Sendable () async throws -> String
  var configuration: @Sendable () -> Configuration = { .init() }
}

extension TextFormattingClient: DependencyKey {
  static let liveValue: Self = {
    let live = TextFormattingClientLive()
    return Self(
      format: { original, instruction in
        try await live.format(original: original, instruction: instruction)
      },
      loadAPIKey: {
        try await live.loadAPIKey()
      },
      configuration: {
        live.configuration
      }
    )
  }()

  static let testValue = Self(
    format: { _, _ in "" },
    loadAPIKey: { "" },
    configuration: { .init() }
  )
}

extension DependencyValues {
  var textFormatting: TextFormattingClient {
    get { self[TextFormattingClient.self] }
    set { self[TextFormattingClient.self] = newValue }
  }
}

enum TextFormattingClientError: LocalizedError, Equatable {
  case missingAPIKey
  case invalidBaseURL(String)
  case transportFailure(String)
  case serverError(statusCode: Int, message: String?)
  case invalidResponse
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "No API key found. Set XAI_API_KEY (or OPENAI_API_KEY) in your environment or ~/.zshrc."
    case let .invalidBaseURL(value):
      return "The text formatting service URL is invalid: \(value)."
    case let .transportFailure(message):
      return "Could not reach xAI. \(message)"
    case let .serverError(statusCode, message):
      if let message, !message.isEmpty {
        return "xAI returned an error (\(statusCode)): \(message)"
      }
      return "xAI returned an error (\(statusCode))."
    case .invalidResponse:
      return "Received an invalid response from xAI."
    case .emptyResponse:
      return "xAI returned no formatted text."
    }
  }
}

actor TextFormattingClientLive {
  let configuration = TextFormattingClient.Configuration()

  private let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    return URLSession(configuration: configuration)
  }()

  func format(original: String, instruction: String) async throws -> String {
    let apiKey = try await loadAPIKey()
    let endpoint = try responsesEndpointURL()

    textFormattingLogger.info(
      "Formatting request model=\(self.configuration.model, privacy: .public) originalLength=\(original.count) instructionLength=\(instruction.count)"
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = self.configuration.timeout.timeInterval
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    request.httpBody = try JSONSerialization.data(
      withJSONObject: makeRequestBody(original: original, instruction: instruction)
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch {
      throw TextFormattingClientError.transportFailure(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TextFormattingClientError.invalidResponse
    }

    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw TextFormattingClientError.serverError(
        statusCode: httpResponse.statusCode,
        message: parseErrorMessage(from: data)
      )
    }

    let jsonObject = try JSONSerialization.jsonObject(with: data)
    guard let responseObject = jsonObject as? [String: Any] else {
      throw TextFormattingClientError.invalidResponse
    }

    guard let formatted = parseFormattedText(from: responseObject), !formatted.isEmpty else {
      throw TextFormattingClientError.emptyResponse
    }

    textFormattingLogger.debug("Formatting response length=\(formatted.count)")
    return formatted
  }

  func loadAPIKey() async throws -> String {
    if let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"]?.trimmedNonEmpty {
      return envKey
    }

    if let fallbackEnvKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmedNonEmpty {
      return fallbackEnvKey
    }

    if let zshKey = try loadAPIKeyFromZshrc() {
      return zshKey
    }

    throw TextFormattingClientError.missingAPIKey
  }

  private func makeRequestBody(original: String, instruction: String) -> [String: Any] {
    [
      "model": self.configuration.model,
      "input": [
        [
          "role": "system",
          "content": [
            [
              "type": "input_text",
              "text": TextFormattingPromptBuilder.systemPrompt,
            ]
          ],
        ],
        [
          "role": "user",
          "content": [
            [
              "type": "input_text",
              "text": TextFormattingPromptBuilder.userPrompt(original: original, instruction: instruction),
            ]
          ],
        ],
      ],
      "tools": [
        ["type": "web_search"],
        ["type": "x_search"],
      ],
      "max_output_tokens": self.configuration.maxOutputTokens,
    ]
  }

  private func responsesEndpointURL() throws -> URL {
    guard var components = URLComponents(url: self.configuration.baseURL, resolvingAgainstBaseURL: false)
    else {
      throw TextFormattingClientError.invalidBaseURL(self.configuration.baseURL.absoluteString)
    }

    let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = "/\(trimmedPath)/responses".replacingOccurrences(of: "//", with: "/")

    guard let url = components.url else {
      throw TextFormattingClientError.invalidBaseURL(self.configuration.baseURL.absoluteString)
    }

    return url
  }

  private func parseErrorMessage(from data: Data) -> String? {
    guard
      let jsonObject = try? JSONSerialization.jsonObject(with: data),
      let responseObject = jsonObject as? [String: Any]
    else { return nil }

    if let error = responseObject["error"] as? [String: Any],
       let message = error["message"] as? String
    {
      return message
    }

    if let message = responseObject["message"] as? String {
      return message
    }

    return nil
  }

  private func parseFormattedText(from response: [String: Any]) -> String? {
    if let outputText = response["output_text"] as? String, !outputText.trimmed.isEmpty {
      return outputText.trimmed
    }

    if let outputTextArray = response["output_text"] as? [String] {
      let text = outputTextArray.joined(separator: "\n").trimmed
      if !text.isEmpty { return text }
    }

    if let output = response["output"] as? [[String: Any]] {
      let fragments = output.flatMap { item in
        extractContentFragments(from: item["content"])
      }
      let text = fragments.joined(separator: "\n").trimmed
      if !text.isEmpty { return text }
    }

    if let choices = response["choices"] as? [[String: Any]] {
      let fragments = choices.flatMap { choice -> [String] in
        guard let message = choice["message"] as? [String: Any] else { return [] }

        if let contentString = message["content"] as? String {
          return [contentString]
        }

        return extractContentFragments(from: message["content"])
      }

      let text = fragments.joined(separator: "\n").trimmed
      if !text.isEmpty { return text }
    }

    return nil
  }

  private func extractContentFragments(from content: Any?) -> [String] {
    guard let content else { return [] }

    if let stringValue = content as? String {
      return [stringValue]
    }

    guard let contentItems = content as? [Any] else { return [] }

    var fragments: [String] = []

    for item in contentItems {
      guard let dictionary = item as? [String: Any] else { continue }

      if let text = dictionary["text"] as? String {
        fragments.append(text)
        continue
      }

      if let textObject = dictionary["text"] as? [String: Any],
         let value = textObject["value"] as? String
      {
        fragments.append(value)
      }
    }

    return fragments
  }

  private func loadAPIKeyFromZshrc() throws -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [
      "-lc",
      "source ~/.zshrc >/dev/null 2>&1; print -r -- ${XAI_API_KEY:-${OPENAI_API_KEY:-}}",
    ]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      textFormattingLogger.debug("Failed to source ~/.zshrc for API key: \(error.localizedDescription, privacy: .public)")
      return nil
    }

    guard process.terminationStatus == 0 else {
      return nil
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8)?.trimmedNonEmpty else {
      return nil
    }

    return output
  }

}

private extension Duration {
  var timeInterval: TimeInterval {
    TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  }
}

private extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedNonEmpty: String? {
    let value = trimmed
    return value.isEmpty ? nil : value
  }
}
