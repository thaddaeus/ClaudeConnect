#!/usr/bin/env python3
"""Criterion 14 — a tab owns its Chrome, and closing the tab terminates it.

The criterion is a LIFETIME claim, and a lifetime claim is only worth what its teardown
paths are worth. So this does not stop at "Chrome opened": it checks the process is
really ours (running against this tab's own --user-data-dir), that the debugging port
actually answers, and then kills the owner four different ways and checks the browser
went with it each time:

    1. closing the TAB terminates it                 (the criterion, literally)
    2. the CLI close path terminates it              (--close-self and friends)
    3. quitting the APP terminates it                (a child is NOT killed by its parent)
    4. FORCE-KILLING the app leaves an orphan that is reaped on next launch

4 is the one that is easy to skip and the reason the promise leaks in practice: SIGKILL
runs no teardown, the browser is reparented to launchd, and "it dies with the tab"
quietly becomes false until the machine reboots.

Beta only. Creates its own throwaway tabs and cleans up after itself.
"""
import json, os, re, subprocess, sys, time, urllib.request

APP = "ConsoleForge Beta"
SUPPORT = os.path.expanduser(f"~/Library/Application Support/{APP}")
CHROME_META = os.path.join(SUPPORT, "chrome")
PROFILES = os.path.join(SUPPORT, "chrome-profiles")
# The repo's OWN copy, not ~/.local/bin — that is a symlink to the main checkout, so a
# branch's CLI changes are invisible there until they merge. Testing a branch against
# main's script silently exercises the wrong code.
CLI = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "scripts", "consoleforge-tab")

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{('  — ' + detail) if detail else ''}")
    return ok


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw).stdout.strip()


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return f"ERR {r.stderr.strip()}" if r.returncode else r.stdout.strip()


def app_running():
    return bool(sh("pgrep", "-f", f"{APP}.app/Contents/MacOS"))


def launch_app():
    subprocess.run(["open", f"/Applications/{APP}.app", "--args", "--dev-hotswap"])
    for _ in range(40):
        time.sleep(0.5)
        if app_running(): break
    time.sleep(6)   # let sessions settle


def new_tab(name, cwd="/tmp"):
    env = dict(os.environ, CONSOLEFORGE_APP_SUPPORT=SUPPORT)
    env.pop("CONSOLEFORGE_TAB_ID", None)   # don't parent it to whatever spawned this
    out = subprocess.run([CLI, "--app", "beta", "--name", name, "--cwd", cwd],
                         capture_output=True, text=True, env=env).stdout
    m = re.search(r"tab-id:\s*([0-9A-Fa-f-]+)", out)
    time.sleep(5)
    return m.group(1).upper() if m else None


def close_tab(name):
    env = dict(os.environ, CONSOLEFORGE_APP_SUPPORT=SUPPORT)
    subprocess.run([CLI, "--app", "beta", "--close", "--name", name],
                   capture_output=True, text=True, env=env)
    time.sleep(3)


def chrome_pid_for(tab_id, mode=None):
    """A Chrome BROWSER process running against this tab's profile. Matched on the
    profile path, so it can never pick up the user's real Chrome or a helper process.
    `mode` narrows to one of the tab's two browsers."""
    profile = os.path.join(PROFILES, tab_id)
    if mode:
        profile = os.path.join(profile, "headless" if mode == "headless" else "window")
    out = sh("ps", "-eo", "pid=,command=")
    for line in out.splitlines():
        if f"--user-data-dir={profile}" in line and "--type=" not in line:
            return int(line.split(None, 1)[0])
    return None


def is_headless(pid):
    return "--headless" in sh("ps", "-p", str(pid), "-o", "command=")


def has_window(pid):
    """Does this process own an on-screen window? The whole promise of the headless mode
    is that the answer is NO, so it is checked rather than assumed."""
    out = osa('tell application "System Events" to return count of every window of '
              f'(first process whose unix id is {pid})')
    try: return int(out) > 0
    except ValueError: return False


