import Foundation
import CryptoKit

final class GitHubClient {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func dispatchHealthPayload(_ payload: HealthPayload) async throws {
        try validateConfig()

        let url = URL(string: "https://api.github.com/repos/\(AppConfig.githubOwner)/\(AppConfig.githubRepo)/actions/workflows/sleep-analysis.yml/dispatches")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AppConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payloadData = try encoder.encode(payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw SleepWatchError.invalidSummaryResponse
        }

        let body = WorkflowDispatchBody(
            ref: AppConfig.githubBranch,
            inputs: WorkflowDispatchInputs(payloadJSON: payloadJSON)
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.ensureSuccess(response: response, data: data, expected: 204)
    }

    func dispatchSleepPayload(_ payload: SleepPayload) async throws {
        let healthPayload = HealthPayload(
            analysisDate: payload.sleepDate,
            windowStart: payload.windowStart,
            windowEnd: payload.windowEnd,
            sleepWindowStart: payload.windowStart,
            sleepWindowEnd: payload.windowEnd,
            generatedAt: payload.generatedAt,
            source: payload.source,
            sleepSamples: payload.samples,
            quantityMetrics: [],
            standHours: [],
            dataGaps: []
        )
        try await dispatchHealthPayload(healthPayload)
    }

    func fetchReport(reportDate: String) async throws -> HealthReport {
        try validateConfig()

        let text = try await fetchContent(path: "reports/\(reportDate).json.enc")
        let decrypted = try Self.decryptReport(text)
        guard let data = decrypted.data(using: .utf8) else {
            throw SleepWatchError.invalidSummaryResponse
        }
        return try JSONDecoder().decode(HealthReport.self, from: data)
    }

    func fetchSummary(sleepDate: String) async throws -> String {
        try validateConfig()

        return try await fetchContent(path: "summaries/\(sleepDate).md")
    }

    private func fetchContent(path: String) async throws -> String {
        var components = URLComponents(string: "https://api.github.com/repos/\(AppConfig.githubOwner)/\(AppConfig.githubRepo)/contents/\(path)")!
        components.queryItems = [URLQueryItem(name: "ref", value: AppConfig.githubBranch)]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(AppConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            throw SleepWatchError.summaryNotReady
        }
        try Self.ensureSuccess(response: response, data: data, expected: 200)

        let apiResponse = try JSONDecoder().decode(GitHubContentResponse.self, from: data)
        guard apiResponse.encoding == "base64",
              let decoded = Data(base64Encoded: apiResponse.content.filter { !$0.isWhitespace }),
              let text = String(data: decoded, encoding: .utf8) else {
            throw SleepWatchError.invalidSummaryResponse
        }

        return text
    }

    private func validateConfig() throws {
        let values = [
            AppConfig.githubOwner,
            AppConfig.githubRepo,
            AppConfig.githubBranch,
            AppConfig.githubToken,
            AppConfig.reportEncryptionKey
        ]
        if values.contains(where: { $0.contains("REPLACE") || $0.contains("YOUR_") || $0.isEmpty }) {
            throw SleepWatchError.githubConfigMissing
        }
    }

    private static func ensureSuccess(response: URLResponse, data: Data, expected: Int) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SleepWatchError.githubRequestFailed(-1, "Missing HTTP response")
        }
        guard httpResponse.statusCode == expected else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SleepWatchError.githubRequestFailed(httpResponse.statusCode, body)
        }
    }

    private static func decryptReport(_ text: String) throws -> String {
        let encrypted = try JSONDecoder().decode(EncryptedReport.self, from: Data(text.utf8))
        guard encrypted.algorithm == "AES-256-GCM",
              let keyData = Data(base64Encoded: AppConfig.reportEncryptionKey),
              keyData.count == 32,
              let combined = Data(base64Encoded: encrypted.combined) else {
            throw SleepWatchError.invalidSummaryResponse
        }

        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let opened = try AES.GCM.open(sealedBox, using: key)
        guard let report = String(data: opened, encoding: .utf8) else {
            throw SleepWatchError.invalidSummaryResponse
        }
        return report
    }
}

private struct WorkflowDispatchBody: Encodable {
    let ref: String
    let inputs: WorkflowDispatchInputs
}

private struct WorkflowDispatchInputs: Encodable {
    let payloadJSON: String

    enum CodingKeys: String, CodingKey {
        case payloadJSON = "payload_json"
    }
}

private struct GitHubContentResponse: Decodable {
    let content: String
    let encoding: String
}

private struct EncryptedReport: Decodable {
    let version: Int
    let algorithm: String
    let combined: String
}
