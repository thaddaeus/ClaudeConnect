import SwiftUI
import AppKit
import CoreImage

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CompanionSettingsView()
                .tabItem { Label("Companion", systemImage: "iphone.gen3") }
        }
        .frame(width: 540, height: 560)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("claudeBinaryPath") private var claudeBinaryPath: String = ""
    @State private var detectedPath: String?

    var body: some View {
        Form {
            Section("Claude Binary") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Path to claude binary", text: $claudeBinaryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { selectBinary() }
                        Button("Auto-detect") { autoDetect() }
                    }

                    if claudeBinaryPath.isEmpty {
                        if let detected = detectedPath {
                            statusLine(.green, "checkmark.circle.fill", "Auto-detected: \(detected)")
                        } else {
                            statusLine(.orange, "exclamationmark.triangle.fill",
                                       "Claude binary not found. Set the path manually or install Claude Code.")
                        }
                    } else if FileManager.default.isExecutableFile(atPath: claudeBinaryPath) {
                        statusLine(.green, "checkmark.circle.fill", "Valid executable")
                    } else {
                        statusLine(.red, "xmark.circle.fill", "File not found or not executable")
                    }

                    Text("Leave blank to use auto-detection. Common locations: ~/.local/bin/claude, /usr/local/bin/claude, /opt/homebrew/bin/claude")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { detectedPath = ShellEnvironment.shared.claudePath }
    }

    private func statusLine(_ color: Color, _ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the claude binary"
        if panel.runModal() == .OK, let url = panel.url {
            claudeBinaryPath = url.path
        }
    }

    private func autoDetect() {
        let env = ShellEnvironment.shared
        if let path = env.claudePath {
            claudeBinaryPath = path
            detectedPath = path
        }
    }
}

// MARK: - Companion

struct CompanionSettingsView: View {
    @Environment(CompanionSettings.self) private var settings
    @Environment(CompanionService.self) private var service

    @State private var pairing: PairingCode?
    @State private var pairError: String?
    @State private var isPairing = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Companion Bridge") {
                Toggle("Enable phone companion", isOn: $settings.companionEnabled)
                TextField("Relay URL", text: $settings.relayBaseURL, prompt: Text("https://…workers.dev"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.companionEnabled)
                Text("The Mac only makes outbound calls to this URL. Nothing connects back to your Mac.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("Pair a Phone") {
                Button {
                    Task { await requestPairingCode() }
                } label: {
                    if isPairing { ProgressView().controlSize(.small) }
                    else { Text("Generate Pairing Code") }
                }
                .disabled(!settings.companionEnabled || settings.relayBaseURL.isEmpty || isPairing)

                if let pairing {
                    pairingCodeView(pairing)
                }
                if let pairError {
                    Label(pairError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Alerts") {
                Toggle("Bell — turn finished / prompt", isOn: $settings.alertOnBell)
                Toggle("Settled — background tab went quiet", isOn: $settings.alertOnSettled)
                Toggle("Exited — process terminated", isOn: $settings.alertOnExit)

                HStack {
                    Stepper(value: $settings.settleSeconds, in: 0...30, step: 1) {
                        Text("Settle delay: \(settleLabel)")
                    }
                }
                .disabled(!settings.alertOnSettled)
                Text("How long a background tab must be quiet before it counts as \u{201C}settled.\u{201D} 0 disables the settled alert.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .disabled(!settings.companionEnabled)

            Section("Connection") {
                LabeledContent("Last sent", value: lastSentLabel)
                LabeledContent("Queued events", value: "\(service.queuedCount)")
                if let err = service.lastError {
                    LabeledContent("Last error") { Text(err).foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var settleLabel: String {
        settings.settleSeconds <= 0 ? "off" : "\(Int(settings.settleSeconds))s"
    }

    private var lastSentLabel: String {
        guard let date = service.lastSuccessfulPost else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func pairingCodeView(_ pairing: PairingCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pairing.code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let expiresAt = pairing.expiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = Int(expiresAt.timeIntervalSince(context.date))
                            if remaining > 0 {
                                Text("Expires in \(remaining)s")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Expired — generate a new code")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Spacer()
                if let qr = qrImage(for: pairing.code) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 96, height: 96)
                }
            }
            Text("On your phone, open the companion (Add to Home Screen) and enter this code or scan the QR.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func requestPairingCode() async {
        isPairing = true
        pairError = nil
        defer { isPairing = false }
        do {
            pairing = try await service.pair()
        } catch {
            pairing = nil
            pairError = error.localizedDescription
        }
    }

    /// Encodes the relay URL + pairing code into a QR the PWA can scan to prefill.
    private func qrImage(for code: String) -> NSImage? {
        let base = settings.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = base.isEmpty ? code : "\(base)/?pair=\(code)"
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
