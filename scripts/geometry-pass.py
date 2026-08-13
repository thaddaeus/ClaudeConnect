#!/usr/bin/env python3
"""Drive and grade the terminal-geometry regression pass (IDEA Base task 9543 / 9487).

WHY THIS EXISTS. The terminal's size is the most regression-prone thing in this app:
reflowing SwiftTerm at a wrong width corrupts its buffer model permanently. Every phase
of the layout work has to re-verify it, and the manual protocol for doing so ran to nine
steps that each had to be performed exactly — which is not a test, it is a trap. Worse,
the single most important check is one a human physically cannot perform: noticing a
reflow that happened when NOBODY ASKED FOR ONE. A spontaneous reflow looks like nothing.

So: every gesture is driven through the Layout MENU BY NAME (never mouse coordinates, so
each step is exact and repeatable) and timestamped to a log. The log is then aligned
against the geometry trace, which lets us assert that each reflow has a cause.

    ./scripts/geometry-pass.py              # run the gestures, then grade
    ./scripts/geometry-pass.py --grade N    # just re-grade from trace line N

BETA ONLY. GeometryTrace is gated on !AppChannel.isProduction, so production writes no
trace and there is nothing to grade.

IT CHANGES THE LAYOUT AND DOES NOT PUT IT BACK. Writing the saved layout.json back is
useless while the app is running — the app holds the layout in memory and overwrites the
file on its next commit. Rather than pretend, the run ends with Layout ▸ Reset Layout so
you land in a known state. ⌘⇧B / ⌘⇧E bring the panels back.

NOT COVERED, and not automatable: sleep/wake and display connect/disconnect. Both are in
the 9543 set. Do them by hand if the change plausibly touches them.
"""
import argparse, json, os, re, subprocess, sys, time

APP = "ConsoleForge Beta"
SUPPORT = os.path.expanduser(f"~/Library/Application Support/{APP}")
GEOM = os.path.join(SUPPORT, "debug", "geometry.jsonl")
GESTURES = "/tmp/consoleforge-geometry-gestures.jsonl"

# Long enough to clear setSize's 140ms debounce AND the 300ms settle nudge, with room for
# the child to redraw. Too short and gestures blur into a single reflow, which makes the
# gesture/reflow alignment meaningless.
SETTLE = 1.5
# A reflow counts as explained if a gesture happened within this window before it.
WINDOW = 2.5


# ─────────────────────────────────────────────────────────────── driving ──

def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return f"ERR {r.stderr.strip()}" if r.returncode else r.stdout.strip()


def log(label):
    with open(GESTURES, "a") as f:
        f.write(json.dumps({"at": time.time(), "label": label}) + "\n")
    print(f"  {label}")


def _ref(path):
    """AX nesting is: menu bar item -> menu 1 -> menu item -> menu 1 -> menu item …"""
    ref = 'menu bar item "Layout" of menu bar 1'
    for name in path:
        ref = f'menu item "{name}" of menu 1 of {ref}'
    return ref


def gesture(*path, label=None, settle=SETTLE, prefix=False):
    """Click Layout ▸ … by name.

    `prefix` matches on the start of the item's name, which is required for "Move to":
    an OCCUPIED target renders as "Top Left — swap with Console", so an exact-name click
    fails — and a swap is the most disruptive move there is, since two sections change
    slot at once. The first version of this harness silently skipped every swap for
    exactly that reason.

    A miss is REPORTED, never silently passed over: a step that did not happen must not
    look like a step that passed.
    """
    target = path[-1]
    if prefix:
        names = osa(f'tell application "System Events" to tell process "{APP}" to '
                    f'return name of every menu item of menu 1 of {_ref(path[:-1])}')
        target = next((n.strip() for n in names.split(",")
                       if n.strip().lower().startswith(path[-1].lower())), None)
        if not target:
            print(f"  SKIPPED {label or path[-1]} — no item starting with {path[-1]!r}")
            return False
    err = osa(f'tell application "System Events" to tell process "{APP}" to '
              f'click menu item "{target}" of menu 1 of {_ref(path[:-1])}')
    if err.startswith("ERR"):
        print(f"  SKIPPED {label or target} — {err.splitlines()[0][:88]}")
        return False
    log(label or " ▸ ".join(path[:-1] + (target,)))
    time.sleep(settle)
    return True


