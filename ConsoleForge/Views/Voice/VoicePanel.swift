import SwiftUI

/// The voice sidecar: what is being spoken, from which tab, and the controls to stop it.
///
/// Phase 1 is speech-out only — the mic affordances arrive with `VoiceEngine`.
struct VoicePanel: View {
    @Environment(VoiceController.self) private var voice
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var voice = voice

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            targetLine
            Divider()
            micStrip
            Divider()
            log
            if voice.pendingDictation != nil {
                Divider()
                confirmBar
            }
            Divider()
            controls
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var voice = voice

        return HStack(spacing: 8) {
            Image(systemName: voice.speech.isSpeaking ? "waveform" : "speaker.wave.2")
                .foregroundStyle(voice.speech.isSpeaking ? .green : .secondary)
                .symbolEffect(.variableColor, isActive: voice.speech.isSpeaking)
            Text("Voice")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Toggle("", isOn: $voice.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(voice.isEnabled ? "Voice on" : "Voice off")
            Button {
                voice.isPanelVisible = false
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide voice panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Target

    private var targetLine: some View {
        HStack(spacing: 6) {
            Text("target")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            if let name = voice.targetTabName, voice.isEnabled {
                Circle()
                    .fill(store.activeTabID.flatMap { store.session(for: $0)?.tabColor } ?? .gray)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            } else {
                Text(voice.isEnabled ? "no active tab" : "voice off")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Mic

    private var micStrip: some View {
        @Bindable var voice = voice

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: micSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(micColor)
                    .frame(width: 14)

                levelMeter

                Spacer()

                Toggle("", isOn: $voice.isMicEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!voice.isEnabled || !voice.isMicSupported)
                    .help(voice.isMicSupported ? "Listen for the wake phrase"
                                               : "Listening requires macOS 26")
            }

            Text(micDetail)
                .font(.system(size: 10))
                .foregroundStyle(micStatusIsProblem ? .orange : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !voice.caption.isEmpty {
                Text(voice.caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.12), value: voice.caption)
    }

    /// Twelve bars driven by the input level — enough to read "it is hearing me"
    /// at a glance without being a real spectrum.
    private var levelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Float(index + 1) / 12
                RoundedRectangle(cornerRadius: 1)
                    .fill(voice.inputLevel >= threshold ? Color.green : Color.secondary.opacity(0.22))
                    .frame(width: 3, height: 4 + CGFloat(index) * 0.7)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: voice.inputLevel)
    }

    private var micSymbol: String {
        switch voice.micStatus {
        case .listening, .echoCancellationUnavailable: return "mic.fill"
        case .denied, .failed, .unsupported: return "mic.slash"
        case .preparing, .downloadingModel: return "mic.badge.plus"
        case .off: return "mic.slash"
        }
    }

    private var micColor: Color {
        switch voice.micStatus {
        case .listening: return .green
        case .echoCancellationUnavailable: return .orange
        case .denied, .failed, .unsupported: return .orange
        case .preparing, .downloadingModel: return .secondary
        case .off: return .secondary
        }
    }

    private var micStatusIsProblem: Bool {
        switch voice.micStatus {
        case .denied, .failed, .unsupported, .echoCancellationUnavailable: return true
        default: return false
        }
    }

    private var micDetail: String {
        switch voice.micStatus {
        case .listening:
            return "say \"\(voice.wakePhrase)\" then your prompt"
        case .denied:
            return "Mic access denied — System Settings → Privacy & Security → Microphone"
        default:
            return voice.micStatus.summary
        }
    }

    // MARK: - Confirm

    private var confirmBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(voice.pendingDictation ?? "")
                .font(.system(size: 11))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Send") { voice.confirmPendingDictation() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { voice.cancelPendingDictation() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Log

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if voice.exchanges.isEmpty {
                        emptyState
                    }
                    ForEach(voice.exchanges) { exchange in
                        exchangeRow(exchange)
                            .id(exchange.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: voice.exchanges.count) { _, _ in
                guard let last = voice.exchanges.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(voice.isEnabled ? "Waiting for the session to say something."
                                 : "Turn voice on to hear replies.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exchangeRow(_ exchange: VoiceController.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label(for: exchange))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color(for: exchange.speaker))
                Text(exchange.at, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            Text(exchange.text)
                .font(.system(size: 11))
                .foregroundStyle(exchange.speaker == .system ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(for exchange: VoiceController.Exchange) -> String {
        switch exchange.speaker {
        case .user: return "you ▸"
        case .assistant: return "\(exchange.source) ▸"
        case .system: return "•"
        }
    }

    private func color(for speaker: VoiceController.Exchange.Speaker) -> Color {
        switch speaker {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .secondary
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                voice.stopSpeaking()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!voice.speech.isSpeaking)

            Button {
                voice.speech.skipCurrent()
            } label: {
                Label("Skip", systemImage: "forward.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!voice.speech.isSpeaking)

            Spacer()

            Button {
                voice.clearLog()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear log")
            .disabled(voice.exchanges.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
