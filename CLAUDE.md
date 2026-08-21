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

## Testing

Two tiers, and the split is not a compromise — they test different things.

**Tier 1 — `swift test`.** Pure model and logic, no app, milliseconds, runs on every PR
(`.github/workflows/tests.yml`). `@testable import ConsoleForge` reaches the executable
target, so `WorkspaceLayout`, `LayoutStore`, `TabStripModel`, `ClaudeProcessBuilder`,
`TerminalMetrics` and `SessionConfiguration` decoding are all directly testable. Nothing
had to be refactored for this; there simply was no test target until 2026-08-21.

**Tier 2 — the live harnesses in `scripts/`.** `geometry-pass.py` (terminal geometry
through the real Layout menu) and `chrome-lifecycle-test.py` (25 teardown checks). These
cover what a unit test structurally cannot: AppKit hosting, real SwiftTerm reflow, Chrome
under launchd. Beta only. Do not try to move these into Tier 1 — and do not skip them for
anything touching layout, terminal sizing, or the browser lifecycle.

**Fixtures (`Tests/Fixtures/`) are shared by both tiers.** Every layout bug so far has been
a SAVED STATE plus an ACTION, and the state kept getting hand-written as throwaway JSON at
debug time. A fixture is named for the situation (`parked-in-occupied-cell`), decoded
directly by Swift tests and copied into the beta support directory by the python harnesses
— the same file, so a permutation checked in one tier cannot silently differ from the
other. `Fixture.url` resolves from the source tree rather than a test bundle for exactly
that reason.

### The two rules that keep this true

**A feature's acceptance criteria become its test names.** Not a paraphrase — the criteria
ARE the list. Task 990039 shipped a bug because its criteria were prose and the
occupied-target permutation was never written down; as test functions it would have been a
visibly missing one.

**A bug fix ships a test that FAILS without the fix.** Write it, watch it fail, then fix.
This is the only mechanical proof the test covers the bug rather than the fix's happy path.
`LayoutStoreMoveTests` was verified this way: reverting `move()` to its v0.9.7 form fails
3 of its 5 tests on 6 assertions.

**Corollary, earned:** a check that cannot run must FAIL, never pass quietly.
`geometry-pass.py` once compared zero grid pushes because the beta had no open tabs — a
check measuring nothing is indistinguishable from a check that passed. Both the CI job and
that harness now refuse to report green on an empty run.

## Workspace slot layout

The detail area is a **slot container** (`Views/Workspace/WorkspaceView.swift`), not a
single pane. SLOTS are the cells of a **real 2 × 3 grid** — rows `top`/`bottom` (the Y
axis) × columns `left`/`center`/`right` (the X axis); SECTIONS are movable content
dropped into them. `SlotID` stays a flat `String` enum (`topLeft` … `bottomRight`)
because its raw values are `layout.json` keys; pre-Y files wrote `left`/`center`/`right`
and decode into the top row via `SlotID.init(legacy:)`.

**The grid is real: a COLUMN owns one x and one width for the whole window** (task
990039). `bottomRight` is genuinely under `topRight`, at the same width. This document
used to claim a 2 × 3 grid and then, forty lines later, that "the X arithmetic runs
independently inside each row" — and the code did the second thing: each row packed its
occupied slots from x = 0 and skipped the empty ones, so a panel dropped in `bottomRight`
began at the LEFT edge and, alone in its row, swallowed the whole width. The names
promised a grid nobody had built, which is how it survived a phase unnoticed. Width now
lives in `ColumnConfiguration` (the X twin of `RowConfiguration`) and never on a cell.

