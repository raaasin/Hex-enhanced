import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let textFormattingLogger = HexLog.app

@DependencyClient
struct TextFormattingClient: Sendable {
  struct Configuration: Equatable, Sendable {
    var provider: TextFormattingProvider = .xAI
    var model: String = HexSettings.defaultTextFormattingModel
    var baseURL: String = HexSettings.defaultTextFormattingURL
    var prompt: String = HexSettings.defaultTextFormattingPrompt
    var timeout: Duration = .seconds(120)
    var maxOutputTokens: Int = 4096
  }

  var format: @Sendable (_ original: String, _ instruction: String) async throws -> String
  var ask: @Sendable (_ question: String) async throws -> String
  var loadAPIKey: @Sendable () async throws -> String
  var configuration: @Sendable () -> Configuration = { .init() }
}

extension TextFormattingClient: DependencyKey {
  static let liveValue: Self = {
    let live = TextFormattingClientLive()
    return Self(
      format: { original, instruction in
        @Shared(.hexSettings) var hexSettings: HexSettings
        let configuration = TextFormattingClient.Configuration(settings: hexSettings)
        let apiKey = try await live.loadAPIKey(settingsValue: hexSettings.textFormattingAPIKey)
        return try await live.format(
          original: original,
          instruction: instruction,
          configuration: configuration,
          apiKey: apiKey
        )
      },
      ask: { question in
        @Shared(.hexSettings) var hexSettings: HexSettings
        let configuration = TextFormattingClient.Configuration(askSettings: hexSettings)
        let apiKey = try await live.loadAPIKey(settingsValue: hexSettings.textFormattingAPIKey)
        return try await live.ask(
          question: question,
          configuration: configuration,
          apiKey: apiKey
        )
      },
      loadAPIKey: {
        @Shared(.hexSettings) var hexSettings: HexSettings
        return try await live.loadAPIKey(settingsValue: hexSettings.textFormattingAPIKey)
      },
      configuration: {
        @Shared(.hexSettings) var hexSettings: HexSettings
        return TextFormattingClient.Configuration(settings: hexSettings)
      }
    )
  }()

  static let testValue = Self(
    format: { _, _ in "" },
    ask: { _ in "" },
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
      return "No API key found. Add one in Settings > AI, or set XAI_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY in your environment or ~/.zshrc."
    case let .invalidBaseURL(value):
      return "The text formatting service URL is invalid: \(value)."
    case let .transportFailure(message):
      return "Could not reach the text formatting provider. \(message)"
    case let .serverError(statusCode, message):
      if let message, !message.isEmpty {
        return "The text formatting provider returned an error (\(statusCode)): \(message)"
      }
      return "The text formatting provider returned an error (\(statusCode))."
    case .invalidResponse:
      return "Received an invalid response from the text formatting provider."
    case .emptyResponse:
      return "The text formatting provider returned no formatted text."
    }
  }
}

