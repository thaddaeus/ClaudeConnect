import AVFoundation
import SwiftUI

/// Settings → Voice. Everything the voice channel exposes, in one pane.
struct VoiceSettingsView: View {
    @Environment(VoiceController.self) private var voice
    @State private var previewVoiceID: String?

    var body: some View {
        @Bindable var voice = voice

        Form {
            Section {
                Toggle("Enable voice", isOn: $voice.isEnabled)
                Text("Speaks the active tab's replies. Only the tab you're looking at is audible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Listening") {
                Toggle("Listen for the wake phrase", isOn: $voice.isMicEnabled)
                    .disabled(!voice.isEnabled || !voice.isMicSupported)

                if !voice.isMicSupported {
                    Label("Listening needs macOS 26 — speech output works on any version.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextField("Wake phrase", text: $voice.wakePhrase)
                    .disabled(!voice.isMicSupported)
                Text("The mic stays open, so this phrase is the only thing separating a prompt from ordinary conversation. Two or three distinct syllables work best.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Confirm before sending", isOn: $voice.confirmBeforeSending)
                    .disabled(!voice.isMicSupported)
                Text("Dictation waits for \"send\" instead of going straight into the session. Worth turning on for sessions running in Bypass Permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status") {
                    Text(voice.micStatus.summary)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speech") {
                Picker("Voice", selection: Binding(
                    get: { voice.speech.voiceIdentifier ?? "" },
                    set: { voice.speech.voiceIdentifier = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System default").tag("")
                    ForEach(SpeechOutput.availableVoices(), id: \.identifier) { v in
                        Text(voiceLabel(v)).tag(v.identifier)
                    }
                }

                HStack {
                    Text("Rate")
                    Slider(value: Binding(
                        get: { Double(voice.speech.rate) },
                        set: { voice.speech.rate = Float($0) }
                    ), in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                    Button("Preview") {
                        voice.speech.speak("Running the tests now. Two files changed.")
                    }
                    .controlSize(.small)
                }

                Text("Enhanced and Premium voices sound markedly better than Default — download them in System Settings → Accessibility → Spoken Content → System Voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Commands") {
                Text(commandHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
    }

    private var commandHelp: String {
        let wake = voice.wakePhrase
        return """
        “\(wake), switch to <tab name>” · “\(wake), next tab” · “\(wake), tab three”
        “\(wake), stop” stops speaking · “\(wake), interrupt” sends Escape to the session
        “\(wake), mute” closes the mic
        Anything else is typed into the active tab.
        """
    }

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch v.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Default"
        }
        return "\(v.name) — \(quality)"
    }
}