def browser_window_via_cli(tab_id, url="https://example.com/"):
    env = dict(os.environ, CONSOLEFORGE_APP_SUPPORT=SUPPORT, CONSOLEFORGE_TAB_ID=tab_id)
    subprocess.run([CLI, "--app", "beta", "--browser-window", url],
                   capture_output=True, text=True, env=env)
    time.sleep(7)


def meta_entry(tab_id, mode):
    m = meta_for(tab_id)
    if not m: return None
    return next((e for e in m.get("browsers", []) if e.get("mode") == mode), None)


def meta_for(tab_id):
    path = os.path.join(CHROME_META, f"{tab_id}.json")
    if not os.path.exists(path): return None
    try: return json.load(open(path))
    except Exception: return None


def menu_click(item, menu="Layout"):
    # Layout, not File: the Chrome command lives beside Safari, Web Output and Documents,
    # which is where anyone looks for a browser.
    return osa(f'tell application "System Events" to tell process "{APP}" to '
               f'click menu item "{item}" of menu 1 of menu bar item "{menu}" of menu bar 1')


def active_tab_id():
    try:
        d = json.load(open(os.path.join(SUPPORT, "sessions.json")))
        return (d.get("activeTabID") or "").upper()
    except Exception:
        return ""


def open_chrome_for_active(expect_tab=None, item="Start Agent Browser"):
    """The menu acts on the ACTIVE tab, so the test has to prove which tab that is.

    Skipping that check once cost a confusing failure: a stale close-by-name command,
    issued while the app was down and replayed at its next launch, closed the tab this
    had just created — so Chrome opened for a DIFFERENT tab and the only symptom was
    `pid=None` three checks later.
    """
    osa(f'tell application "{APP}" to activate'); time.sleep(1.2)
    if expect_tab and active_tab_id() != expect_tab.upper():
        print(f"  precondition FAILED: active tab is {active_tab_id()[:8]}, expected {expect_tab[:8]}")
        return False
    err = menu_click(item)
    time.sleep(7)
    return not err.startswith("ERR")


def drain_commands():
    """Discard queued CLI commands before starting.

    The commands bus is fire-and-forget: anything written while the app is down is
    replayed at its next launch. A leftover "close ChromeTest C" from an earlier run
    will therefore close this run's tab, seconds after it is created.
    """
    d = os.path.join(SUPPORT, "commands")
    for f in os.listdir(d) if os.path.isdir(d) else []:
        try: os.remove(os.path.join(d, f))
        except OSError: pass


def wait_gone(pid, timeout=12):
    for _ in range(int(timeout * 2)):
        if pid is None or sh("ps", "-p", str(pid), "-o", "pid=") == "":
            return True
        time.sleep(0.5)
    return False


# ── 1: launch + ownership ────────────────────────────────────────────────────
def test_launch_and_close_tab():
    print("\n1. the agent's browser is headless and has NO window")
    if not app_running(): launch_app()
    tab = new_tab("ChromeTest A")
    if not check("throwaway tab created", bool(tab), tab or "no tab id"): return
    if not check("menu item fired", open_chrome_for_active(tab, "Start Agent Browser")): return

    pid = chrome_pid_for(tab, "headless")
    check("agent browser running against its own profile", pid is not None, f"pid={pid}")
    if pid:
        check("it really is headless", is_headless(pid))
        # The entire point of the mode: no window means nothing can steal focus while
        # you are typing. Asserted, not assumed.
        check("it owns NO on-screen window", not has_window(pid))
    e = meta_entry(tab, "headless")
    check("port published for --browserUrl", e is not None,
          (e or {}).get("browserUrl", "?"))
    if e:
        try:
            with urllib.request.urlopen(f"{e['browserUrl']}/json/version", timeout=6) as r:
                check("CDP port answers", True, json.load(r).get("Browser", "?"))
        except Exception as ex:
            check("CDP port answers", False, str(ex)[:60])

    print("\n2. a SESSION can ask for a real window, and gets a separate browser")
    browser_window_via_cli(tab)
    wpid = chrome_pid_for(tab, "windowed")
    check("windowed browser launched by the CLI verb", wpid is not None, f"pid={wpid}")
    if wpid:
        check("it is NOT headless", not is_headless(wpid))
        check("it has a real window", has_window(wpid))
        check("it is a DIFFERENT process from the agent's", wpid != pid)
    check("both browsers listed in metadata",
          len((meta_for(tab) or {}).get("browsers", [])) == 2,
          f"{len((meta_for(tab) or {}).get('browsers', []))} listed")

    print("\n2b. CLOSING THE TAB terminates BOTH  (criterion 14)")
    close_tab("ChromeTest A")
    check("agent browser gone", wait_gone(pid))
    check("browser window gone", wait_gone(wpid))
    check("metadata cleaned up", meta_for(tab) is None)


