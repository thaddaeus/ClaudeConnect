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

## Workspace slot layout

The detail area is a **slot container** (`Views/Workspace/WorkspaceView.swift`), not a
single pane. SLOTS are fixed named positions (`left`, `center`, `right`, laid out
left → right); SECTIONS are movable content dropped into them. Sections are named by
ENGINE, not by role — `.browser` displays as **Safari** (the in-app WKWebView), so
Phase C's managed Chrome can sit beside it without either going ambiguous. Raw values
are the `layout.json` persistence keys; never rename them.
Layout is per-**window**, not per-tab — switching console tabs never rearranges it.
Persisted to `layout.json` beside `sessions.json`, so a bad layout can be deleted
without touching sessions.

Every slot decides independently — pinning is combinatorial, not one global policy:

| Property | Values |
| -------- | ------ |
| size | PINNED (an explicit fraction **of the window**) or FLEXIBLE (absorbs leftover) |
| display | TILED (consumes layout space) or FLOATING (docked overlay, consumes none) |

**Floating is a docked overlay, not a free window.** The panel keeps the edge its slot
came from (`SlotID.floatsToTrailingEdge`), spans the full height, and takes
`pinnedFraction` as its width. It consumes no layout space in *any* state, collapsed
included — so the tiles underneath resolve as if it were not there, and resizing,
collapsing or maximising the overlay afterwards cannot move them. Dragging its header
into another slot re-anchors it to that edge; dragging its inner edge resizes it.
Full Width on a floating panel just covers the window and leaves the tiles alone.

Size arithmetic lives in `WorkspaceLayout.resolve(in:)` and is the whole point of the
feature — *the console must not resize when a browser closes*:

- A pinned fraction is of the WINDOW, so it survives a sibling closing.
- Leftover after pins splits evenly among flexible slots.
- An **empty slot that is PINNED reserves its fraction as a GAP** at its own position —
  a hole held open for a panel that is not there yet. This needs no separate concept: a
  slot keeps its pin when its section is moved out or closed, so "leave a 30% hole where
  Safari was" is just the slot, still pinned. Dropping any section there fills it
  exactly; a flexible neighbour cannot swallow it; right-click releases it. The header's
  pin button pins a section at its *current* width, which is how a gap gets made.
  **Closing** a pinned section holds its space; **moving** one releases it — a move is
  repositioning, not reserving, and a phantom gap would shove everything sideways.
- Any leftover beyond the pins stays EMPTY at the trailing edge. Nothing stretches
  into it.
- A FLOATING slot contributes nothing to this arithmetic — the tiled layout resolves
  exactly as if that section did not exist.
- Pins over 100% scale down proportionally; flexible slots keep a `minSlotWidth` floor.
- A slot that cannot reach its section's minimum width **collapses to a rail** rather
  than rendering a useless sliver. The rail is chrome-width (152pt), not a thin strip:
  it carries the section's real header — pin, Collapse/Normal/Full Width, menu — over a
  click-anywhere expand area, so a collapsed panel is somewhere you can act from. A
  22pt strip made those buttons impossible to hit. The console's minimum is a standard
  **80 columns** (`TerminalMetrics.minimumWidth` — measured from the live font, ≈544pt
  at Menlo 11pt), because output written to wrap at 80 wraps mid-word below that. The
  last remaining tiled slot never collapses. Clicking the rail restores the slot.
  A collapsed section stays in the view tree at **zero width** — never removed, so its
  NSView survives, and never resized, because a zero width is rejected on the way into
  `setSize`.

`TerminalMetrics` owns the terminal font; `TerminalSession` reads it from there so the
rendered font and the layout engine's column arithmetic cannot drift.

**The load-bearing rule (tasks 9543 / 9487 — permanent terminal garble is SwiftTerm
BUFFER MODEL corruption from reflowing at a wrong size):** every section is rendered
exactly once at a structurally fixed position in the workspace ZStack and moved only by
changing `.frame` + `.offset`. Nothing is ever re-parented, so `TerminalContainerView`
keeps its identity across every move / pin / float / splitter drag, and the console's
container NSView reports its new bounds through the *existing* `frameDidChange` →
`TerminalSessionManager.setSize` path with its 140 ms trailing debounce. Never set a
frame on a terminal view, never animate a slot rect, and never add a second resize path.
Watch for `if/else` in the view tree around a section (that is what
`FloatingDecoration` avoids) — a `_ConditionalContent` swap changes structural identity
and rebuilds the hosted NSView.

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