**Pinning is a WIDTH concept, and width is a COLUMN property — rows have no
pinned/flexible switch and neither does an individual cell.** A lone row FILLS the
height; height is only constrained once a second row sits under the first, and then
`RowConfiguration.heightFraction` is how they split it (the row splitter sets it). A row
is floored at the tallest minimum its VISIBLE sections declare — the console's is 24
terminal rows, the companion to its 80-column width floor — and when floors overflow, the
excess comes off the rows with SLACK above their own floor, never by scaling everything
down (that would push a floored row back under its minimum). Sections are named by
ENGINE, not by role — `.browser` displays as **Safari** (the in-app WKWebView), so
Phase C's managed Chrome can sit beside it without either going ambiguous. Raw values
are the `layout.json` persistence keys; never rename them.
Layout is per-**window**, not per-tab — switching console tabs never rearranges it.
Persisted to `layout.json` beside `sessions.json`, so a bad layout can be deleted
without touching sessions. `layout.json` gained a `columns` key; a file without one is a
pre-column layout, and each pinned SLOT's fraction is lifted onto its column on decode so
a saved arrangement keeps the widths it had.

Each axis and each cell decides a different thing:

| Property | Owner | Values |
| -------- | ----- | ------ |
| width | COLUMN | PINNED (an explicit fraction **of the window**) or FLEXIBLE (absorbs leftover) |
| height | ROW | a share of the window height; a lone row fills |
| display | CELL | TILED (consumes layout space) or FLOATING (docked overlay, consumes none) |

Pinning is still combinatorial — three columns, each independently pinned or flexible —
it is just not per-cell, because two cells of one column cannot be two widths.

**The browser's console and network output is captured IN-APP.** The point of an
in-tool browser is that the session can see what the page is doing, and Web Inspector
cannot deliver that: WebKit owns its inspector window, there is no public API to host it
in a slot, and driving it from Safari puts the output somewhere neither the app nor the
agent can reach. (Do not try WebKit's private developer-extras preference for a
right-click "Inspect Element" — it docks an inspector *inside* the web view, which a
third-party host cannot render, and the panel goes half-dead.)

Instead `WebConsoleScript` is injected at document start and patches `console.*`,
`window.onerror`, `unhandledrejection`, `fetch` and `XMLHttpRequest`, posting to
`WebConsoleBridge` → `WebConsoleLog`. That surfaces two ways: the **Web Output** section
(⌘⇧J), a slot panel like any other; and `…/ConsoleForge[ Beta]/web-console/session.jsonl`,
which a session can `tail` — the panel's terminal button copies that path. What this does
NOT reach: subresource loads the browser issues itself (images, CSS, fonts, scripts,
beacons) and anything before the script runs. Full request capture needs a real debugging
protocol, which is Phase C's managed Chrome with `--remote-debugging-port`.
`isInspectable` stays set (criterion 7) as an escape hatch, with an "Open in Safari"
button beside it.

**Floating is a docked overlay, not a free window.** The panel keeps the edge its slot
came from (`SlotID.floatsToTrailingEdge`), spans the full height, and takes
`SlotConfiguration.floatingFraction` as its width — the one width still owned by a cell,
because a floating panel is not a member of the grid. Its `layout.json` key stays
`pinnedFraction`, which is what pre-column files wrote. It consumes no layout space in
*any* state, collapsed included — so the tiles underneath resolve as if it were not
there, and resizing, collapsing or maximising the overlay afterwards cannot move them. Dragging its header
into another slot re-anchors it to that edge; dragging its inner edge resizes it.
Full Width on a floating panel just covers the window and leaves the tiles alone.

**The trailing-edge rail is ALWAYS there, and it lists every section** — on screen,
collapsed, or closed (`SectionRailView`). Without it the default state advertised
nothing: headers only appear once a second section is open, so a lone console showed no
header, no rail, and no hint that Safari, Web Output or Documents existed at all — the
whole feature was reachable only from the menu bar, which you had to already know about.
One click on a row opens a closed section, parks a visible one, or brings a parked one
back; the row's own context menu and the sliders button at the foot of the rail carry
the layout controls, so they never vanish. A rail row is a SHOW/HIDE switch and never a
close button — closing discards a panel, so that stays a deliberate act on the header's
✕ or in a menu.

