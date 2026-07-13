import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct ZcodeUsageTests {
    @Test
    func `uses the available coding plan credential when a stale start plan token also exists`() throws {
        let files = try self.makeConfig(
            startPlanAPIKey: "stale-start-token",
            codingPlanAPIKey: "active-coding-token",
            statuses: [
                "builtin:zai-start-plan": "unavailable",
                "builtin:zai-coding-plan": "available",
            ])
        defer { try? FileManager.default.removeItem(at: files.config.deletingLastPathComponent()) }

        let credential = try #require(ZcodeSettingsReader.usageCredential(
            configURL: files.config,
            statusURL: files.status))

        #expect(credential.token == "active-coding-token")
        #expect(credential.plan == .codingPlan)
    }

    @Test
    func `uses an available start plan credential when coding plan is unavailable`() throws {
        let files = try self.makeConfig(
            startPlanAPIKey: "active-start-token",
            codingPlanAPIKey: "stale-coding-token",
            statuses: [
                "builtin:zai-start-plan": "available",
                "builtin:zai-coding-plan": "unavailable",
            ])
        defer { try? FileManager.default.removeItem(at: files.config.deletingLastPathComponent()) }

        let credential = try #require(ZcodeSettingsReader.usageCredential(
            configURL: files.config,
            statusURL: files.status))

        #expect(credential.token == "active-start-token")
        #expect(credential.plan == .startPlan)
    }

    @Test
    func `defaults to coding plan when status cache is missing or corrupt`() throws {
        let files = try self.makeConfig(
            startPlanAPIKey: "start-token",
            codingPlanAPIKey: "coding-token")
        defer { try? FileManager.default.removeItem(at: files.config.deletingLastPathComponent()) }

        try Data("not-json".utf8).write(to: files.status, options: .atomic)
        let corruptCacheCredential = try #require(ZcodeSettingsReader.usageCredential(
            configURL: files.config,
            statusURL: files.status))
        #expect(corruptCacheCredential.token == "coding-token")
        #expect(corruptCacheCredential.plan == .codingPlan)

        try FileManager.default.removeItem(at: files.status)
        let missingCacheCredential = try #require(ZcodeSettingsReader.usageCredential(
            configURL: files.config,
            statusURL: files.status))
        #expect(missingCacheCredential.token == "coding-token")
        #expect(missingCacheCredential.plan == .codingPlan)
    }

    @Test
    func `does not hide a candidate when the status cache is only partially written`() throws {
        let files = try self.makeConfig(
            startPlanAPIKey: "start-token",
            codingPlanAPIKey: "coding-token",
            statuses: ["builtin:zai-start-plan": "unavailable"])
        defer { try? FileManager.default.removeItem(at: files.config.deletingLastPathComponent()) }

        let credential = try #require(ZcodeSettingsReader.usageCredential(
            configURL: files.config,
            statusURL: files.status))

        #expect(credential.token == "coding-token")
        #expect(credential.plan == .codingPlan)
    }

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
        let files = try self.makeConfig(codingPlanAPIKey: "zcode-token")
        defer { try? FileManager.default.removeItem(at: files.config.deletingLastPathComponent()) }

        let resolution = ProviderTokenResolver.zaiResolution(
            environment: [ZaiSettingsReader.apiTokenKey: "explicit-token"],
            zcodeConfigURL: files.config)

        #expect(resolution?.token == "explicit-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `ZCode config is local credential fallback`() throws {
        let files = try self.makeConfig(codingPlanAPIKey: "zcode-token")
        defer { try? FileManager.default.removeItem(at: files.config.deletingLastPathComponent()) }

        let resolution = ProviderTokenResolver.zaiResolution(environment: [:], zcodeConfigURL: files.config)

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
        #expect(await transport.requestPaths() == [
            "/api/v1/zcode-plan/billing/current",
            "/api/v1/zcode-plan/billing/balance",
        ])
        #expect(try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "app_version" })?.value == "9.9.9")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
    }

    @Test
    func `reports no active Start Plan before requesting balances`() async throws {
        let transport = ZcodeTransportStub(hasActivePlan: false)

        do {
            _ = try await ZcodeUsageFetcher.fetchUsage(apiKey: "local-token", transport: transport)
            Issue.record("Expected the missing Start Plan to fail")
        } catch let error as ZaiUsageError {
            #expect(error.localizedDescription.contains("No active ZCode Start Plan"))
        }

        #expect(await transport.requestPaths() == ["/api/v1/zcode-plan/billing/current"])
    }

    private func makeConfig(
        startPlanAPIKey: String? = nil,
        codingPlanAPIKey: String? = nil,
        statuses: [String: String] = [:]) throws -> (config: URL, status: URL)
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        var providers: [String: Any] = [:]
        if let startPlanAPIKey {
            providers["builtin:zai-start-plan"] = ["options": ["apiKey": startPlanAPIKey]]
        }
        if let codingPlanAPIKey {
            providers["builtin:zai-coding-plan"] = ["options": ["apiKey": codingPlanAPIKey]]
        }
        let config = ["provider": providers]
        try JSONSerialization.data(withJSONObject: config).write(to: configURL, options: .atomic)

        let statusURL = directory.appendingPathComponent("coding-plan-cache.json")
        let items = statuses.mapValues { ["status": $0] }
        let status = ["entryStatus": ["items": items]]
        try JSONSerialization.data(withJSONObject: status).write(to: statusURL, options: .atomic)
        return (configURL, statusURL)
    }
}

private actor ZcodeTransportStub: ProviderHTTPTransport {
    private var requests: [URLRequest] = []
    private let hasActivePlan: Bool

    init(hasActivePlan: Bool = true) {
        self.hasActivePlan = hasActivePlan
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        let json = if request.url?.path.hasSuffix("/billing/current") == true {
            self.hasActivePlan
                ? #"{"code":0,"data":{"plans":[{"plan_id":"start"}]}}"#
                : #"{"code":0,"data":{"plans":[]}}"#
        } else {
            #"{"code":0,"data":{"balances":[{"total_units":150,"used_units":50,"remaining_units":100,"reset":null}]}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(json.utf8), response)
    }

    func lastRequest() -> URLRequest? {
        self.requests.last
    }

    func requestPaths() -> [String] {
        self.requests.compactMap(\.url?.path)
    }
}
