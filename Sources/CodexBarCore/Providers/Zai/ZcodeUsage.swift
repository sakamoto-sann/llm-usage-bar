import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ZcodeSettingsReader {
    public static let appVersionKey = "ZCODE_APP_VERSION"
    private static let supportedProviderIDs = ["builtin:zai-start-plan", "builtin:zai-coding-plan"]

    public static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/config.json", isDirectory: false)
    }

    public static func apiToken(configURL: URL? = nil, fileManager: FileManager = .default) -> String? {
        let url = configURL ?? self.defaultConfigURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ZcodeConfig.self, from: data)
        else {
            return nil
        }
        for providerID in self.supportedProviderIDs {
            if let token = ZaiSettingsReader.cleaned(config.provider[providerID]?.options.apiKey) {
                return token
            }
        }
        return nil
    }

    public static func appVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        ZaiSettingsReader.cleaned(environment[self.appVersionKey]) ?? "3.1.8"
    }
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

public enum ZcodeUsageFetcher {
    private static let balanceURL = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")!

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZaiUsageSnapshot
    {
        guard !apiKey.isEmpty else { throw ZaiUsageError.invalidCredentials }
        guard var components = URLComponents(url: self.balanceURL, resolvingAgainstBaseURL: false) else {
            throw ZaiUsageError.networkError("Invalid ZCode billing URL")
        }
        components.queryItems = [
            URLQueryItem(name: "app_version", value: ZcodeSettingsReader.appVersion(environment: environment)),
        ]
        guard let url = components.url else { throw ZaiUsageError.networkError("Invalid ZCode billing URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw ZaiUsageError.apiError("ZCode billing HTTP \(response.statusCode)")
        }
        return try self.parseUsageSnapshot(from: response.data)
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
}

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
