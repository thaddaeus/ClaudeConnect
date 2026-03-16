import SwiftUI

struct SettingsView: View {
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
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Auto-detected: \(detected)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Claude binary not found. Set the path manually or install Claude Code.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if FileManager.default.isExecutableFile(atPath: claudeBinaryPath) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Valid executable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("File not found or not executable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Leave blank to use auto-detection. Common locations: ~/.local/bin/claude, /usr/local/bin/claude, /opt/homebrew/bin/claude")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 200)
        .onAppear {
            detectedPath = ShellEnvironment.shared.claudePath
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
        // Re-run detection
        let env = ShellEnvironment.shared
        if let path = env.claudePath {
            claudeBinaryPath = path
            detectedPath = path
        }
    }
}
