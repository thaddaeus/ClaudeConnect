---
description: Start work on a ConsoleForge task or issue — resolve the ref, create a worktree, spawn a spoke tab
argument-hint: <ref> [notes...]
allowed-tools: Bash, Read, Grep, Glob
---

# start $ARGUMENTS

Start work on a ref. **The user typing `start <ref>` IS the authorization to begin.**
Do not interrupt it with clarifying questions, an options menu, or a plan review. Create
the worktree and open the tab. If a real decision surfaces, the spoke raises it — see
"If a decision surfaces" at the bottom.

## 1. Resolve the ref (never guess)

`$ARGUMENTS` starts with a ref. Resolve it deterministically:

| Form typed | Meaning |
|---|---|
| `#12`, `gh12`, `gh#12`, `issue 12` | GitHub issue 12 — skip lookup, it's explicit |
| `ib9736`, `task 9736` | IDEA Base task 9736 — skip lookup, it's explicit |
| bare number, e.g. `9736` | Ambiguous — resolve by lookup below |

For a **bare number**, check both sources before doing anything:

```bash
gh issue view <N> --json number,title,state,body 2>/dev/null
```
and `mcp__idea-base__get_task` with `task_id: <N>`.

- **Exactly one resolves** → use it. Say which one you picked in one line.
- **Both resolve** → ask which, one short question, nothing else. Do not pick.
- **Neither resolves** → say so and stop. Do not create a task, do not invent scope.

ConsoleForge's IDEA Base project id is **9031**. Its task ids are 4-digit (9xxx); GitHub
issue numbers here are small (under 100 as of 2026-08), so collisions are unlikely in
practice — but check anyway rather than relying on the range.

> **Open question, not yet decided:** whether user-reported issues get logged to IDEA Base,
> to GitHub Issues, or both. This command works either way and needs no change when that
> is settled. Don't resolve it unilaterally.

Anything in `$ARGUMENTS` after the ref is **scope notes for this task only** — pass it
through to the spoke prompt verbatim. It is not a mode flag.

## 2. Read the ref

- GitHub: `gh issue view <N> --comments`
- IDEA Base: `mcp__idea-base__get_task` — read `description`, `acceptance_criteria`, and
  `resume_context`. Resume context, when present, is the most current state; a task that
  has one is a **resume**, not a cold start.

## 3. Names

| | Worktree | Branch |
|---|---|---|
| IDEA Base | `.claude/worktrees/task-<N>` | `<type>/<N>-<slug>` |
| GitHub | `.claude/worktrees/issue-<N>` | `<type>/<N>-<slug>` |

`<type>` is `feat`, `fix`, or `chore`. `<slug>` is short kebab-case from the title.
The repo's existing branches are bare kebab (`fix/mic-silent-downmix`); we include the ref
number so cleanup can find every branch for a ref by grep. `.claude/worktrees/` is already
gitignored ("Agent worktrees (transient)").

Check `git worktree list` first — if it already exists, skip creation and reuse it.

## 4. Create the worktree

```bash
git -C /Users/tadd/projects/thaddaeus/ClaudeConnect fetch origin
git -C /Users/tadd/projects/thaddaeus/ClaudeConnect worktree add \
    -b <type>/<N>-<slug> .claude/worktrees/<task|issue>-<N> origin/main
```

Always branch from `origin/main`. This repo has no preview/staging branch.

## 5. Symlink memory into the worktree's project dir

Without this the spoke boots with no ConsoleForge memory and re-learns the terminal-resize
lessons the hard way.

```bash
WT="/Users/tadd/projects/thaddaeus/ClaudeConnect/.claude/worktrees/<task|issue>-<N>"
HUB_MEMORY="/Users/tadd/.claude/projects/-Users-tadd-projects-thaddaeus-ClaudeConnect/memory"
WT_PROJECT="/Users/tadd/.claude/projects/$(echo "$WT" | sed 's/[/.]/-/g')"
mkdir -p "$WT_PROJECT"
ln -sfn "$HUB_MEMORY" "$WT_PROJECT/memory"
```

## 6. Mark it started

- IDEA Base: `mcp__idea-base__update_task_status` → `in_progress`.
- GitHub: no status change needed; the branch is the signal.

## 7. Triage: pick the model and effort before opening the tab

Don't default every spoke to the same model. Read the ref (step 2) and place the work
on this grid, then say in one line which you picked and why.

**What actually drives the pick** — reason about the work, not the line count:

* **Novelty** — does this establish a new pattern, or follow one the repo already has?
* **Blast radius** — can a wrong call here corrupt user state or break a load-bearing
  invariant (the SwiftTerm resize path, session persistence, signing)?
* **Specification** — does the task already carry the file:line answers, or must the
  spoke discover them?

