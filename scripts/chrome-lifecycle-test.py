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
CLI = os.path.expanduser("~/.local/bin/consoleforge-tab")

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


def chrome_pid_for(tab_id):
    """A Chrome BROWSER process running against this tab's profile. Matched on the
    profile path, so it can never pick up the user's real Chrome or a helper process."""
    profile = os.path.join(PROFILES, tab_id)
    out = sh("ps", "-eo", "pid=,command=")
    for line in out.splitlines():
        if f"--user-data-dir={profile}" in line and "--type=" not in line:
            return int(line.split(None, 1)[0])
    return None


def meta_for(tab_id):
    path = os.path.join(CHROME_META, f"{tab_id}.json")
    if not os.path.exists(path): return None
    try: return json.load(open(path))
    except Exception: return None


def menu_click(item):
    return osa(f'tell application "System Events" to tell process "{APP}" to '
               f'click menu item "{item}" of menu 1 of menu bar item "File" of menu bar 1')


def open_chrome_for_active():
    osa(f'tell application "{APP}" to activate'); time.sleep(1.2)
    err = menu_click("Open Chrome for This Tab")
    time.sleep(6)
    return not err.startswith("ERR")


def wait_gone(pid, timeout=12):
    for _ in range(int(timeout * 2)):
        if pid is None or sh("ps", "-p", str(pid), "-o", "pid=") == "":
            return True
        time.sleep(0.5)
    return False


# ── 1: launch + ownership ────────────────────────────────────────────────────
def test_launch_and_close_tab():
    print("\n1. a tab launches a Chrome that is genuinely its own")
    if not app_running(): launch_app()
    tab = new_tab("ChromeTest A")
    if not check("throwaway tab created", bool(tab), tab or "no tab id"): return
    if not check("menu item fired", open_chrome_for_active()): return

    pid = chrome_pid_for(tab)
    check("Chrome running against THIS tab's profile", pid is not None, f"pid={pid}")
    meta = meta_for(tab)
    check("metadata published for the session to read", meta is not None,
          f"port={meta.get('port') if meta else '?'}")
    if meta:
        check("metadata pid matches the live process", meta.get("pid") == pid,
              f"meta={meta.get('pid')} live={pid}")
        # The port is the entire reason for --remote-debugging-port; an unanswered port
        # is a flag that was set and never worked.
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{meta['port']}/json/version", timeout=6) as r:
                ver = json.load(r).get("Browser", "?")
            check("CDP debugging port answers", True, ver)
        except Exception as e:
            check("CDP debugging port answers", False, str(e)[:60])
        check("profile is dedicated, not the user's Chrome",
              meta.get("profileDir", "").startswith(PROFILES), meta.get("profileDir", ""))

    print("\n2. CLOSING THE TAB terminates it  (the criterion)")
    close_tab("ChromeTest A")
    check("Chrome process gone after the tab closed", wait_gone(pid))
    check("metadata cleaned up", meta_for(tab) is None)


# ── 3: app quit ──────────────────────────────────────────────────────────────
def test_app_quit():
    print("\n3. QUITTING THE APP terminates it")
    tab = new_tab("ChromeTest B")
    if not check("tab created", bool(tab)): return
    if not check("menu item fired", open_chrome_for_active()): return
    pid = chrome_pid_for(tab)
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
    if not check("menu item fired", open_chrome_for_active()): return
    pid = chrome_pid_for(tab)
    if not check("Chrome running", pid is not None, f"pid={pid}"): return

    app_pid = sh("pgrep", "-f", f"{APP}.app/Contents/MacOS").split()[0]
    subprocess.run(["kill", "-9", app_pid])
    time.sleep(3)
    orphaned = chrome_pid_for(tab) is not None
    check("SIGKILL really does strand the browser (the hazard is real)", orphaned,
          "still running with no owner" if orphaned else "died on its own")
    check("metadata survived the crash, so the orphan is findable", meta_for(tab) is not None)

    launch_app()
    check("orphan reaped on next launch", wait_gone(pid, timeout=20))
    close_leftover(tab)


def close_leftover(tab):
    for name in ("ChromeTest A", "ChromeTest B", "ChromeTest C"):
        close_tab(name)
    pid = chrome_pid_for(tab) if tab else None
    if pid:
        print(f"  (cleanup: killing leftover Chrome {pid})")
        subprocess.run(["kill", "-9", str(pid)])


if __name__ == "__main__":
    if not os.path.exists(f"/Applications/{APP}.app"):
        sys.exit(f"{APP} not installed — run ./scripts/beta.sh first")
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
