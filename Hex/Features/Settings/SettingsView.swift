import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus
  
	var body: some View {
		Form {
			if microphonePermission != .granted
				|| accessibilityPermission != .granted
				|| inputMonitoringPermission != .granted {
				PermissionsSectionView(
					store: store,
					microphonePermission: microphonePermission,
					accessibilityPermission: accessibilityPermission,
					inputMonitoringPermission: inputMonitoringPermission
				)
			}

			ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)
			// Only show language picker for WhisperKit models (not Parakeet)
			if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil {
				LanguageSectionView(store: store)
			}

			HotKeySectionView(store: store)
          
			if microphonePermission == .granted {
				MicrophoneSelectionSectionView(store: store)
			}

			SoundSectionView(store: store)
			AISectionView(store: store)
			GeneralSectionView(store: store)
			HistorySectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}

struct AISectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				HStack {
					Text("Provider")
					Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.textFormattingProvider },
						set: { store.send(.setTextFormattingProvider($0)) }
					)) {
						ForEach(TextFormattingProvider.allCases, id: \.self) { provider in
							Text(provider.displayName).tag(provider)
						}
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "cloud")
			}

			Label {
				TextField(
					"https://api.x.ai/v1",
					text: Binding(
						get: { store.hexSettings.textFormattingURL },
						set: { store.send(.setTextFormattingURL($0)) }
					)
				)
			} icon: {
				Image(systemName: "link")
			}

			Label {
				TextField(
					"grok-4-1-fast-non-reasoning",
					text: Binding(
						get: { store.hexSettings.textFormattingModel },
						set: { store.send(.setTextFormattingModel($0)) }
					)
				)
			} icon: {
				Image(systemName: "cube")
			}

			Label {
				SecureField(
					"API key",
					text: Binding(
						get: { store.hexSettings.textFormattingAPIKey },
						set: { store.send(.setTextFormattingAPIKey($0)) }
					)
				)
			} icon: {
				Image(systemName: "key")
			}

			VStack(alignment: .leading, spacing: 8) {
				Label("Prompt", systemImage: "text.quote")
				TextEditor(text: Binding(
					get: { store.hexSettings.textFormattingPrompt },
					set: { store.send(.setTextFormattingPrompt($0)) }
				))
				.frame(minHeight: 100)
			}
		} header: {
			Text("AI")
		}
		.enableInjection()
	}
}

// MARK: - Shared Styles

extension Text {
	/// Applies caption font with secondary color, commonly used for helper/description text in settings.
	func settingsCaption() -> some View {
		self.font(.caption).foregroundStyle(.secondary)
	}
}
