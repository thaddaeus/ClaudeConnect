# ConsoleForge Companion — Design Spec

A phone companion for ConsoleForge that shows live tab status and pushes alerts
when a tab finishes a turn, goes quiet, or exits — even when you're away from your
Mac and the companion app is closed.

Status: **design** (no code yet). This document is the contract; implementation
follows it.

---

## 1. Goals & non-goals

**Goals**
- See the live status of every open ConsoleForge tab on your phone (name, color,
  state, working dir, last-update time).
- Get a push notification when a tab needs you — Claude finished a turn / hit a
  prompt (bell), or a background tab streamed output and then went quiet ("settled").
- Work **anywhere** (cellular, off your WiFi) and fire **even when the PWA is closed**.
- **GitHub login is required** to use the companion. One identity ties together the
  Mac(s), the phone(s), and support requests.
- Signing in on the Mac **mints a long-lived device token**; the phone signs in with
  the same account and automatically sees that account's Macs.

> **Unified-login model** (revised 2026-06-01, supersedes the original accountless
> design). One GitHub login is the single source of identity, but the three concerns
> still use distinct *tokens* so the background poster never depends on a refreshable
> OAuth token:
> 1. **User identity** → GitHub login (required, up front).
> 2. **Bridge transport auth** → a long-lived **device token** that login *mints*
>    server-side. The Mac→relay poster uses this token, never the OAuth/session token,
>    so it survives OAuth expiry while you're away.
> 3. **Support backend** → pluggable intake, authed by the **session token** from the
>    same login; first adapter is GitHub Issues.
> Rationale: requiring login gives one mental model and ties support + multi-device to
> a real identity, while login-bootstrapped device tokens keep the unattended poster
> stable (the hard constraint from the original design is preserved).

**Non-goals (v1)**
- Two-way control (typing into a tab from the phone). Read/alert only.
- Multiple Macs fanning into one phone view (single Mac ↔ one-or-more phones is enough).
- Historical/analytics. We keep only the latest snapshot per device.

---

## 2. Architecture

Three components across two repos. The Cloudflare Worker is not just a companion
bridge — it's the **ConsoleForge backend**: companion bridge + GitHub auth + support
intake, all behind one origin and one deploy.

```
┌─────────────────────────┐   POST /v1/events (device token)   ┌────────────────────────────┐
│  ConsoleForge (macOS)   │ ──────────────────────────────────▶│  Backend (CF Worker)       │
│  • TabActivityTracker   │   POST /v1/support (user/GitHub)    │  • snapshot + subscriptions│
│  • CompanionService     │ ──────────────────────────────────▶│  • Web Push sender         │
│  • SupportReporter      │ ◀──────  (no inbound to Mac)        │  • GitHub OAuth verify     │
└─────────────────────────┘                                    │  • Support → GitHub Issues │
                                                                │  • serves PWA assets       │
                                           Web Push (APNs/FCM)   └──────────┬─────────────────┘
                                          ┌────────────────────────────────┘     │
                                          ▼          GET /v1/status, /v1/subscribe│ GitHub App
                                 ┌──────────────────┐ ◀──────────────────────────┘ (bot token)
                                 │  PWA (phone)     │                              ▼
                                 │  • service worker│              ┌───────────────────────────┐
                                 │  • status screen │              │ private backend repo      │
                                 └──────────────────┘              │  Issues (one per report)  │
                                                                   └───────────────────────────┘
```

- **macOS app changes** live in this repo (`ClaudeConnect`).
- **Backend + PWA** live in a **new private repo** (`consoleforge-backend`). One
  Cloudflare Worker serves both the static PWA (Workers Static Assets) and the API,
  so there's a single origin and a single deploy.

The Mac only ever makes **outbound** HTTPS calls. Nothing needs to reach the Mac,
so there's no inbound port, no firewall hole, no Bonjour.

---

## 3. Detection: what counts as an "alert"

ConsoleForge already classifies per-tab activity in `TabActivityTracker`
(`ConsoleForge/Models/TabActivity.swift`): `.idle`, `.active`, `.output`, `.bell`,
plus process termination. We map those to companion events:

| Companion event | Source signal | Push? |
|---|---|---|
| `bell`    | `didReceiveBell` → `.bell` (Claude rang the terminal bell: turn done / permission prompt / question) | **Yes** |
| `settled` | A background tab received output, then **no further output for `settleSeconds` (default 3s)** | **Yes** |
| `exited`  | Tab process terminated (`SessionState.terminated`, carries exit code) | **Yes** |
| `active`/`output`/`idle` | Ordinary state changes | No — snapshot only |

