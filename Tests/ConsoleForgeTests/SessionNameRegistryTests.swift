import XCTest
@testable import ConsoleForge

/// Task 990003's acceptance criteria, as test functions.
///
/// The failure this guards is silent: two live sessions holding one name means
/// `SendMessage` picks one, and nothing errors. On 2026-08-19 a spoke reported completion
/// to the wrong hub and the right hub simply never heard back.
final class SessionNameRegistryTests: XCTestCase {

    private func row(_ name: String, pid: Int, start: String = "Thu Aug 27 20:39:40 2026",
                     socket: String = "/tmp/cc-socks/x.sock") -> SessionNameRegistry.Row {
        .init(name: name, pid: pid, procStart: start, socketPath: socket)
    }

    /// Criterion 1, and the half that is easy to lose: a free name must come back
    /// UNCHANGED. Spokes address the hub by a name they were told in advance, so a scheme
    /// that renamed every launch would be unique and useless.
    func testANameNoLivePeerHoldsIsUsedUnchanged() {
        XCTAssertEqual(SessionNameRegistry.uniqueName(for: "bfg:hub", takenBy: []), "bfg:hub")
        XCTAssertEqual(SessionNameRegistry.uniqueName(for: "bfg:hub", takenBy: ["other"]), "bfg:hub")
    }

    /// Criterion 1: never silently create a duplicate address.
    func testANameHeldByALivePeerIsSuffixedNotDuplicated() {
        let got = SessionNameRegistry.uniqueName(for: "bfg:hub", takenBy: ["bfg:hub"])
        XCTAssertEqual(got, "bfg:hub-2")
        XCTAssertNotEqual(got, "bfg:hub")
    }

    func testSuffixingSkipsNamesAlreadyTaken() {
        let taken: Set<String> = ["bfg:hub", "bfg:hub-2", "bfg:hub-3"]
        XCTAssertEqual(SessionNameRegistry.uniqueName(for: "bfg:hub", takenBy: taken), "bfg:hub-4")
    }

    /// Criterion 4: two hubs for different projects run concurrently and stay distinct.
    func testTwoHubsRunningConcurrentlyGetDistinctAddresses() {
        var taken: Set<String> = []
        let first = SessionNameRegistry.uniqueName(for: "Hub", takenBy: taken)
        taken.insert(first)
        let second = SessionNameRegistry.uniqueName(for: "Hub", takenBy: taken)
        XCTAssertEqual(first, "Hub")
        XCTAssertEqual(second, "Hub-2")
        XCTAssertNotEqual(first, second)
    }

    /// Criterion 2: a recycled pid must not read as live. `kill -0` alone cannot tell a
    /// stale row apart from a running one.
    func testARecycledPidIsNotTreatedAsLive() {
        XCTAssertFalse(SessionNameRegistry.procStartsAgree(
            rowStart: "Thu Aug 27 20:39:40 2026",
            psStart:  "Tue Jul 14 09:12:03 2026"))
    }

    /// The registry writes `procStart` in UTC while `ps` prints local time. Both stamps
    /// are built here from ONE instant using the machine's own zone, so the test states
    /// the real relationship instead of hard-coding an offset that would pass in EDT and
    /// fail on a UTC CI runner.
    func testTheSameInstantMatchesAcrossTheRegistryAndPsTimezones() {
        let instant = Date(timeIntervalSince1970: 1_787_863_180)
        func stamp(_ zone: TimeZone) -> String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            df.timeZone = zone
            return df.string(from: instant)
        }
        let utc = stamp(TimeZone(identifier: "UTC")!)
        let local = stamp(.current)
        XCTAssertTrue(SessionNameRegistry.procStartsAgree(rowStart: utc, psStart: local),
                      "UTC \(utc) and local \(local) describe one instant and must agree")
    }

    func testAnUnparsableTimestampIsNotTreatedAsAMatch() {
        XCTAssertFalse(SessionNameRegistry.procStartsAgree(rowStart: "", psStart: ""))
        XCTAssertFalse(SessionNameRegistry.procStartsAgree(rowStart: "garbage", psStart: "garbage"))
    }

    /// No socket, no SendMessage — it is not an address, whatever the file says.
    func testARowWhoseSocketIsGoneIsNotLive() {
        let rows = [row("bfg:hub", pid: 1)]
        let live = SessionNameRegistry.liveRows(rows,
                                                psStarts: [1: "Thu Aug 27 20:39:40 2026"],
                                                socketExists: { _ in false })
        XCTAssertTrue(live.isEmpty)
    }

    /// A zombie is filtered out of `psStarts`, so it reaches `liveRows` as a missing pid.
    /// Without this its name would block that name forever — ConsoleForge does not always
    /// reap, and `<defunct>` still answers `ps -p`.
    func testARowWithNoLiveProcessIsNotLiveAndDoesNotHoldItsName() {
        let rows = [row("bfg:hub", pid: 4242)]
        let live = SessionNameRegistry.liveRows(rows, psStarts: [:], socketExists: { _ in true })
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(SessionNameRegistry.uniqueName(for: "bfg:hub",
                                                      takenBy: Set(live.map(\.name))), "bfg:hub")
    }

    func testALiveRowHoldsItsNameSoTheNextTabIsSuffixed() {
        let rows = [row("bfg:hub", pid: 7)]
        let live = SessionNameRegistry.liveRows(rows,
                                                psStarts: [7: "Thu Aug 27 20:39:40 2026"],
                                                socketExists: { _ in true })
        XCTAssertEqual(live.map(\.name), ["bfg:hub"])
        XCTAssertEqual(SessionNameRegistry.uniqueName(for: "bfg:hub",
                                                      takenBy: Set(live.map(\.name))), "bfg:hub-2")
    }
}
