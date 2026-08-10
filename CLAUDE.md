# ConsoleForge

A native macOS app for managing multiple AI coding terminal sessions in tabs.

## Tech Stack
- Swift 5.9+ / SwiftUI (macOS 14+)
- SwiftTerm (SPM) for terminal emulation with PTY support
- posix_spawn + openpty for fork-safe process launching (hardened runtime compatible)

## Architecture
- **Models/**: Data types (SessionConfiguration, SessionFolder, SessionState)
- **Services/**: SessionStore (persistence + state), ClaudeProcessBuilder (CLI arg builder), PtyProcess (PTY management)
- **Views/**: SwiftUI views organized by feature (Sidebar, Terminal, SessionEditor, Settings)

## Development

Build and run locally:
```bash
swift build
swift run
```

### Beta channel (preferred for iteration)

`scripts/beta.sh` builds and signs a **separate** `/Applications/ConsoleForge Beta.app`
that runs side by side with production and cannot touch its state. Use it instead of
`dev.sh` whenever production has real sessions open — it never quits, pkills, or writes
to `/Applications/ConsoleForge.app`.

```bash
./scripts/beta.sh              # release build, relaunch beta
./scripts/beta.sh debug        # faster debug build
./scripts/beta.sh --no-launch  # build + install, leave the app closed
```

**No notarization.** Gatekeeper only blocks bundles carrying the `com.apple.quarantine`
xattr, which is set on *download* — a locally built app never has it. So beta is
build + sign (seconds), not the `notarytool --wait` round trip. `spctl -a` still reports
"rejected / Unnotarized Developer ID" because it assesses as-if-downloaded; that is not
the check the launch path runs. Signing is still mandatory, for the Keychain reason in
`dev.sh`'s header — a stable Developer ID keeps the designated requirement constant.

Beta diverges from production in five places. The bundle id is the master key; the app
derives the rest from it in `AppChannel.swift`:

| Divergence | Production | Beta |
| ---------- | ---------- | ---- |
| Bundle id | `com.thaddaeus.ConsoleForge` | `com.thaddaeus.ConsoleForge.beta` |
| App | `/Applications/ConsoleForge.app` | `/Applications/ConsoleForge Beta.app` |
| Support dir | `~/Library/Application Support/ConsoleForge` | `…/ConsoleForge Beta` |
| Keychain service | `com.thaddaeus.ConsoleForge` | `com.thaddaeus.ConsoleForge.beta` |
| Sparkle | live feed, auto-checks on | no feed, updater never started |

A different bundle id alone is **not** enough: `sessions.json`, `commands/`, and `events/`
used to hardcode the literal string `"ConsoleForge"`, so a beta would still have written
into production's tree. Anything that is not exactly the production bundle id — including
an unbundled `swift run`, whose identifier is nil — is treated as non-production.

`consoleforge-tab` picks its target the same way: explicit `--app prod|beta` wins,
otherwise `$CONSOLEFORGE_APP_SUPPORT` (exported by whichever app owns the tab), otherwise
production. That env var is what makes it deterministic — `~/.local/bin/consoleforge-tab`
comes before the bundle's own copy on `PATH`, so the file on disk can't identify the channel.

Beta's icon is the production icon hue-rotated (orange → cyan). Regenerate it with
`python3 scripts/make-beta-icon.py` if `AppIcon.icns` is ever redesigned.

### Production hot-swap

Hot-swap the running app without a full release — **always use `scripts/dev.sh`**:
```bash
./scripts/dev.sh           # release config (default)
./scripts/dev.sh debug     # faster debug build
```

The script does build → quit running app → swap binary into the **installed** app at
`/Applications/ConsoleForge.app` → **re-sign with the Developer ID** → relaunch. It targets
the prod install in place so the app you normally launch is the one you're testing. The
re-sign step is mandatory: copying a fresh binary into the bundle invalidates its signature,
so the Keychain treats every relaunch as a new untrusted app and forces the login-**password**
prompt on the companion token read (Touch ID / Apple Watch cannot authorize a new app identity
against an existing item). Re-signing with the stable Developer ID keeps a constant designated
requirement — click "Always Allow" once and no future hot-swap prompts. (Re-signing locally
strips the notarization staple from this install until the next `./scripts/build.sh` install —
expected for a dev build.) **Never hand-swap with a bare `cp` + `open`** (the old recipe); it
reintroduces the password storm.

## Releasing

**IMPORTANT: `scripts/build.sh` is the ONLY way to create a release.** Do not manually zip, sign, notarize, or upload. The script handles everything:

1. `swift build -c release`
2. Create `.app` bundle with Info.plist
3. Code sign with Developer ID (hardened runtime + timestamp + entitlements)
4. Verify signature
5. Create DMG with Applications symlink
6. Sign DMG
7. Submit to Apple for notarization (waits for approval)
8. Staple notarization ticket to DMG
9. *(with `--release`)* Create GitHub release and upload DMG

```bash
# Required env var (signing identity — see memory for value)
export DEV_ID_APPLICATION="Developer ID Application: ..."

# Build + sign + notarize (no publish)
./scripts/build.sh 0.5.0

# Build + sign + notarize + publish to GitHub Releases
./scripts/build.sh 0.5.0 --release --notes "Fix tab close crash"
```

**Never do any of these manually:**
- Do not `zip` the app bundle — releases are DMGs, not zips
- Do not `codesign` outside the script — the script ensures correct flags
- Do not `xcrun notarytool submit` outside the script — the script handles submission, waiting, and stapling
- Do not `gh release create` outside the script — use `--release`
- Do not skip any step for "quick" releases — every release must be signed AND notarized

## Key Design Decisions
- Terminal views are kept alive in a ZStack (hidden via AppKit isHidden) to preserve running processes when switching tabs
- Sessions persist to `~/Library/Application Support/ConsoleForge/sessions.json`
- PtyProcess uses posix_spawn (not forkpty) for hardened runtime compatibility
- Claude binary is resolved via common path search at startup, configurable in Settings (Cmd+,)
- Login shell (`zsh -l -c`) used to inherit user's PATH for running CLI tools

## Session Configuration Fields
- name, workingDirectory, model, permissionMode, effort
- systemPrompt, appendSystemPrompt, initialPrompt
- allowedTools, disallowedTools, mcpConfigPath
- additionalFlags (raw CLI flags, one per line)
- tabColorHex, tabIconName (SF Symbol), autoStart, continueSession, openInConsoleForge