### Why `settled` instead of raw output
Claude sessions stream output almost continuously, so alerting on every output
chunk would be a firehose. The useful signal is the **trailing edge**: a tab that
was streaming goes quiet. That closely tracks "the turn just finished" and fires
once per turn instead of thousands of times.

Implementation: a per-tab debounce timer. Each output chunk on a **background** tab
(re)starts a `settleSeconds` timer; if it elapses with no new output, emit one
`settled` event. Focusing the tab cancels its pending timer (you're already looking).
Foreground tabs never settle-alert.

`settleSeconds` is user-configurable (default 3s); set to 0 to disable the settled
trigger and rely on bell only.

---

## 4. macOS app changes (this repo)

### 4.1 New types

- **`CompanionSettings`** (UserDefaults-backed, `@AppStorage` where it drives UI):
  - `companionEnabled: Bool`
  - `relayBaseURL: String` (e.g. `https://companion.example.workers.dev`)
  - `alertOnBell: Bool` (default true)
  - `alertOnSettled: Bool` (default true)
  - `alertOnExit: Bool` (default true)
  - `settleSeconds: Double` (default 3)
  - `deviceId: String` — stable UUID per install (UserDefaults).
- **`deviceToken`** — random secret generated on first enable, stored in **Keychain**
  (never UserDefaults, never the repo). Used as the bearer token on `/v1/events`.

- **`CompanionService`** (`@Observable`, in `Services/`):
  - Owns `deviceId` + `deviceToken`, builds and POSTs events.
  - **Offline queue**: if a POST fails (no network), enqueue in memory (bounded,
    e.g. last 50 events) and flush on next success. Coalesce duplicate snapshot
    updates for the same tab.
  - Exposes `pair() -> code` (see §6) and `enqueue(event:)`.

### 4.2 Wiring detection → events

`TabActivityTracker` gains an optional event sink (closure or delegate) so it can
report transitions without taking a hard dependency on networking:

```swift
var onCompanionEvent: ((CompanionEvent) -> Void)?
```

- `didReceiveBell` (background) → emit `bell`.
- `didReceiveOutput` (background) → (re)start that tab's settle timer; on fire → emit `settled`.
- `didFocusTab` → cancel that tab's settle timer.
- Process termination (hook in the same place `TabEventWriter.emitClose` is called
  for `processExit`) → emit `exited` with exit code.
- Any state change also emits a **snapshot** update so `/v1/status` stays current.

`CompanionService` decides whether each event also *notifies* (based on the
`alertOn*` prefs) and sets the `notify` flag on the payload.

### 4.3 Settings UI

Extend `Views/SettingsView.swift` with a **Companion** section:
- Enable toggle + relay URL field.
- "Pair a phone" button → shows a 6-char pairing code (and a QR encoding
  `relayBaseURL` + code) with a countdown to expiry.
- Alert checkboxes (bell / settled / exit) and a `settleSeconds` stepper.
- Connection status line (last successful POST, queued count).

### 4.4 Tab metadata available to send

Per tab we can include: `id` (UUID), `name`, `tabColorHex`, `tabIconName`
(SF Symbol), `workingDirectory`, current `state`. (All already on
`SessionConfiguration` / tracked state.)

### 4.5 GitHub login + support (Phases 4–5)

- **`AuthService`** — GitHub OAuth via `ASWebAuthenticationSession`; sends the code to
  the backend, receives + stores the app session token in Keychain. Login is lazy
  (only when the user opens Support or enables multi-device).
- **`SupportReporter`** — gathers category/title/body + opt-in scrubbed diagnostics and
  POSTs `/v1/support`. A **Help menu** ("Report a Bug", "Get Help", "My Requests") and
  a small report sheet; "My Requests" lists the user's issues + status via
  `/v1/support/mine`.

---

## 5. Event & API schemas

### 5.1 Event (Mac → relay)

`POST /v1/events`  ·  `Authorization: Bearer <deviceToken>`

```jsonc
{
  "v": 1,
  "deviceId": "C2A1...UUID",
  "events": [
    {
      "tabId": "9F3C...UUID",
      "name": "claude — myapp",
      "colorHex": "#FF2D55",
      "icon": "terminal",            // SF Symbol name; PWA maps to its own glyph
      "workingDirectory": "/Users/tadd/projects/myapp",
      "state": "bell",               // bell | settled | exited | active | output | idle
      "exitCode": null,              // present only when state == "exited"
      "notify": true,                // relay pushes iff true
      "ts": "2026-05-27T17:48:00Z"
    }
  ]
}
```

Batched array so the offline queue can flush several at once. Relay updates the
per-`tabId` snapshot for every event and sends a push for those with `notify: true`.

### 5.2 Subscribe (PWA → relay)

`POST /v1/subscribe`

```jsonc
{
  "code": "K7P2QX",                  // pairing code shown on the Mac
  "subscription": { /* PushSubscription.toJSON() */ },
  "ua": "iPhone; iOS 18.x"           // optional, for debugging
}
```

Returns a `readToken` the PWA uses to call `/v1/status`. Relay resolves
`code → deviceId`, stores the subscription under that device, and discards the code.

### 5.3 Status (PWA → relay)

`GET /v1/status`  ·  `Authorization: Bearer <readToken>`

```jsonc
{
  "deviceId": "C2A1...",
  "updatedAt": "2026-05-27T17:48:00Z",
  "tabs": [
    { "tabId": "9F3C...", "name": "claude — myapp", "colorHex": "#FF2D55",
      "icon": "terminal", "state": "settled", "workingDirectory": "...",
      "ts": "2026-05-27T17:48:00Z" }
  ]
}
```

The PWA pulls this on open / focus (and after receiving a push) to render the full
board; pushes are the real-time nudge.

### 5.5 Support (app/PWA → backend)

`POST /v1/support`  ·  `Authorization: Bearer <userSessionToken>`

```jsonc
{
  "category": "bug",                 // bug | help | feature
  "title": "Tab dot stays blue after focus",
  "body": "Steps: ...",
  "diagnostics": {                   // opt-in, scrubbed
    "appVersion": "0.6.0",
    "os": "macOS 15.4",
    "logTail": "…redacted…"
  }
}
```

Returns `{ "issueNumber": 142, "url": "https://github.com/.../issues/142" }`.

`GET /v1/support/mine` · `Authorization: Bearer <userSessionToken>` →
`{ "requests": [ { "issueNumber": 142, "title": "...", "state": "open",
"category": "bug", "updatedAt": "..." } ] }`

### 5.4 Push payload (relay → PWA via Web Push)

```jsonc
{
  "title": "claude — myapp",
  "body": "Turn finished — needs your input",   // varies by state
  "tag": "9F3C...",                              // collapse repeats per tab
  "state": "bell",
  "ts": "2026-05-27T17:48:00Z"
}
```

---

## 6. Auth & device enrollment (login-required)

All flows hang off one GitHub login (see §7). No pairing codes.

1. **Mac sign-in** → `ASWebAuthenticationSession` runs the GitHub OAuth flow (§7).
   On success the Worker mints, for this `github_id` + `deviceId`:
   - a **device token** (long-lived, random) → stored in the Mac Keychain; the
     `POST /v1/events` poster authenticates with it. Bound to the user.
   - a **session token** (for `/v1/support*`) → also Keychain.
2. **Phone sign-in** → the PWA runs the same GitHub OAuth flow and receives a
   **read token** scoped to that user. It then requests notification permission, gets
   a `PushSubscription`, and calls `/v1/subscribe` (authed by the read token). The
   subscription is stored under the **user**, so it receives pushes from any of that
   user's Macs.
3. Multiple Macs and multiple phones per account: events fan in by `github_id`,
   pushes fan out to all the user's subscriptions.

**Token model:** `deviceToken` (Mac, write), `readToken` (phone, read), and the
support `sessionToken` are independent and all derived from one identity. A phone
holds only a read token, so it can never post fake events. Losing the OAuth token
never stops the poster — it runs on the long-lived device token.

---

## 7. User identity (GitHub login) — required, up front

Login is the **entry point** to the companion (not lazy). Until the user signs in,
the Mac has no device token and the phone has no read token, so nothing flows.

- **Flow:** GitHub OAuth, Authorization Code with a **confidential client** — the
  **Worker holds the client secret** and performs the `code → access_token` exchange;
  the secret never ships in the app or PWA. A signed `state` value guards CSRF.
  - **macOS:** `ASWebAuthenticationSession` opens `GET /v1/auth/start?platform=mac`
    (callbackURLScheme `consoleforge`). The Worker redirects to GitHub; GitHub calls
    back to `GET /v1/auth/callback`; the Worker exchanges the code, upserts the user,
    mints a **device token** + **session token**, and 302s to
    `consoleforge://auth/callback#device=…&session=…`. `ASWebAuthenticationSession`
    captures that and the app stores both in Keychain.
  - **PWA:** navigates to `GET /v1/auth/start?platform=web`; after the GitHub callback
    the Worker redirects back to `/` with a **read token** (in the URL fragment); the
    PWA stores it and proceeds to push subscription.
- **Scopes:** minimal — `read:user` (+ `user:email` for contact). We do **not** request
  `repo`: issues are authored by our GitHub App/bot, not the user's token (see §8).
- **Identity:** Worker keys everything on a stable `github_id` (+ `login`, `avatar`).
  Device tokens, read tokens (subscriptions), and the support session token are all
  bound to it but remain independent secrets.

## 8. Support intake (Report a Bug / Help)

Primary surface is the **macOS app** (Help → Report a Bug / Get Help); the PWA is a
secondary surface. Backend is **pluggable** — first adapter is GitHub Issues.

- **`SupportReporter`** (macOS) collects: `category` (bug | help | feature), `title`,
  `body`, and opt-in **diagnostics** (app version, macOS version, redacted recent log
  tail). User consents before diagnostics attach; secrets/paths scrubbed.
- `POST /v1/support` `{ category, title, body, diagnostics }` with the user session
  token (from §7).
- The Worker creates a **GitHub Issue in the private backend repo** via a **GitHub App
  installation token** (server-side; users need no GitHub repo access). Labels carry
  `category` + `app-version`; the issue body embeds the reporter's `login` so we can
  @-mention / follow up. Returns `{ issueNumber, url }`.
- **Backend-agnostic by design:** a `SupportBackend` interface in the Worker; the
  `GitHubIssues` adapter is first; IDEA Base / Linear / etc. drop in later without app
  changes.
- **Status loop:** `GET /v1/support/mine` (session-authed) → the Worker queries issues
  by reporter label and returns title/state/updated. Users see *their* requests and
  status **through the app** (relay-mediated) — they are not repo collaborators and
  don't view issues on GitHub directly. Keeps reports private.

## 9. Backend (Cloudflare Worker)

- **Runtime:** Worker with Static Assets serving the PWA at `/`, API under `/v1/*`.
  Hosts the companion bridge, GitHub OAuth, and support intake.
- **Storage:** KV (or a Durable Object per `deviceId` if we want stronger ordering):
  - `device:<id>` → `{ deviceTokenHash, ownerGithubId?, createdAt }`
  - `snapshot:<id>` → latest tabs map
  - `subs:<id>` → list of `{ subscription, readToken }`
  - `code:<code>` → `deviceId` (TTL ~5 min)
  - `user:<github_id>` → `{ login, avatar, email?, sessionTokenHash }`
- **Web Push:** VAPID (ES256). Public key shipped in the PWA as `applicationServerKey`;
  private key in a **Worker secret**. Payload encrypted `aes128gcm` with the
  subscription's `p256dh` + `auth`. Use a WebCrypto-based push library that runs on
  Workers (the Node `web-push` package does **not** run on Workers — pick one built
  on WebCrypto, e.g. `webpush-webcrypto` / `@negrel/webpush`). On `410 Gone`/`404`,
  delete the dead subscription.
- **Secrets (all via `wrangler secret`):** VAPID private key, GitHub OAuth client
  secret, GitHub App private key / installation token.
- **Hardening:** rate-limit `/v1/pair`, `/v1/subscribe`, `/v1/support`; validate bearer
  tokens with constant-time compare; CORS locked to the PWA origin; never commit secrets.

---

## 10. PWA (phone)

Static site served by the Worker. Built to the iPhone PWA layout rules in the global
`CLAUDE.md` (viewport-fit=cover, safe-area insets, no `overflow:hidden` on body,
`apple-mobile-web-app-capable`, etc.).

- **`manifest.json`** — `display: standalone`, name, theme color, icons (192/512 +
  180 apple-touch-icon).
- **`sw.js`** (service worker) — `push` event → `showNotification(title, {body, tag})`;
  `notificationclick` → focus/open the status screen for that tab.
- **`index.html` + `app.js`** — two screens:
  - **Pair**: code input (or QR scan) → request notification permission → subscribe.
  - **Status board**: tab cards with the color dot mirroring the app's state colors
    (idle gray / active green / output blue / bell yellow / exited dim), name,
    working dir, relative time. Pull `/v1/status` on load + on `visibilitychange`;
    refresh on push receipt. Offline/last-synced indicator.
- **iOS requirements to call out in the UI:** must be **Added to Home Screen**
  (iOS 16.4+), and notification permission must be requested from a tap.

---

## 11. Repo layout (new **private** `consoleforge-backend` repo)

```
consoleforge-backend/
├── README.md                # links back to this spec
├── wrangler.toml            # one Worker: assets + /v1 API
├── src/                     # Worker (API + Web Push + auth + support)
│   ├── index.ts             # router
│   ├── push.ts              # VAPID + aes128gcm send
│   ├── auth.ts              # GitHub OAuth (PKCE) + session tokens
│   ├── support/
│   │   ├── intake.ts        # backend-agnostic report intake
│   │   └── github-issues.ts # first SupportBackend adapter (GitHub App token)
│   └── store.ts             # KV/DO access
├── public/                  # PWA static assets (served by the Worker)
│   ├── index.html
│   ├── app.js
│   ├── sw.js
│   ├── manifest.json
│   └── icons/
└── .dev.vars.example        # VAPID public key, OAuth client id (no secrets committed)
```

Private repo (code hygiene; the deployed endpoint is still public — see §13).
Scaffolded via the `new-project` flow when we start Phase 2/3.

---

## 12. Build phases

1. **macOS event layer** (this repo): `CompanionEvent` model, settle-timer in
   `TabActivityTracker`, `CompanionService` (deviceId/token, POST + offline queue),
   Settings UI + pairing code display. Testable against a local mock backend.
2. **Backend bridge** (new repo): Worker with KV, pairing, snapshot, and Web Push
   (VAPID). Validate end-to-end push to a real iPhone home-screen PWA.
3. **PWA** (new repo): pairing + status board + service worker, to the iPhone layout
   guide. Polish notification copy per state.
4. **GitHub login** (both repos) — now the **auth backbone**, not an add-on. Worker:
   `/v1/auth/start` + `/v1/auth/callback`, confidential `code→token` exchange, user
   store, mint device/session/read tokens. macOS: `AuthService`
   (`ASWebAuthenticationSession` + `consoleforge://` callback), gate the Companion UI
   on sign-in, store device + session tokens. PWA: sign-in screen → read token.
   **Retrofits Phases 1–3:** the Mac's client-generated device token and the phone's
   pairing-code flow are replaced by login-minted tokens.
5. **Support intake** (both repos): `SupportReporter` + Help menu in the app;
   `/v1/support*` in the Worker with the GitHub Issues adapter into the private repo;
   "your requests" status view (authed by the session token from Phase 4).

Phases 1–3 (built first under the original accountless design) now get retrofitted by
Phase 4's login-required model; Phase 5 builds on Phase 4's identity.

---

## 13. Security checklist

- The `consoleforge-backend` repo is **private**. This hides the source only — the
  deployed Worker URL is reachable by anyone on the internet, so the real gate is
  runtime auth (below), not repo visibility. Treat the endpoint as hostile-facing.
- `deviceToken` / `readToken` / user session token in **Keychain** (Mac) and backend
  storage only — never in the repo (per project rule: no secrets in committed files).
- Backend secrets via `wrangler secret`: VAPID private key, **GitHub OAuth client
  secret**, **GitHub App private key / installation token**.
- The GitHub OAuth `code → token` exchange happens **server-side**; the client secret
  never ships in the app/PWA. User OAuth scopes stay minimal (`read:user`) and are
  **never** used to write issues — only the GitHub App/bot authors issues.
- Support diagnostics are opt-in and **scrubbed** of secrets/paths before leaving the Mac.
- Pairing codes short-lived (~5 min) and single-use.
- All transport HTTPS; CORS restricted to the PWA origin; bearer compares constant-time;
  rate-limit `/v1/pair`, `/v1/subscribe`, `/v1/support`.
- Per-`deviceId` isolation in storage; dead subscriptions pruned on push failure.
- Outbound-only from the Mac (no inbound listener).
