import Foundation
import Testing
@testable import MonitorEngine

/// Real `nettop` output captured on this Mac (macOS 27.0) and saved as fixtures.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

func parse(_ text: String) -> [NettopEvent] {
    var parser = NettopParser()
    var events = text.split(whereSeparator: \.isNewline).compactMap { parser.feed($0) }
    if let last = parser.flush() { events.append(last) }
    return events
}

func samples(_ events: [NettopEvent]) -> [NettopSample] {
    events.compactMap { if case .sample(let sample) = $0 { sample } else { nil } }
}

@Suite struct NettopParserTests {
    @Test func parsesRealSummaryOutput() throws {
        let all = samples(parse(try fixture("summary_delta_raw")))
        #expect(all.count == 4)
        #expect(all[0].isBaseline)
        #expect(all.dropFirst().allSatisfy { !$0.isBaseline })
        #expect(all[0].rows.count > 10)
        let apsd = try #require(all[0].rows.first { $0.pid == 602 })
        #expect(apsd.name == "apsd")
        #expect(apsd.bytes == ByteCounts(down: 952_503, up: 6_297_101))
    }

    @Test func handlesCarriageReturnsFromACookedTerminal() throws {
        let all = samples(parse(try fixture("summary_delta_crlf")))
        #expect(all.count == 3)
        #expect(all[0].rows.contains { $0.name == "mDNSResponder" && $0.pid == 683 })
    }

    @Test func keepsNamesWithSpacesDotsAndParentheses() {
        let text = """
        ,bytes_in,bytes_out,
        Google Chrome H.5286,16347566,9241821,
        Code Helper (Pl.7854,0,0,
        com.adguard.mac.73807,18772455,9627687,
        Weird, Inc Agent.42,10,20,
        """
        let rows = samples(parse(text))[0].rows
        #expect(rows.map(\.name) == ["Google Chrome H", "Code Helper (Pl", "com.adguard.mac", "Weird, Inc Agent"])
        #expect(rows.map(\.pid) == [5286, 7854, 73807, 42])
        #expect(rows[3].bytes == ByteCounts(down: 10, up: 20))
    }

    @Test func countsARealTenMegabyteDownloadUnderCurl() throws {
        let deltas = samples(parse(try fixture("summary_with_10MB_download"))).filter { !$0.isBaseline }
        let curl = deltas.flatMap(\.rows).filter { $0.name == "curl" }.reduce(ByteCounts.zero) { $0 + $1.bytes }
        // 10,000,000 bytes of payload plus TCP/IP and TLS overhead.
        #expect(curl.down > 10_000_000 && curl.down < 11_000_000)
    }

    @Test func rejectsTheDefaultColumnLayout() throws {
        let events = parse(try fixture("default_columns"))
        guard case .unexpectedFormat(let header) = events.first else {
            Issue.record("expected a format failure, got \(events)")
            return
        }
        #expect(header.hasPrefix("time,,interface,state,bytes_in"))
        #expect(events.count == 1)
    }

    @Test func deliversAQuietSampleWithoutWaitingForTheNextHeader() {
        var parser = NettopParser()
        _ = parser.feed(",bytes_in,bytes_out,")
        _ = parser.feed("a.1,5,5,")
        #expect(parser.flush() == .sample(NettopSample(rows: [NettopRow(name: "a", pid: 1, bytes: ByteCounts(down: 5, up: 5))], isBaseline: true)))
        _ = parser.feed(",bytes_in,bytes_out,")
        _ = parser.feed("a.1,7,0,")
        #expect(parser.flush() == .sample(NettopSample(rows: [NettopRow(name: "a", pid: 1, bytes: ByteCounts(down: 7, up: 0))], isBaseline: false)))
        #expect(parser.flush() == nil)
    }
}

@Suite struct ReconcilerTests {
    @Test func gapBecomesMacSystem() {
        let result = Reconciler.reconcile(total: ByteCounts(down: 1000, up: 100),
                                          apps: ["a": ByteCounts(down: 600, up: 50), "b": ByteCounts(down: 300, up: 0)])
        #expect(result.unexplained == ByteCounts(down: 100, up: 50))
        #expect(result.apps["a"] == ByteCounts(down: 600, up: 50))
    }

    @Test func overCountIsScaledToExactlyTheTotal() {
        let result = Reconciler.reconcile(total: ByteCounts(down: 1000, up: 10),
                                          apps: ["a": ByteCounts(down: 700, up: 7), "b": ByteCounts(down: 700, up: 7), "c": ByteCounts(down: 1, up: 0)])
        #expect(result.unexplained == .zero)
        let sum = result.apps.values.reduce(ByteCounts.zero, +)
        #expect(sum == ByteCounts(down: 1000, up: 10))
        #expect(result.apps["a"]!.down == 500 || result.apps["a"]!.down == 499)
    }

