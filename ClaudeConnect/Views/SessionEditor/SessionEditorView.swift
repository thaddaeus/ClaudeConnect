import SwiftUI

// MARK: - Help Tip View

struct HelpTip: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .onHover { hovering in
                isShowing = hovering
            }
            .popover(isPresented: $isShowing, arrowEdge: .trailing) {
                Text(text)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

// MARK: - Session Editor

struct SessionEditorView: View {
    @State var session: SessionConfiguration

    var onSave: (SessionConfiguration) -> Void
    var onSaveAndLaunch: (SessionConfiguration) -> Void
    var onCancel: () -> Void

    private let models = ["", "opus", "sonnet", "haiku"]
    private let efforts = ["", "low", "medium", "high", "max"]
    private let iconOptions = [
        "terminal", "bolt", "cpu", "server.rack",
        "hammer", "wrench.and.screwdriver", "ant", "ladybug",
        "text.page", "doc.text", "globe", "network"
    ]
    private let colorPresets = [
        "#007AFF", "#FF2D55", "#5856D6", "#FF9500",
        "#34C759", "#AF52DE", "#00C7BE", "#FF6482"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Session")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(session) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // General
                    GroupBox("General") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent {
                                TextField("Session name", text: $session.name)
                                    .textFieldStyle(.roundedBorder)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Name")
                                    HelpTip(text: "A display name for this session. Shown in the sidebar and tab bar.")
                                }
                            }

                            LabeledContent {
                                HStack {
                                    TextField("~/path/to/project", text: $session.workingDirectory)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Browse...") { selectDirectory() }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Working Directory")
                                    HelpTip(text: "The directory Claude Code will start in. This is where it looks for CLAUDE.md, .git, and your project files.")
                                }
                            }

                            HStack(spacing: 4) {
                                Toggle("Auto-start on launch", isOn: $session.autoStart)
                                HelpTip(text: "Automatically open this session in a tab when ClaudeConnect starts.")
                            }

                            HStack(spacing: 4) {
                                Toggle("Continue previous session", isOn: $session.continueSession)
                                HelpTip(text: "Resume the last conversation instead of starting fresh. Uses the --continue flag.")
                            }

                            HStack(spacing: 4) {
                                Toggle("Open new tabs in ClaudeConnect", isOn: $session.openInClaudeConnect)
                                HelpTip(text: "When enabled, tells Claude to use claude-connect-tab to open new terminal tabs inside ClaudeConnect instead of opening Terminal.app. Essential for hub/worktree workflows.")
                            }
                        }
                        .padding(8)
                    }

                    // Claude Settings
                    GroupBox("Claude Settings") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent {
                                Picker("", selection: Binding(
                                    get: { session.model ?? "" },
                                    set: { session.model = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text("Default").tag("")
                                    ForEach(models.dropFirst(), id: \.self) { model in
                                        Text(model.capitalized).tag(model)
                                    }
                                }
                                .labelsHidden()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Model")
                                    HelpTip(text: "Which Claude model to use. Opus is the most capable, Haiku is the fastest. Leave as Default to use your account's default.")
                                }
                            }

                            LabeledContent {
                                Picker("", selection: Binding(
                                    get: { session.permissionMode ?? .default },
                                    set: { session.permissionMode = $0 }
                                )) {
                                    ForEach(SessionConfiguration.PermissionMode.allCases) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .labelsHidden()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Permission Mode")
                                    HelpTip(text: "Controls how much Claude can do without asking.\n\n- Default: Asks before file edits and commands\n- Plan: Read-only, Claude plans but doesn't execute\n- Auto Edit: Auto-approves file edits, asks for commands\n- Full Auto: Auto-approves edits and most commands\n- Bypass: Skips all permission prompts (use with caution)")
                                }
                            }

                            LabeledContent {
                                Picker("", selection: Binding(
                                    get: { session.effortLevel ?? "" },
                                    set: { session.effortLevel = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text("Default").tag("")
                                    ForEach(efforts.dropFirst(), id: \.self) { level in
                                        Text(level.capitalized).tag(level)
                                    }
                                }
                                .labelsHidden()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Effort")
                                    HelpTip(text: "How much thinking effort Claude puts in.\n\n- Low: Quick, concise responses\n- Medium: Balanced (default behavior)\n- High: More thorough analysis\n- Max: Deep thinking for complex tasks")
                                }
                            }
                        }
                        .padding(8)
                    }

                    // Prompts
                    GroupBox("Prompts") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("System Prompt")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HelpTip(text: "REPLACES Claude's entire default system prompt with your custom instructions. This is invisible to the conversation \u{2014} Claude follows it but it's never shown in the terminal. Use this for defining Claude's role, personality, or strict rules.\n\nFor most cases, use Append System Prompt instead to ADD to the defaults rather than replacing them.")
                                }
                                TextEditor(text: Binding(
                                    get: { session.systemPrompt ?? "" },
                                    set: { session.systemPrompt = $0.isEmpty ? nil : $0 }
                                ))
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 60, maxHeight: 100)
                                .border(Color.gray.opacity(0.3))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("Append System Prompt")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HelpTip(text: "ADDS to Claude's default system prompt without replacing it. Your text is appended at the end. This is the safest way to give Claude extra context or rules while keeping all of its built-in capabilities.\n\nThis is invisible to the conversation \u{2014} Claude follows it behind the scenes.")
                                }
                                TextEditor(text: Binding(
                                    get: { session.appendSystemPrompt ?? "" },
                                    set: { session.appendSystemPrompt = $0.isEmpty ? nil : $0 }
                                ))
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 60, maxHeight: 100)
                                .border(Color.gray.opacity(0.3))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("Initial Prompt")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HelpTip(text: "A message sent to Claude as the FIRST user message when the session starts. This IS visible in the terminal \u{2014} you'll see it and Claude's response.\n\nUse this for startup tasks like: \"Read and summarize the current issues\" or \"Check the build status and report any failures.\"")
                                }
                                TextEditor(text: Binding(
                                    get: { session.initialPrompt ?? "" },
                                    set: { session.initialPrompt = $0.isEmpty ? nil : $0 }
                                ))
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 60, maxHeight: 100)
                                .border(Color.gray.opacity(0.3))
                            }
                        }
                        .padding(8)
                    }

                    // Advanced
                    GroupBox("Advanced") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent {
                                TextField("/path/to/mcp-config.json", text: Binding(
                                    get: { session.mcpConfigPath ?? "" },
                                    set: { session.mcpConfigPath = $0.isEmpty ? nil : $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("MCP Config Path")
                                    HelpTip(text: "Path to a JSON file defining MCP (Model Context Protocol) servers. These give Claude access to external tools like databases, APIs, or browser automation.")
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("Additional Flags")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HelpTip(text: "Raw CLI flags passed directly to the claude command. One flag per line.\n\nExamples:\n--verbose\n--no-telemetry\n--dangerously-skip-permissions")
                                }
                                TextEditor(text: $session.additionalFlags)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 60, maxHeight: 100)
                                    .border(Color.gray.opacity(0.3))
                            }
                        }
                        .padding(8)
                    }

                    // Appearance
                    GroupBox("Appearance") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Tab Color")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    ForEach(colorPresets, id: \.self) { hex in
                                        Circle()
                                            .fill(Color(hex: hex) ?? .blue)
                                            .frame(width: 24, height: 24)
                                            .overlay {
                                                if session.tabColorHex == hex {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                            .onTapGesture {
                                                session.tabColorHex = hex
                                            }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Tab Icon")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 6), spacing: 8) {
                                    ForEach(iconOptions, id: \.self) { icon in
                                        Image(systemName: icon)
                                            .font(.system(size: 16))
                                            .frame(width: 32, height: 32)
                                            .background(session.tabIconName == icon ? Color.accentColor.opacity(0.2) : .clear)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .onTapGesture {
                                                session.tabIconName = icon
                                            }
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Save & Launch") { onSaveAndLaunch(session) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                Spacer()
            }
            .padding()
        }
        .frame(width: 520, height: 700)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let expanded = (session.workingDirectory as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: expanded)
        if panel.runModal() == .OK, let url = panel.url {
            session.workingDirectory = url.path
        }
    }
}
