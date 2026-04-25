import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

public enum TextFormattingProvider: String, Codable, CaseIterable, Equatable, Sendable {
	case xAI
	case openAI
	case gemini

	public var displayName: String {
		switch self {
		case .xAI:
			return "xAI"
		case .openAI:
			return "OpenAI"
		case .gemini:
			return "Gemini"
		}
	}
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
	public static let defaultWordRemovals: [WordRemoval] = [
		.init(pattern: "uh+"),
		.init(pattern: "um+"),
		.init(pattern: "er+"),
		.init(pattern: "hm+")
	]
	public static let defaultTextFormattingURL = "https://api.x.ai/v1"
	public static let defaultTextFormattingModel = "grok-4-1-fast-non-reasoning"
	public static let defaultTextFormattingPrompt = """
	You are an expert writing assistant.
	Rewrite text according to the user instruction while preserving the original intent.
	Keep any factual details unless the instruction explicitly asks to change them.
	Return only the rewritten text, with no preamble.
	strictly do not use double dashes and always return naturally written text, unless formal is specificed.
	if prompted for a code rewrite do not return in code blocks or with extra imports be strictly concise.
	"""

	public static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}

	public var soundEffectsEnabled: Bool
	public var soundEffectsVolume: Double
	public var hotkey: HotKey
	public var openOnLogin: Bool
	public var showDockIcon: Bool
	public var selectedModel: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
	public var doubleTapLockEnabled: Bool
	public var outputLanguage: String?
	public var selectedMicrophoneID: String?
	public var saveTranscriptionHistory: Bool
	public var maxHistoryEntries: Int?
	public var pasteLastTranscriptHotkey: HotKey?
	public var hasCompletedModelBootstrap: Bool
	public var hasCompletedStorageMigration: Bool
	public var wordRemovalsEnabled: Bool
	public var wordRemovals: [WordRemoval]
	public var wordRemappings: [WordRemapping]
	public var textFormattingProvider: TextFormattingProvider
	public var textFormattingURL: String
	public var textFormattingModel: String
	public var textFormattingAPIKey: String
	public var textFormattingPrompt: String

	private mutating func normalizeDoubleTapSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = ParakeetModel.multilingualV3.identifier,
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		copyToClipboard: Bool = false,
		superFastModeEnabled: Bool = false,
		useDoubleTapOnly: Bool = false,
		doubleTapLockEnabled: Bool = true,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false,
		wordRemovalsEnabled: Bool = false,
		wordRemovals: [WordRemoval] = HexSettings.defaultWordRemovals,
		wordRemappings: [WordRemapping] = [],
		textFormattingProvider: TextFormattingProvider = .xAI,
		textFormattingURL: String = HexSettings.defaultTextFormattingURL,
		textFormattingModel: String = HexSettings.defaultTextFormattingModel,
		textFormattingAPIKey: String = "",
		textFormattingPrompt: String = HexSettings.defaultTextFormattingPrompt
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
		self.doubleTapLockEnabled = doubleTapLockEnabled
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
		self.wordRemovalsEnabled = wordRemovalsEnabled
		self.wordRemovals = wordRemovals
		self.wordRemappings = wordRemappings
		self.textFormattingProvider = textFormattingProvider
		self.textFormattingURL = textFormattingURL
		self.textFormattingModel = textFormattingModel
		self.textFormattingAPIKey = textFormattingAPIKey
		self.textFormattingPrompt = textFormattingPrompt
		normalizeDoubleTapSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
		}
		normalizeDoubleTapSettings()
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.encode(self, into: &container)
		}
	}
}

// MARK: - Schema

private enum HexSettingKey: String, CodingKey, CaseIterable {
	case soundEffectsEnabled
	case soundEffectsVolume
	case hotkey
	case openOnLogin
	case showDockIcon
	case selectedModel
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
	case doubleTapLockEnabled
	case outputLanguage
	case selectedMicrophoneID
	case saveTranscriptionHistory
	case maxHistoryEntries
	case pasteLastTranscriptHotkey
	case hasCompletedModelBootstrap
	case hasCompletedStorageMigration
	case wordRemovalsEnabled
	case wordRemovals
	case wordRemappings
	case textFormattingProvider
	case textFormattingURL
	case textFormattingModel
	case textFormattingAPIKey
	case textFormattingPrompt
}