    @Test func packetHeadersAreSharedByUsageBeforeAnythingIsUnexplained() {
        // 100 packets each way are 8,000 bytes of headers, shared 90/10 by each app's usage.
        // Down: an 11,000-byte gap, 8,000 explained. Up: an 8,000-byte gap, all explained.
        let result = Reconciler.reconcile(total: ByteCounts(down: 100_000, up: 9_000),
                                          packets: PacketCounts(down: 100, up: 100),
                                          apps: ["big": ByteCounts(down: 81_000, up: 0), "small": ByteCounts(down: 8_000, up: 1_000)])
        #expect(result.unexplained == ByteCounts(down: 3_000, up: 0))
        #expect(result.apps["big"] == ByteCounts(down: 88_200, up: 7_200))
        #expect(result.apps["small"] == ByteCounts(down: 8_800, up: 1_800))
        let sum = result.apps.values.reduce(result.unexplained, +)
        #expect(sum == ByteCounts(down: 100_000, up: 9_000))
    }

    @Test func relaysOnlyGetWhatTheAppsCannotExplain() {
        // AdGuard relayed Chrome's 1,000 bytes and fetched 50 bytes of filter updates of its own.
        let result = Reconciler.reconcile(total: ByteCounts(down: 1_050, up: 0),
                                          apps: ["chrome": ByteCounts(down: 1_000, up: 0)],
                                          relays: ["adguard": ByteCounts(down: 1_050, up: 0)])
        #expect(result.apps["chrome"] == ByteCounts(down: 1_000, up: 0))
        #expect(result.apps["adguard"] == ByteCounts(down: 50, up: 0))
        #expect(result.unexplained == .zero)
    }

    @Test func aRelayWithNothingToRepeatKeepsItsOwnTraffic() {
        // SSH inside a Tailscale tunnel that nettop does not see: the tunnel is the only witness.
        let result = Reconciler.reconcile(total: ByteCounts(down: 10_300, up: 2_000),
                                          apps: [:],
                                          relays: ["tailscale": ByteCounts(down: 10_000, up: 1_900)])
        #expect(result.apps["tailscale"] == ByteCounts(down: 10_000, up: 1_900))
        #expect(result.unexplained == ByteCounts(down: 300, up: 100))
    }

    @Test func zeroTotalDropsEverything() {
        let result = Reconciler.reconcile(total: .zero, apps: ["a": ByteCounts(down: 5, up: 5)])
        #expect(result.apps.isEmpty)
        #expect(result.unexplained == .zero)
    }
}

@Suite struct LedgerTests {
    let app = AppIdentity(key: "com.example", displayName: "Example", kind: .app)

    let proxy = AppIdentity(key: "com.example.proxy", displayName: "Proxy", kind: .app)

    func tick(_ time: Date, total: UInt64, app appBytes: UInt64 = 0, relay relayBytes: UInt64 = 0,
              span: DateInterval? = nil) -> UsageTick {
        UsageTick(time: time, total: ByteCounts(down: total, up: 0), packets: .zero,
                  apps: appBytes > 0 ? [app: ByteCounts(down: appBytes, up: 0)] : [:],
                  relays: relayBytes > 0 ? [proxy: ByteCounts(down: relayBytes, up: 0)] : [:],
                  appSpan: span, network: .wifi, secondsSinceInput: 0)
    }

    @Test func trafficRelayedThroughAProxyIsCountedOnce() {
        // A 30 MB download in Chrome, relayed by AdGuard: nettop sees it in both.
        var ledger = MinuteLedger(grace: 15)
        let minute = MinuteLedger.minuteStart(Date())
        var closed = ledger.add(tick(minute.addingTimeInterval(30), total: 31_000_000, app: 30_000_000, relay: 30_500_000))
        closed += ledger.close()
        #expect(closed.count == 1)
        // Chrome keeps all of its download; the proxy gets only the 1 MB the apps cannot explain.
        #expect(closed[0].apps[app] == ByteCounts(down: 30_000_000, up: 0))
        #expect(closed[0].apps[proxy] == ByteCounts(down: 1_000_000, up: 0))
        #expect(closed[0].apps[.macSystem] == nil)
    }

