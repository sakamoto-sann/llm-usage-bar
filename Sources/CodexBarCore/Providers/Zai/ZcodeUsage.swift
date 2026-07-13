import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ZcodeSettingsReader {
    public static let appVersionKey = "ZCODE_APP_VERSION"
    private static let codingPlanProviderID = "builtin:zai-coding-plan"
    private static let startPlanProviderID = "builtin:zai-start-plan"

    public static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/config.json", isDirectory: false)
    }

    public static func defaultStatusURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/coding-plan-cache.json", isDirectory: false)
    }

    public static func apiToken(configURL: URL? = nil, fileManager: FileManager = .default) -> String? {
        self.usageCredential(configURL: configURL, fileManager: fileManager)?.token
    }

    public static func usageCredential(
        configURL: URL? = nil,
        statusURL: URL? = nil,
        fileManager: FileManager = .default) -> ZcodeUsageCredential?
    {
        let resolvedConfigURL = configURL ?? self.defaultConfigURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: resolvedConfigURL),
              let config = try? JSONDecoder().decode(ZcodeConfig.self, from: data)
        else {
            return nil
        }

        let candidates = [
            self.credential(
                providerID: self.codingPlanProviderID,
                plan: .codingPlan,
                config: config),
            self.credential(
                providerID: self.startPlanProviderID,
                plan: .startPlan,
                config: config),
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }

        let resolvedStatusURL = statusURL ?? (configURL == nil
            ? self.defaultStatusURL(fileManager: fileManager)
            : resolvedConfigURL.deletingLastPathComponent().appendingPathComponent("coding-plan-cache.json"))
        guard let statusData = try? Data(contentsOf: resolvedStatusURL),
              let cache = try? JSONDecoder().decode(ZcodePlanStatusCache.self, from: statusData)
        else {
            return candidates.first
        }

        if let available = candidates.first(where: {
            cache.entryStatus.items[$0.providerID]?.status == "available"
        }) {
            return available
        }

        let allCandidatesHaveStatus = candidates.allSatisfy {
            cache.entryStatus.items[$0.providerID] != nil
        }
        return allCandidatesHaveStatus ? nil : candidates.first
    }

    public static func appVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        ZaiSettingsReader.cleaned(environment[self.appVersionKey]) ?? "3.1.8"
    }

    private static func credential(
        providerID: String,
        plan: ZcodeUsagePlan,
        config: ZcodeConfig) -> ZcodeUsageCredential?
    {
        guard let token = ZaiSettingsReader.cleaned(config.provider[providerID]?.options.apiKey) else {
            return nil
        }
        return ZcodeUsageCredential(token: token, plan: plan, providerID: providerID)
    }
}

public enum ZcodeUsagePlan: Sendable, Equatable {
    case codingPlan
    case startPlan
}

public struct ZcodeUsageCredential: Sendable, Equatable {
    public let token: String
    public let plan: ZcodeUsagePlan
    fileprivate let providerID: String
}

private struct ZcodeConfig: Decodable {
    let provider: [String: ZcodeProvider]
}

private struct ZcodeProvider: Decodable {
    let options: ZcodeProviderOptions
}

private struct ZcodeProviderOptions: Decodable {
    let apiKey: String?
}

private struct ZcodePlanStatusCache: Decodable {
    let entryStatus: ZcodePlanEntryStatus
}

private struct ZcodePlanEntryStatus: Decodable {
    let items: [String: ZcodePlanStatus]
}

private struct ZcodePlanStatus: Decodable {
    let status: String
}