actor TextFormattingClientLive {
  private let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    return URLSession(configuration: configuration)
  }()

  func format(
    original: String,
    instruction: String,
    configuration: TextFormattingClient.Configuration,
    apiKey: String
  ) async throws -> String {
    try await performRequest(
      requestBody: makeFormatRequestBody(original: original, instruction: instruction, configuration: configuration),
      configuration: configuration,
      apiKey: apiKey,
      requestKind: "format",
      inputLength: original.count + instruction.count
    )
  }

  func ask(
    question: String,
    configuration: TextFormattingClient.Configuration,
    apiKey: String
  ) async throws -> String {
    try await performRequest(
      requestBody: makeAskRequestBody(question: question, configuration: configuration),
      configuration: configuration,
      apiKey: apiKey,
      requestKind: "ask",
      inputLength: question.count
    )
  }

  private func performRequest(
    requestBody: [String: Any],
    configuration: TextFormattingClient.Configuration,
    apiKey: String,
    requestKind: String,
    inputLength: Int
  ) async throws -> String {
    let endpoint = try responsesEndpointURL(baseURL: configuration.baseURL)

    textFormattingLogger.info(
      "AI request type=\(requestKind, privacy: .public) provider=\(configuration.provider.rawValue, privacy: .public) model=\(configuration.model, privacy: .public) inputLength=\(inputLength)"
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.timeout.timeInterval
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

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

    guard let parsed = parseFormattedText(from: responseObject) else {
      throw TextFormattingClientError.emptyResponse
    }

    let formatted = Self.sanitizeOuterMarkdownFence(in: parsed)
    guard !formatted.isEmpty else {
      throw TextFormattingClientError.emptyResponse
    }

    textFormattingLogger.debug("Formatting response length=\(formatted.count)")
    return formatted
  }

  func loadAPIKey(settingsValue: String) async throws -> String {
    if let settingsKey = settingsValue.trimmedNonEmpty {
      return settingsKey
    }

    if let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"]?.trimmedNonEmpty {
      return envKey
    }

    if let fallbackEnvKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmedNonEmpty {
      return fallbackEnvKey
    }

    if let geminiEnvKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.trimmedNonEmpty {
      return geminiEnvKey
    }

    if let zshKey = try loadAPIKeyFromZshrc() {
      return zshKey
    }

    throw TextFormattingClientError.missingAPIKey
  }

  private func makeFormatRequestBody(
    original: String,
    instruction: String,
    configuration: TextFormattingClient.Configuration
  ) -> [String: Any] {
    let prompt = configuration.prompt.trimmedNonEmpty ?? HexSettings.defaultTextFormattingPrompt

    var body: [String: Any] = [
      "model": configuration.model,
      "input": [
        [
          "role": "system",
          "content": [
            [
              "type": "input_text",
              "text": prompt,
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
      "max_output_tokens": configuration.maxOutputTokens,
    ]

    if configuration.provider == .xAI {
      body["tools"] = [
        ["type": "web_search"],
        ["type": "x_search"],
      ]
    }

    return body
  }

  private func makeAskRequestBody(
    question: String,
    configuration: TextFormattingClient.Configuration
  ) -> [String: Any] {
    let prompt = configuration.prompt.trimmedNonEmpty ?? HexSettings.defaultAskPrompt

    var body: [String: Any] = [
      "model": configuration.model,
      "input": [
        [
          "role": "system",
          "content": [
            [
              "type": "input_text",
              "text": prompt,
            ]
          ],
        ],
        [
          "role": "user",
          "content": [
            [
              "type": "input_text",
              "text": question,
            ]
          ],
        ],
      ],
      "max_output_tokens": configuration.maxOutputTokens,
    ]

    if configuration.provider == .xAI {
      body["tools"] = [
        ["type": "web_search"],
        ["type": "x_search"],
      ]
    }

    return body
  }

  private func responsesEndpointURL(baseURL: String) throws -> URL {
    guard let url = URL(string: baseURL),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      throw TextFormattingClientError.invalidBaseURL(baseURL)
    }

    let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = "/\(trimmedPath)/responses".replacingOccurrences(of: "//", with: "/")

    guard let url = components.url else {
      throw TextFormattingClientError.invalidBaseURL(baseURL)
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

  nonisolated static func sanitizeOuterMarkdownFence(in text: String) -> String {
    guard text.hasPrefix("```") else { return text }
    guard let openingFenceLineBreak = text.firstIndex(of: "\n") else { return text }
    let openingFenceInfo = text[text.index(text.startIndex, offsetBy: 3)..<openingFenceLineBreak]
    guard !openingFenceInfo.contains("`") else { return text }

    let remainder = text[text.index(after: openingFenceLineBreak)...]
    guard remainder.hasSuffix("\n```") else { return text }

    let innerCodeEnd = remainder.index(remainder.endIndex, offsetBy: -4)
    var innerCode = String(remainder[..<innerCodeEnd])
    guard !innerCode.hasPrefix("```") else { return text }
    guard !innerCode.contains("\n```") else { return text }
    guard !innerCode.contains("\r\n```") else { return text }
    if innerCode.hasSuffix("\r") {
      innerCode.removeLast()
    }
    return innerCode
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
      "source ~/.zshrc >/dev/null 2>&1; print -r -- ${XAI_API_KEY:-${OPENAI_API_KEY:-${GEMINI_API_KEY:-}}}",
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

private extension TextFormattingClient.Configuration {
  init(settings: HexSettings) {
    self.provider = settings.textFormattingProvider
    self.model = settings.textFormattingModel.trimmedNonEmpty ?? HexSettings.defaultTextFormattingModel
    self.baseURL = settings.textFormattingURL.trimmedNonEmpty ?? HexSettings.defaultTextFormattingURL
    self.prompt = settings.textFormattingPrompt
  }

  init(askSettings settings: HexSettings) {
    self.provider = settings.textFormattingProvider
    self.model = settings.textFormattingModel.trimmedNonEmpty ?? HexSettings.defaultTextFormattingModel
    self.baseURL = settings.textFormattingURL.trimmedNonEmpty ?? HexSettings.defaultTextFormattingURL
    self.prompt = settings.askModePrompt
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