    @Test func spreadsAppBytesAcrossTheMinuteBoundary() {
        var ledger = MinuteLedger(grace: 15)
        let minute = MinuteLedger.minuteStart(Date())
        var closed: [MinuteSummary] = []
        closed += ledger.add(tick(minute.addingTimeInterval(55), total: 500))
        closed += ledger.add(tick(minute.addingTimeInterval(65), total: 500, app: 1000,
                                  span: DateInterval(start: minute.addingTimeInterval(55), end: minute.addingTimeInterval(65))))
        closed += ledger.close()
        #expect(closed.count == 2)
        #expect(closed[0].apps[app] == ByteCounts(down: 500, up: 0))
        #expect(closed[1].apps[app] == ByteCounts(down: 500, up: 0))
        for summary in closed {
            #expect(summary.apps.values.reduce(ByteCounts.zero, +) == summary.total)
        }
    }

    @Test func waitsForTheGracePeriodBeforeClosing() {
        var ledger = MinuteLedger(grace: 15)
        let minute = MinuteLedger.minuteStart(Date())
        #expect(ledger.add(tick(minute.addingTimeInterval(30), total: 10)).isEmpty)
        #expect(ledger.add(tick(minute.addingTimeInterval(70), total: 10)).isEmpty)
        #expect(ledger.add(tick(minute.addingTimeInterval(76), total: 10)).count == 1)
    }
}

@Suite struct FormattingTests {
    @Test func friendlyUnits() {
        #expect(FriendlyBytes.format(0) == "0 KB")
        #expect(FriendlyBytes.format(40) == "0.1 KB")
        #expect(FriendlyBytes.format(2_400_000_000) == "2.4 GB")
        #expect(FriendlyBytes.format(12_340_000_000) == "12 GB")
        #expect(FriendlyBytes.format(340_000_000) == "340 MB")
        #expect(FriendlyBytes.format(8_500_000) == "8.5 MB")
        #expect(FriendlyBytes.format(3_000_000) == "3 MB")
    }
}

@Suite struct AttributionTests {
    @Test func outermostAppWins() {
        let resolver = ProcessResolver()
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let identity = resolver.appIdentity(containing: chromeHelper)
        #expect(identity?.bundlePath == "/Applications/Google Chrome.app")
    }

    @Test func helperAppsInsideSystemFrameworksAreNotApps() {
        let resolver = ProcessResolver()
        #expect(resolver.appIdentity(containing: "/System/Library/PrivateFrameworks/IMTransferServices.framework/IMTransferAgent.app/Contents/MacOS/IMTransferAgent") == nil)
        #expect(resolver.appIdentity(containing: "/System/Applications/Messages.app/Contents/MacOS/Messages")?.displayName == "Messages")
        #expect(FriendlyNames.lookup("IMTransferAgent")?.displayName == "Messages and FaceTime")
    }

    @Test func proxiesAndTunnelsAreRelaysButFiltersAreNot() {
        func info(_ type: String) -> [String: Any] { ["NetworkExtension": ["NEProviderClasses": [type: "Provider"]]] }
        #expect(ProcessResolver.isRelay(info: info("com.apple.networkextension.app-proxy")))
        #expect(ProcessResolver.isRelay(info: info("com.apple.networkextension.packet-tunnel")))
        #expect(!ProcessResolver.isRelay(info: info("com.apple.networkextension.filter-data")))
        #expect(ProcessResolver.isRelay(info: ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"]]))
        #expect(!ProcessResolver.isRelay(info: [:]))
        #expect(ProcessResolver.extensionBundlePath("/Library/SystemExtensions/X/a.b.systemextension/Contents/MacOS/a") == "/Library/SystemExtensions/X/a.b.systemextension")
    }

    @Test func installedAdGuardAndTailscaleExtensionsAreRecognized() throws {
        let resolver = ProcessResolver()
        let extensions = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/SystemExtensions")) ?? []
        for folder in extensions {
            let base = "/Library/SystemExtensions/\(folder)"
            for bundle in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] where bundle.hasSuffix(".systemextension") {
                let executable = "\(base)/\(bundle)/Contents/MacOS/x"
                if bundle.hasPrefix("com.adguard") || bundle.hasPrefix("io.tailscale") {
                    #expect(resolver.isRelay(executablePath: executable), "\(bundle) should be a relay")
                }
                if bundle.hasPrefix("ch.tripmode") || bundle.hasPrefix("com.macpaw.moonlock") {
                    #expect(!resolver.isRelay(executablePath: executable), "\(bundle) is only a filter")
                }
            }
        }
    }

    @Test func bundleIDComponentsLookLikeBundleIDs() {
        #expect(ProcessResolver.looksLikeBundleID("io.tailscale.ipn.macsys.network-extension.systemextension"))
        #expect(!ProcessResolver.looksLikeBundleID("Google Chrome.app"))
        #expect(!ProcessResolver.looksLikeBundleID("28FF92B2-80FC-4B9D-86F6-60FDB6C641A4"))
    }
}
