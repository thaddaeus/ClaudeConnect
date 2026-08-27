import XCTest
@testable import ConsoleForge

/// The Local Network Access flags must reach EVERY browser driven on our behalf.
///
/// `ManagedChrome.open()` has carried them since Chrome 138 gated LAN/VPN addresses, but
/// there are two paths where we do not launch Chrome at all — the self-launch MCP config
/// below, and the fallback at the end of `scripts/consoleforge-chrome-mcp`. On those,
/// chrome-devtools-mcp launches Chrome itself with Puppeteer's default flag set, our
/// flags never run, and a public page's request to a Twingate/LAN address dies with
/// `ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS`.
///
/// That failure is invisible from `ps`: the flag-less browser sits on OUR profile
/// directory while other tabs' correctly-flagged browsers are right there in the process
/// list, so the flags look present. Hence these tests.
@MainActor
final class ManagedChromeMCPConfigTests: XCTestCase {

    private func mcpArgs(appOwned: Bool) throws -> [String] {
        try XCTSkipIf(ManagedChrome.binary == nil, "Chrome is not installed on this machine")
        let tabID = UUID()
        guard let path = ManagedChrome.shared.writeSessionMCPConfig(tabID: tabID,
                                                                    appOwned: appOwned) else {
            XCTFail("no MCP config written")
            return []
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["chrome-devtools"] as? [String: Any])
        return try XCTUnwrap(server["args"] as? [String])
    }

    /// The bug, stated directly: without the fix there is no `--chromeArg` at all.
    func testSelfLaunchedBrowserIsGivenTheLocalNetworkAccessFlags() throws {
        let args = try mcpArgs(appOwned: false)
        XCTAssertTrue(args.contains { $0.hasPrefix("--chromeArg=") },
                      "the self-launch config must pass our Chrome flags through; args were \(args)")
    }

    /// The trap that cost a round trip: yargs reads a space-separated value that itself
    /// begins with `--` as its own flag, and the server exits with
    /// `Unknown arguments: --disableFeatures`. It has to be ONE `=`-joined token.
    func testChromeArgIsASingleEqualsJoinedTokenNotASeparateValue() throws {
        let args = try mcpArgs(appOwned: false)
        XCTAssertFalse(args.contains("--chromeArg"),
                       "a bare `--chromeArg` means the value was passed as a separate argv entry, "
                       + "which yargs rejects; args were \(args)")
        let chromeArgs = args.filter { $0.hasPrefix("--chromeArg=") }
        XCTAssertEqual(chromeArgs.count, 1)
        XCTAssertEqual(chromeArgs.first, "--chromeArg=\(ManagedChrome.localNetworkAccessFlag)")
    }

    /// Disabling the umbrella does not cover the socket paths — each sub-check is listed
    /// explicitly, and a browser reached over a WebSocket would otherwise still fail.
    func testEveryLocalNetworkAccessSubCheckIsNamed() {
        let flag = ManagedChrome.localNetworkAccessFlag
        XCTAssertTrue(flag.hasPrefix("--disable-features="))
        for check in ["LocalNetworkAccessChecks",
                      "LocalNetworkAccessChecksWebSockets",
                      "LocalNetworkAccessChecksWebTransport",
                      "LocalNetworkAccessChecksWebRTC"] {
            XCTAssertTrue(flag.contains(check), "\(check) missing from \(flag)")
        }
    }

    /// The wrapper is Python and cannot import the Swift constant, so the two copies are
    /// pinned to each other here — drift would silently restore the bug on the fallback
    /// path only, which is the hardest version of it to notice.
    func testWrapperScriptCarriesTheSameFlagAsTheSwiftConstant() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConsoleForgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let wrapper = repoRoot.appendingPathComponent("scripts/consoleforge-chrome-mcp")
        let source = try String(contentsOf: wrapper, encoding: .utf8)
        let features = ManagedChrome.localNetworkAccessFlag
            .replacingOccurrences(of: "--disable-features=", with: "")
        for check in features.split(separator: ",") {
            XCTAssertTrue(source.contains(String(check)),
                          "\(check) is in the Swift constant but not in the wrapper script")
        }
        XCTAssertTrue(source.contains("\"--chromeArg=\" + LOCAL_NETWORK_ACCESS_FLAG"),
                      "the wrapper must join --chromeArg to its value with `=`")
    }
}
