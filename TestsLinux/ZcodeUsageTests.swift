import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct ZcodeUsageTests {
    @Test
    func `aggregates 100 plus 50 capacity using API totals`() throws {
        let json = #"""
        {"code":0,"data":{"balances":[
          {"total_units":100,"used_units":25,"remaining_units":75,"reset":"2026-08-01T00:00:00Z"},
          {"total_units":"50","used_units":"25","remaining_units":"25","reset":"2026-08-01T00:00:00Z"}
        ]}}
        """#

        let snapshot = try ZcodeUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.tokenLimit?.usage == 150)
        #expect(snapshot.tokenLimit?.currentValue == 50)
        #expect(snapshot.tokenLimit?.remaining == 100)
        #expect(abs((snapshot.tokenLimit?.usedPercent ?? 0) - (100.0 / 3.0)) < 0.001)
    }

    @Test
    func `caps inconsistent billing values to the combined capacity`() throws {
        let json = #"""
        {"code":0,"data":{"balances":[
          {"total_units":100,"used_units":120,"remaining_units":40,"reset":null},
          {"total_units":50,"used_units":60,"remaining_units":25,"reset":null}
        ]}}
        """#

        let snapshot = try ZcodeUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.tokenLimit?.usage == 150)
        #expect(snapshot.tokenLimit?.currentValue == 150)
        #expect(snapshot.tokenLimit?.remaining == 0)
        #expect(snapshot.tokenLimit?.usedPercent == 100)
    }

    @Test
    func `explicit environment credential wins over ZCode config`() throws {
        let configURL = try self.makeConfig(apiKey: "zcode-token")
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

        let resolution = ProviderTokenResolver.zaiResolution(
            environment: [ZaiSettingsReader.apiTokenKey: "explicit-token"],
            zcodeConfigURL: configURL)

        #expect(resolution?.token == "explicit-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `ZCode config is local credential fallback`() throws {
        let configURL = try self.makeConfig(apiKey: "zcode-token")
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

        let resolution = ProviderTokenResolver.zaiResolution(environment: [:], zcodeConfigURL: configURL)

        #expect(resolution?.token == "zcode-token")
        #expect(resolution?.source == .authFile)
    }

    @Test
    func `billing request includes app version and bearer credential`() async throws {
        let transport = ZcodeTransportStub()

        _ = try await ZcodeUsageFetcher.fetchUsage(
            apiKey: "local-token",
            environment: [ZcodeSettingsReader.appVersionKey: "9.9.9"],
            transport: transport)

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.host == "zcode.z.ai")
        #expect(request.url?.path == "/api/v1/zcode-plan/billing/balance")
        #expect(try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "app_version" })?.value == "9.9.9")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
    }

    private func makeConfig(apiKey: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let json = #"{"provider":{"builtin:zai-start-plan":{"options":{"apiKey":"\#(apiKey)"}}}}"#
        try Data(json.utf8).write(to: url, options: .atomic)
        return url
    }
}

private actor ZcodeTransportStub: ProviderHTTPTransport {
    private var request: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let json = #"{"code":0,"data":{"balances":[{"total_units":150,"used_units":50,"remaining_units":100,"reset":null}]}}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(json.utf8), response)
    }

    func lastRequest() -> URLRequest? {
        self.request
    }
}