def resize(w, h, settle=SETTLE):
    osa(f'tell application "System Events" to tell process "{APP}" '
        f'to set size of window 1 to {{{w}, {h}}}')
    log(f"window → {w}px")
    time.sleep(settle)


def run():
    if not os.path.exists(GEOM):
        sys.exit(f"No geometry trace at {GEOM}. Is the BETA running? (production writes none)")
    baseline = sum(1 for _ in open(GEOM))
    open(GESTURES, "w").close()
    print(f"trace baseline: {baseline} events\n")

    osa(f'tell application "{APP}" to activate')
    time.sleep(1.5)
    size = osa(f'tell application "System Events" to tell process "{APP}" to return size of window 1')
    ow, oh = ([int(x) for x in size.replace(" ", "").split(",")] if "," in size else [1600, 1000])
    print(f"window {ow}×{oh}\n")

    print("SETUP — three tiled panels")
    gesture("Show Safari"); gesture("Show Documents")
    for s in ("Safari", "Documents", "Console"):
        gesture(s, "Size", "Normal", label=f"{s} → Normal", settle=0.9)

    print("\nA — width changes with a third tiled panel")
    for pct in ("25%", "50%", "75%", "33%"):
        gesture("Console", "Size", f"Pin at {pct}", label=f"pin Console at {pct}")
    gesture("Console", "Size", "Flexible", label="Console → Flexible")
    for pct in ("25%", "50%"):
        gesture("Documents", "Size", f"Pin at {pct}", label=f"pin Documents at {pct}")
    gesture("Documents", "Size", "Flexible", label="Documents → Flexible")

    print("\nB — moves, including swaps into occupied slots")
    for section, slot in (("Documents", "Bottom Center"), ("Documents", "Top Left"),
                          ("Documents", "Top Center"), ("Safari", "Top Left"),
                          ("Documents", "Top Right"), ("Console", "Top Center")):
        gesture(section, "Move to", slot, label=f"{section} → {slot}", prefix=True)

    print("\nC — float / dock (must not move the tiled console)")
    for s in ("Documents", "Safari"):
        gesture(s, "Float over the layout", label=f"{s} float")
        gesture(s, "Dock into the layout", label=f"{s} dock")

    print("\nD — collapse / expand / full width")
    gesture("Documents", "Size", "Collapse", label="Documents collapse")
    gesture("Documents", "Size", "Normal", label="Documents normal")
    gesture("Console", "Size", "Full Width", label="Console full width")
    gesture("Console", "Size", "Normal", label="Console normal")

    print("\nE — window resize storm")
    for w in (1500, 1300, 1100, 950, 1100, 1300, 1500, ow):
        resize(w, oh, settle=0.35)
    log("resize storm settling"); time.sleep(2.5)

    print("\nF — fullscreen in / out")
    for state, name in ((True, "ENTER"), (False, "EXIT")):
        osa(f'tell application "System Events" to tell process "{APP}" to set value of '
            f'attribute "AXFullScreen" of window 1 to {str(state).lower()}')
        log(f"fullscreen {name}"); time.sleep(3.5)

    print("\nG — closing a panel must NOT change the console's width")
    gesture("Console", "Size", "Pin at 50%", label="pin Console at 50%")
    gesture("Hide Documents", label="hide Documents")
    gesture("Hide Safari", label="hide Safari")

    time.sleep(1.0)
    gesture("Reset Layout", label="reset layout", settle=0.5)
    return baseline


# ─────────────────────────────────────────────────────────────── grading ──

def _dims(d):
    m = re.search(r"container=(\d+)×(\d+)", d)
    return (int(m.group(1)), int(m.group(2))) if m else None

def _setsize_cols(d):
    m = re.search(r"\((\d+) cols\)", d)
    return int(m.group(1)) if m else None

def _grid_cols(d):
    m = re.search(r"→ (\d+)×(\d+) cols", d)
    return int(m.group(1)) if m else None