public enum ZcodeUsageFetcher {
    private static let currentURL = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/current")!
    private static let balanceURL = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")!

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZaiUsageSnapshot
    {
        guard !apiKey.isEmpty else { throw ZaiUsageError.invalidCredentials }
        let currentData = try await self.fetch(
            url: self.currentURL,
            apiKey: apiKey,
            environment: environment,
            transport: transport)
        let current = try JSONDecoder().decode(ZcodeCurrentResponse.self, from: currentData)
        guard current.code == 0 else {
            throw ZaiUsageError.apiError(current.message ?? "ZCode billing/current returned code \(current.code)")
        }
        guard let plans = current.data?.plans, !plans.isEmpty else {
            throw ZaiUsageError.apiError("No active ZCode Start Plan. Connect a Z.ai Coding Plan in ZCode.")
        }

        let balanceData = try await self.fetch(
            url: self.balanceURL,
            apiKey: apiKey,
            environment: environment,
            transport: transport)
        return try self.parseUsageSnapshot(from: balanceData)
    }

    public static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> ZaiUsageSnapshot {
        let response = try JSONDecoder().decode(ZcodeBalanceResponse.self, from: data)
        guard response.code == 0, let balances = response.data?.balances, !balances.isEmpty else {
            throw ZaiUsageError.parseFailed("ZCode billing response contains no balances")
        }

        let total = balances.reduce(0) { $0 + Self.validUnits($1.totalUnits.value) }
        guard total > 0 else { throw ZaiUsageError.parseFailed("ZCode billing total is zero") }
        let used = min(total, balances.reduce(0) { $0 + Self.validUnits($1.usedUnits.value) })
        let reportedRemaining = balances.reduce(0) { $0 + Self.validUnits($1.remainingUnits.value) }
        let remaining = min(total - used, reportedRemaining)
        let reset = balances.compactMap(\.resetDate).min()
        let limit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .unknown,
            number: 0,
            usage: Int(total.rounded()),
            currentValue: Int(used.rounded()),
            remaining: Int(remaining.rounded()),
            percentage: min(100, max(0, used / total * 100)),
            usageDetails: [],
            nextResetTime: reset)
        return ZaiUsageSnapshot(
            tokenLimit: limit,
            timeLimit: nil,
            planName: "ZCode GLM",
            updatedAt: now)
    }

    private static func validUnits(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, Double(Int.max))
    }

    private static func fetch(
        url: URL,
        apiKey: String,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZaiUsageError.networkError("Invalid ZCode billing URL")
        }
        components.queryItems = [
            URLQueryItem(name: "app_version", value: ZcodeSettingsReader.appVersion(environment: environment)),
        ]
        guard let requestURL = components.url else {
            throw ZaiUsageError.networkError("Invalid ZCode billing URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw ZaiUsageError.apiError("ZCode billing HTTP \(response.statusCode)")
        }
        return response.data
    }
}

private struct ZcodeCurrentResponse: Decodable {
    let code: Int
    let msg: String?
    let data: ZcodeCurrentData?

    var message: String? {
        guard let msg = self.msg?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty else {
            return nil
        }
        return msg
    }
}

private struct ZcodeCurrentData: Decodable {
    let plans: [ZcodeCurrentPlan]
}

private struct ZcodeCurrentPlan: Decodable {}

private struct ZcodeBalanceResponse: Decodable {
    let code: Int
    let data: ZcodeBalanceData?
}

private struct ZcodeBalanceData: Decodable {
    let balances: [ZcodeBalance]
}

private struct ZcodeBalance: Decodable {
    let totalUnits: FlexibleDouble
    let usedUnits: FlexibleDouble
    let remainingUnits: FlexibleDouble
    let reset: FlexibleDate?

    enum CodingKeys: String, CodingKey {
        case totalUnits = "total_units"
        case usedUnits = "used_units"
        case remainingUnits = "remaining_units"
        case reset
    }

    var resetDate: Date? {
        self.reset?.date
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self.value = value
        } else if let raw = try? container.decode(String.self), let value = Double(raw) {
            self.value = value
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected numeric units")
        }
    }
}

private struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            return
        }
        guard let raw = try? container.decode(String.self) else {
            self.date = nil
            return
        }
        if let seconds = Double(raw) {
            self.date = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        } else {
            self.date = ISO8601DateFormatter().date(from: raw)
        }
    }
}