| Work shape | Model | Effort |
|---|---|---|
| Novel architecture; a wrong call is expensive to unwind; touches the terminal resize invariants or session persistence | `opus` | `high`–`max` |
| Real implementation against a spec that already names the files and the risk | `opus` | `high` |
| Well-specified change following an established repo pattern | `sonnet` | `medium`–`high` |
| Mechanical: rename, flag passthrough, string/copy change, doc edit | `sonnet` or `haiku` | `low`–`medium` |
| Genuinely hard and open-ended — no known-good approach exists yet | `fable` | (thinking is always on) |

Notes that matter here:

* **`fable` and `opusplan` both work**, even though `scripts/consoleforge-tab --help`
  (line 14) lists only `opus, sonnet, haiku` — the script passes `--model` through
  unvalidated at line 190, and the app's own help and Settings picker both include them.
  That help string is stale, not a constraint.
* **`haiku` has a 200K context window**, not 1M like the others. Don't send it a task
  that has to read wide across the codebase.
* **Reach past `high` deliberately.** `max` buys correctness where correctness beats
  cost, but it can overthink a task that didn't need it.
* **`fable` costs roughly 2× opus per token** and can't have thinking disabled. Reserve it
  for work where no known-good approach exists — not merely large work.

## 8. Spawn the spoke tab

The hub does **not** enter the worktree and does **not** write the code. Hand it off:

```bash
consoleforge-tab \
  --name "<Task 9736 | Issue #12>: <short title>" \
  --cwd "/Users/tadd/projects/thaddaeus/ClaudeConnect/.claude/worktrees/<task|issue>-<N>" \
  --model <from step 7> \
  --effort <from step 7> \
  --permission-mode bypassPermissions \
  --prompt "<prompt, see below>"
```

**`bypassPermissions` is the default for spokes and is encouraged.** A spoke sits in its
own worktree on its own branch — the blast radius is already contained, and permission
prompts just stall autonomous work that nobody is watching. Use a narrower mode only when
the spoke will touch something outside its worktree.

**Prompt hygiene — the prompt carries only:**
1. The ref and where to read it (`get_task 9736` / `gh issue view 12 --comments`).
2. The branch and worktree it is already sitting in.
3. Scope notes the user typed after the ref, verbatim.
4. Anything the hub genuinely knows about *this* ref that isn't already in the task.
5. Where to stop — see below. This one is not optional and not inferable: a spoke
   with `bypassPermissions` and a green test run will merge its own PR unless told
   not to, because from inside the worktree that looks like finishing the job.

Do **not** restate process rules, build instructions, or release steps — those live in
`CLAUDE.md` and the project memories, which the spoke reads on its own. Restated process
text goes stale and silently overrides the real source.

## 9. Report back in one or two lines

Which ref resolved, the branch, the model + effort you picked and why, and that the tab is
open. Then stop — the hub does not follow the spoke into the work.

---

## Where the spoke stops

**The spoke opens the PR. It does not merge it, and it does not release.** Say so in the
prompt, every time. Put the evidence somewhere durable — a comment on the issue or task —
because that survives whether or not the hub is still running; a `SendMessage` to the hub
by name is a nudge on top of that record, not a substitute for it.

This is **not** because the spoke's work needs a second opinion. Issue #23's spoke ran the
geometry pass, used `build.sh` properly, and shipped a correctly signed, notarized,
stapled v0.9.5 with a valid appcast and the tag on the right commit — verified against the
artifact, not its own report. The reasons are narrower than that, and both are structural:

* **A release cannot run concurrently.** `scripts/build.sh` regenerates the ONE
  `appcast.xml` that every install polls. Two spokes finishing minutes apart would race
  the version number and clobber the feed. Nothing about either spoke has to be wrong for
  that to break.
* **Whether a change warrants a release at all is a product decision.** It needs sight of
  what else has landed and what is still in flight, which is exactly what a spoke scoped
  to one ref does not have.

**Merging and releasing are separate decisions, and most merges are neither.** Docs, this
command file, CI, tests, `.gitignore` — none of it reaches the bundle, which holds only
the binary, `consoleforge-tab`, `consoleforge-chrome-mcp` and the icon. Do not cut a
version because a PR merged; cut one when there is user-facing change worth shipping.

## If a decision surfaces

A genuine architecture/scope decision is **not** a reason to withhold the start. Create the
worktree and open the tab anyway, and either:

- let the spoke raise it (as an IDEA Base comment or an issue comment) once it has context, or
- state a recommended default in the spoke prompt and keep discussing in parallel.

If you truly must ask something at kickoff, the question must include a
**"just start it, work the specifics out in the spoke"** option that proceeds immediately
on a sensible default. Never let the question be the only way forward.

## What this command does NOT do

No preview environment, no evidence gates, no deploy step — ConsoleForge ships via
`scripts/build.sh` and is verified by the user on real hardware. Do not import BuyingBuddy's
Gate 0/1/2 machinery here; it has no meaning in this repo.

Never auto-launch the built app to "verify" — build-only. Launching is the user's call.