def grade(baseline):
    ev = sorted((json.loads(l) for l in open(GEOM) if l.strip()), key=lambda e: e["at"])[baseline:]
    if not ev:
        sys.exit("No new geometry events — did the run happen?")
    gest = [json.loads(l) for l in open(GESTURES)] if os.path.exists(GESTURES) else []
    t0, g0 = ev[0]["at"], (gest[0]["at"] if gest else 0)
    # Two different clocks — the trace is CFAbsoluteTime, the gesture log is wall time —
    # so each is taken relative to its OWN first record. The two runs started together.
    rel = lambda e: e["at"] - t0
    grel = lambda g: g["at"] - g0

    applied = [e for e in ev if e.get("stage") == "applied"]
    grids = [e for e in ev if e.get("stage") == "grid"]
    rejected = [e for e in ev if e.get("stage") == "rejected"]
    sets = [e for e in ev if e.get("stage") == "setSize"]
    fails = []

    print(f"\n{len(ev)} events / {rel(ev[-1]):.0f}s   applied={len(applied)} "
          f"grid={len(grids)} rejected={len(rejected)}   {len(gest)} gestures\n")

    print(f"1. rejected geometries: {len(rejected)}")
    for e in rejected[:8]:
        print(f"     +{rel(e):6.1f}s {e.get('detail','')}")
    if rejected: fails.append("a degenerate geometry reached the resize path")
    print("   PASS\n" if not rejected else "   FAIL\n")

    # Pair each apply with the setSize that produced it. `applied` records carry no
    # "(N cols)" of their own — an earlier version of this check read that field, found
    # nothing, compared nothing, and reported PASS. A check that can pass vacuously is
    # worse than no check, so it now prints how many comparisons it actually made.
    compared, bad = 0, []
    for a in applied:
        want_dims = _dims(a.get("detail", ""))
        src = [s for s in sets if s["at"] <= a["at"] and _dims(s.get("detail", "")) == want_dims]
        if not src: continue
        want = _setsize_cols(src[-1].get("detail", ""))
        if want is None: continue
        for g in grids:
            if 0 <= g["at"] - a["at"] < 0.25:
                got = _grid_cols(g.get("detail", ""))
                if got is None: continue
                compared += 1
                if got != want:
                    bad.append((rel(a), want, got))
    print(f"2. container/grid disagreements: {len(bad)}   ({compared} grid pushes compared)")
    for t, w, g in bad[:8]:
        print(f"     +{t:6.1f}s container {w} cols, grid took {g}")
    if not compared: fails.append("check 2 compared nothing — grader is blind")
    if bad: fails.append("container and SwiftTerm grid disagreed")
    print("   PASS\n" if compared and not bad else "   FAIL\n")

    # The check no human can do.
    spont = [a for a in applied if not any(0 <= rel(a) - grel(g) <= WINDOW for g in gest)]
    print(f"3. reflows with no gesture behind them: {len(spont)} of {len(applied)}")
    for a in spont[:8]:
        print(f"     +{rel(a):6.1f}s {a.get('detail','')}   <- nobody asked for this")
    if spont: fails.append("reflows happened with no gesture behind them")
    print("   PASS\n" if not spont else "   FAIL\n")

    def dims_after(sub):
        # LAST match, not first — section A pins the console at 50% as well, and grading
        # that one instead of section G's compares two unrelated moments.
        hits = [x for x in gest if sub.lower() in x["label"].lower()]
        if not hits: return None
        after = [a for a in applied if 0 <= rel(a) - grel(hits[-1]) <= WINDOW]
        return _dims(after[-1].get("detail", "")) if after else None

    pin, hidden = dims_after("pin Console at 50%"), dims_after("hide Documents")
    print("4. console holds its WIDTH when a sibling closes (pinned 50%)")
    print(f"     after pin:            {pin}")
    print(f"     after hide Documents: {hidden}")
    if pin and hidden:
        if pin[0] == hidden[0]:
            # Height MAY legitimately change: if the closed panel was the only thing in
            # the bottom row, the surviving row fills the height. Only width is pinned.
            note = " (height changed, which is correct — a lone row fills)" if pin[1] != hidden[1] else ""
            print(f"   PASS — width held at {pin[0]}px{note}\n")
        else:
            fails.append("console width changed when a sibling closed")
            print("   FAIL\n")
    else:
        print("   INCONCLUSIVE — no reflow in the window (which is itself the desired outcome)\n")

    print("VERDICT:", "PASS" if not fails else "FAIL — " + "; ".join(fails))
    print("\nNot covered by this harness: sleep/wake, display connect/disconnect.")
    return 0 if not fails else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--grade", type=int, metavar="N",
                   help="skip the run; grade the existing trace from line N")
    args = p.parse_args()
    sys.exit(grade(args.grade if args.grade is not None else run()))