**Moving a section is spatial.** The header's grid button opens a 2 × 3 picture of the
window (`SlotGridPicker`); hovering a cell says what would be displaced and where it
lands, so the consequence is on screen before the click. The menu path states the same
outcome — "Top Right — Safari moves to Top Center". Neither says "swap with": one
section per cell is a fine rule, but naming the mechanism described the implementation
and made a move read as a warning. **Pin sits with the size controls** in the header,
not across a Spacer from them — it fixes the width, so it is a sizing control, and
across a Spacer it was the one control you had to hunt for.

The rail costs the console **nothing new**: `railStripeWidth` has been a permanently
reserved gutter since the jump-on-collapse fix, and it is `collapsedRailWidth` (34pt)
wide whether or not anything is collapsed. That constancy is load-bearing — a rail that
grew as panels opened would resize the console, which is the exact thing pinning exists
to prevent. 34pt gives each row a **34 × 34pt** hit rectangle, bigger in both axes than
any control the app already ships (the section header's are 18×16 and 20×16) and than an
AppKit push button (21pt). The 22pt rail that failed earlier was 22pt WIDE and carried
the *whole* header — pin, two size segments, menu, collapse, close — at roughly 22×11pt
per target; one control per row is a different control. The rail REPLACED the tall
per-collapsed-section tab rather than coexisting with it (two representations of one
collapsed section will not fit in 34pt), but it COEXISTS with the per-section header,
which is still the drag source for moving a section between slots and still carries
pin-at-current-width — neither survives a 34pt stripe.

Size arithmetic lives in `WorkspaceLayout.resolve(in:)` and is the whole point of the
feature — *the console must not resize when a browser closes*:

- A column is **LIVE** when any of its cells shows a section, or when the column is
  PINNED. A dead column takes no space at all, so the default lone console still fills
  the window.
- A pinned fraction is of the WINDOW, so it survives a sibling closing.
- Leftover after pins splits evenly among flexible LIVE COLUMNS.
- Leftover beyond the pins stays EMPTY, and it falls **where the missing columns are**:
  `left` starts at the leading edge, `right` ENDS at the trailing edge, `center` is
  centred between them. Pinning the right column to 50% therefore leaves the empty half
  on the LEFT. (It used to sweep all leftover to the trailing edge, which is why a
  right-hand slot anchored left.)
- An **empty CELL of a live column is a GAP** — real space the grid owns, at the cell's
  own position, and a drop target that fills it exactly. This is no longer a concept of
  its own: the cell under an occupied one holds its column open automatically, and
  "reserved" just means that column is PINNED with nothing in it. **Closing** a section
  holds its column's space; **moving** one releases the pin *if the move emptied the
  column outright* — a move is repositioning, not reserving, and a phantom reserved
  strip would shove everything sideways. A column that still holds something keeps its
  width, because the remaining cell needs it.
- A FLOATING cell contributes nothing to this arithmetic — the tiled grid resolves
  exactly as if that section did not exist, and a floating cell does not make its column
  live.
- Pins over 100% scale down proportionally; flexible columns keep a `minSlotWidth` floor.
- A cell that cannot reach its section's minimum width **collapses**, rather than
  rendering a useless sliver — it goes back to being a row in the rail. The console's
  minimum is a standard **80 columns** (`TerminalMetrics.minimumWidth` — measured from
  the live font, 584pt at Menlo 11pt), because output written to wrap at 80 wraps
  mid-word below that. The last section on screen never collapses; instead its column is
  widened to the section's floor.
- There is ONE splitter per boundary between adjacent live columns, spanning every live
  row. A per-row handle would be two controls editing one number, and they could be
  dragged into disagreeing — the exact class of bug the grid removes.
  A collapsed section stays in the view tree, **parked off-canvas at a usable width** —
  never removed, so its NSView survives, and never reflowed, because the container never
  takes a degenerate size in the first place. Parking at zero width was a trap: it left
  the container one unguarded frame write from a 2-column reflow.

`TerminalMetrics` owns the terminal font; `TerminalSession` reads it from there so the
rendered font and the layout engine's column arithmetic cannot drift.

**A column is not a fixed number of points.** SwiftTerm snaps its cell to the display's
pixel grid, and since v1.16.0 to the NEAREST device pixel rather than always up — so
Menlo 11's 6.6226pt advance is a **6.5pt cell at 2x and a 7.0pt cell at 1x**.
`TerminalMetrics.cellWidth(scale:)` reproduces that arithmetic and every
columns/rows/isUsable call takes the scale of the screen its window is on
(`@Environment(\.displayScale)`, or `window?.backingScaleFactor` on the mount path).
Getting it from the wrong display is a ~7% error — one column in fourteen — and it
shows up as a container/grid disagreement in the HUD, which is the alarm that is
supposed to mean something. The layout engine's `minimumWidth` is the exception: it is
scale-free by construction, so it is built from the WIDEST cell (1x), which can only
over-reserve. `chrome` (17pt) is a point offset for SwiftTerm's reserved scroller plus
our inset and is unaffected by any of this. **Re-verify against a fresh geometry trace
whenever the SwiftTerm pin moves** — this is exactly what the 0f2af750 → v1.19.0 bump
had to pay for.

**Beta-only geometry instrumentation.** `GeometryTrace` records the whole chain —
container px → SwiftTerm grid → PTY winsize — including every REJECTED and coalesced
size, to a ring buffer, a HUD (Layout ▸ Show Geometry Debug, ⌘⇧D) and
`…/ConsoleForge Beta/debug/geometry.jsonl` that a session can read. Gated on
`GeometryTrace.isEnabled` = `!AppChannel.isProduction`, the same switch as the beta
support directory and Keychain namespace, so production ships no buffer, no file handle
and no HUD. The HUD flags it when the container's column count and SwiftTerm's grid
disagree — that mismatch is the whole bug class.

**Verifying the terminal never regresses: `./scripts/geometry-pass.py`.** The manual
protocol for this was nine steps that each had to be performed exactly, which is a trap
rather than a test — and the most important check is one a human cannot perform at all:
noticing a reflow that happened when NOBODY ASKED FOR ONE. A spontaneous reflow looks
like nothing. So the script drives ~40 gestures through the Layout menu BY NAME (never
mouse coordinates, so each step is exact), timestamps every one, and grades them against
`geometry.jsonl`: zero rejected geometries, zero container/grid disagreements, zero
reflows without a gesture behind them, and the console holding its WIDTH when a sibling
closes (its height may legitimately change — a lone row fills). Beta only; production
writes no trace. Re-run it for any change that touches layout or terminal sizing. It does
NOT cover sleep/wake or display connect/disconnect — do those by hand.

There are exactly TWO writers of a terminal view's frame — `TerminalSession.resize`
(reached only from the manager) and the mount in `TerminalHostView.updateNSView`. Both
are gated on `TerminalMetrics.isUsable`. Adding a third, or ungating either, is how the
buffer gets destroyed.

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

## Tabs: view kinds and per-strip contiguity

A tab is a **`ViewKind`**: `.terminal` (a Claude CLI session with a PTY) or `.document`
(a read-only file). "Session" used to mean "thing with a PTY" everywhere — `PtyProcess`,
`ClaudeProcessBuilder`, `autoStart`, resume, the voice channel, `PendingPromptProbe` — so
**every one of those paths now reads `SessionStore.terminalTabIDs`, never `openTabIDs`**.
`resolveLaunch` refuses a non-terminal tab outright, so a launch is structurally
impossible even if a future caller forgets the filter.

**Each strip owns its own selection.** `activeTabID` is the CONSOLE strip's (the name and
the JSON key predate this, and half the app reads it) and is guaranteed to name a
terminal tab; `activeDocumentTabID` is the Documents strip's. Clicking a document must
never move `activeTabID` — that would unmount the console's terminal view.
`focusedKind` tracks the strip you last picked a tab in and drives ⌘W, next/previous
and ⌘1–9.