# ── 3: app quit ──────────────────────────────────────────────────────────────
def test_app_quit():
    print("\n3. QUITTING THE APP terminates it")
    tab = new_tab("ChromeTest B")
    if not check("tab created", bool(tab)): return
    if not check("menu item fired", open_chrome_for_active(tab)): return
    pid = chrome_pid_for(tab, "headless")
    if not check("Chrome running", pid is not None, f"pid={pid}"): return

    osa(f'tell application "{APP}" to quit')
    time.sleep(6)
    check("Chrome gone after the app quit", wait_gone(pid))
    close_leftover(tab)


# ── 4: force kill → orphan reaped next launch ────────────────────────────────
def test_orphan_reaping():
    print("\n4. FORCE-KILLING the app strands an orphan, which is reaped on next launch")
    if not app_running(): launch_app()
    tab = new_tab("ChromeTest C")
    if not check("tab created", bool(tab)): return
    if not check("menu item fired", open_chrome_for_active(tab)): return
    pid = chrome_pid_for(tab, "headless")
    if not check("Chrome running", pid is not None, f"pid={pid}"): return

    app_pid = sh("pgrep", "-f", f"{APP}.app/Contents/MacOS").split()[0]
    subprocess.run(["kill", "-9", app_pid])
    time.sleep(3)
    orphaned = chrome_pid_for(tab, "headless") is not None
    check("SIGKILL really does strand the browser (the hazard is real)", orphaned,
          "still running with no owner" if orphaned else "died on its own")
    check("metadata survived the crash, so the orphan is findable", meta_for(tab) is not None)

    launch_app()
    check("orphan reaped on next launch", wait_gone(pid, timeout=20))
    close_leftover(tab)


def close_leftover(tab):
    # Never issue closes while the app is down — they would queue and fire against the
    # NEXT run's tabs.
    if not app_running(): launch_app()
    for name in ("ChromeTest A", "ChromeTest B", "ChromeTest C"):
        close_tab(name)
    pid = chrome_pid_for(tab) if tab else None
    if pid:
        print(f"  (cleanup: killing leftover Chrome {pid})")
        subprocess.run(["kill", "-9", str(pid)])


if __name__ == "__main__":
    if not os.path.exists(f"/Applications/{APP}.app"):
        sys.exit(f"{APP} not installed — run ./scripts/beta.sh first")
    drain_commands()
    test_launch_and_close_tab()
    test_app_quit()
    test_orphan_reaping()

    print("\n" + "-" * 64)
    bad = [n for n, ok, _ in results if not ok]
    for n, ok, d in results:
        if not ok: print(f"  FAILED: {n}  {d}")
    print(f"VERDICT: {len(results)-len(bad)}/{len(results)} checks passed — "
          f"{'PASS' if not bad else 'FAIL'}")
    sys.exit(1 if bad else 0)
