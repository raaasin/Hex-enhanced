import ComposableArchitecture
import Inject
import SwiftUI

struct AISettingsView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("AI") {
        Label {
          Toggle(
            "Enable Ask mode",
            isOn: Binding(
              get: { store.hexSettings.askModeEnabled },
              set: { store.send(.setAskModeEnabled($0)) }
            )
          )
          Text("Use tap, then tap-and-hold on modifier-only hotkeys to ask a one-shot question.")
        } icon: {
          Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Provider")
          Picker(
            "Provider",
            selection: Binding(
              get: { store.hexSettings.textFormattingProvider },
              set: { store.send(.setTextFormattingProvider($0)) }
            )
          ) {
            ForEach(TextFormattingProvider.allCases, id: \.self) { provider in
              Text(provider.displayName).tag(provider)
            }
          }
          .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Provider URL")
          TextField(
            "https://api.x.ai/v1",
            text: Binding(
              get: { store.hexSettings.textFormattingURL },
              set: { store.send(.setTextFormattingURL($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Model slug")
          TextField(
            "grok-4-1-fast-non-reasoning",
            text: Binding(
              get: { store.hexSettings.textFormattingModel },
              set: { store.send(.setTextFormattingModel($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("API key")
          SecureField(
            "API key",
            text: Binding(
              get: { store.hexSettings.textFormattingAPIKey },
              set: { store.send(.setTextFormattingAPIKey($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Prompt")
          TextEditor(text: Binding(
            get: { store.hexSettings.textFormattingPrompt },
            set: { store.send(.setTextFormattingPrompt($0)) }
          ))
          .frame(minHeight: 140)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Ask prompt")
          TextEditor(text: Binding(
            get: { store.hexSettings.askModePrompt },
            set: { store.send(.setAskModePrompt($0)) }
          ))
          .frame(minHeight: 140)
        }
      }
    }
    .formStyle(.grouped)
    .enableInjection()
  }
}