**Contiguity is PER STRIP, and lives in `TabStripModel`** — a pure value type over ids,
deliberately outside `SessionStore` so a harness can reach it (Phase A's third bug was a
sizing rule that lived only in the store, which is why nothing caught it). `openTabIDs`
stays one flat list holding both kinds; a strip is that list filtered to its kind, and a
reorder writes back only into the slots that kind already held — so a reorder in one
strip *cannot* move a tab in the other. A group is a contiguous run WITHIN a strip, which
is as strong as the invariant can be once a parent in the console strip has children in
the document strip. Contiguity is tested as "every member of the group occupies
consecutive positions", NOT "is the moved tab inside the run starting at its parent":
with no in-strip parent to anchor to, that older scan found a dragged tab at the head of
its own one-tab run and called the group intact while its sibling sat stranded.

**Closing a console tab that parented DOCUMENT children prompts** (`requestCloseTab` →
`pendingClose` → the dialog in `ContentView`) rather than silently orphaning them.
Terminal worktree-tab grouping is deliberately unchanged: console children of a closing
console tab still orphan silently. Non-interactive closes — the CLI's `--close-self`, a
process exit — call `closeTab` directly and never prompt.

The Documents section is a **read-only viewer** by decision, not omission (Tadd,
2026-08-12). Its `layout.json` key stays `editor` — renaming a persistence key to track a
scope decision would orphan every saved layout — but its user-facing name says what it
does. No save path, no dirty state, no file watcher; the toolbar's Reload is how an
external change is picked up.