private struct SettingsField<Value: Codable & Sendable> {
	let key: HexSettingKey
	let keyPath: WritableKeyPath<HexSettings, Value>
	let defaultValue: Value
	let decodeStrategy: (KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value
	let encodeStrategy: (inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void

	init(
		_ key: HexSettingKey,
		keyPath: WritableKeyPath<HexSettings, Value>,
		default defaultValue: Value,
		decode: ((KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value)? = nil,
		encode: ((inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void)? = nil
	) {
		self.key = key
		self.keyPath = keyPath
		self.defaultValue = defaultValue
		self.decodeStrategy = decode ?? { container, key, defaultValue in
			try container.decodeIfPresent(Value.self, forKey: key) ?? defaultValue
		}
		self.encodeStrategy = encode ?? { container, key, value in
			try container.encode(value, forKey: key)
		}
	}

	func eraseToAny() -> AnySettingsField {
		AnySettingsField(
			key: key,
			decode: { container, settings in
				let value = try decodeStrategy(container, key, defaultValue)
				settings[keyPath: keyPath] = value
			},
			encode: { settings, container in
				let value = settings[keyPath: keyPath]
				try encodeStrategy(&container, key, value)
			}
		)
	}
}

private struct AnySettingsField {
	let key: HexSettingKey
	let decode: (KeyedDecodingContainer<HexSettingKey>, inout HexSettings) throws -> Void
	let encode: (HexSettings, inout KeyedEncodingContainer<HexSettingKey>) throws -> Void

	func decode(into settings: inout HexSettings, from container: KeyedDecodingContainer<HexSettingKey>) throws {
		try decode(container, &settings)
	}

	func encode(_ settings: HexSettings, into container: inout KeyedEncodingContainer<HexSettingKey>) throws {
		try encode(settings, &container)
	}
}

private enum HexSettingsSchema {
	static let defaults = HexSettings()

	nonisolated(unsafe) static let fields: [AnySettingsField] = [
		SettingsField(.soundEffectsEnabled, keyPath: \.soundEffectsEnabled, default: defaults.soundEffectsEnabled).eraseToAny(),
		SettingsField(.soundEffectsVolume, keyPath: \.soundEffectsVolume, default: defaults.soundEffectsVolume).eraseToAny(),
		SettingsField(.hotkey, keyPath: \.hotkey, default: defaults.hotkey).eraseToAny(),
		SettingsField(.openOnLogin, keyPath: \.openOnLogin, default: defaults.openOnLogin).eraseToAny(),
		SettingsField(.showDockIcon, keyPath: \.showDockIcon, default: defaults.showDockIcon).eraseToAny(),
		SettingsField(.selectedModel, keyPath: \.selectedModel, default: defaults.selectedModel).eraseToAny(),
		SettingsField(.useClipboardPaste, keyPath: \.useClipboardPaste, default: defaults.useClipboardPaste).eraseToAny(),
		SettingsField(.preventSystemSleep, keyPath: \.preventSystemSleep, default: defaults.preventSystemSleep).eraseToAny(),
		SettingsField(
			.recordingAudioBehavior,
			keyPath: \.recordingAudioBehavior,
			default: defaults.recordingAudioBehavior,
			decode: { container, key, defaultValue in
				if let value = try container.decodeIfPresent(RecordingAudioBehavior.self, forKey: key) {
					return value
				}
				if let legacyPause = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) {
					return legacyPause ? .pauseMedia : .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
		SettingsField(
			.outputLanguage,
			keyPath: \.outputLanguage,
			default: defaults.outputLanguage,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.selectedMicrophoneID,
			keyPath: \.selectedMicrophoneID,
			default: defaults.selectedMicrophoneID,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.saveTranscriptionHistory, keyPath: \.saveTranscriptionHistory, default: defaults.saveTranscriptionHistory).eraseToAny(),
		SettingsField(
			.maxHistoryEntries,
			keyPath: \.maxHistoryEntries,
			default: defaults.maxHistoryEntries,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.pasteLastTranscriptHotkey,
			keyPath: \.pasteLastTranscriptHotkey,
			default: defaults.pasteLastTranscriptHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.hasCompletedModelBootstrap, keyPath: \.hasCompletedModelBootstrap, default: defaults.hasCompletedModelBootstrap).eraseToAny(),
		SettingsField(.hasCompletedStorageMigration, keyPath: \.hasCompletedStorageMigration, default: defaults.hasCompletedStorageMigration).eraseToAny(),
		SettingsField(.wordRemovalsEnabled, keyPath: \.wordRemovalsEnabled, default: defaults.wordRemovalsEnabled).eraseToAny(),
		SettingsField(
			.wordRemovals,
			keyPath: \.wordRemovals,
			default: defaults.wordRemovals
		).eraseToAny(),
		SettingsField(
			.wordRemappings,
			keyPath: \.wordRemappings,
			default: defaults.wordRemappings
		).eraseToAny(),
		SettingsField(.textFormattingProvider, keyPath: \.textFormattingProvider, default: defaults.textFormattingProvider).eraseToAny(),
		SettingsField(.textFormattingURL, keyPath: \.textFormattingURL, default: defaults.textFormattingURL).eraseToAny(),
		SettingsField(.textFormattingModel, keyPath: \.textFormattingModel, default: defaults.textFormattingModel).eraseToAny(),
		SettingsField(.textFormattingAPIKey, keyPath: \.textFormattingAPIKey, default: defaults.textFormattingAPIKey).eraseToAny(),
		SettingsField(.textFormattingPrompt, keyPath: \.textFormattingPrompt, default: defaults.textFormattingPrompt).eraseToAny()
	]
}