## Managed Chrome (Phase C)

A tab owns **up to two** browsers, and which one you get is the whole design.

| | profile | window | for |
| --- | --- | --- | --- |
| `.headless` | `chrome-profiles/<tabID>/headless` | never exists | the agent — testing, discovery, screenshots |
| `.windowed` | `chrome-profiles/<tabID>/window` | on demand | you, reviewing or signing in |

**Headless is the default because focus theft, not clutter, was the actual problem.** A
Chrome window grabs focus when it launches and eats keystrokes being typed into another
session. A headless browser has no window, so it cannot. It still renders for real —
`Page.captureScreenshot` and the whole protocol work — so the agent loses nothing.

**Soft attach, never a pixel embed.** Chrome is spawned as a **child process** (`Process`,
launching the binary directly) rather than handed to `open`, which would detach it into
launchd and leave nothing to terminate. Embedding would mean CEF: a second browser engine
to keep patched, for a rectangle.

**Two profiles, because two Chromes cannot share a `--user-data-dir`** (single-instance
lock). That is a real seam: a login done in the window is invisible to the headless one.
The resolution is that BOTH publish a debugging port, so after signing in the agent
simply drives the windowed browser — no cookie copying, no swapping processes and losing
page state. `…/chrome/<tabID>.json` lists every browser the tab owns with a `browserUrl`
ready for `chrome-devtools-mcp --browserUrl`; `consoleforge-tab --browser-info` prints it.

A session can call `consoleforge-tab --browser-window [URL]` to produce a window — the one
thing it cannot do for itself, and what it needs when it hits a sign-in wall. That is
deliberately the ONLY browser verb in the CLI: general session→browser control is task
9925.

Four teardown paths, all tested by `./scripts/chrome-lifecycle-test.py` (25 checks):
closing the tab (both browsers), the CLI close path, quitting the app, and
**force-killing** it — a child is NOT killed by its parent dying, so SIGKILL strands the
browser under launchd. Each instance records its pid so `reapOrphans()` kills leftovers at
next launch; a recorded pid is never trusted alone, since pids are recycled, so each is
verified to still be a Chrome running against OUR profile first. Profiles are pruned when
the SESSION is gone, not when the tab closes — a saved session keeps its logins.

Note `~/.local/bin/consoleforge-tab` symlinks to the MAIN checkout, so CLI changes on a
branch are invisible there until they merge; test a branch against `./scripts/consoleforge-tab`.

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
