import Foundation

struct HealthPayload: Codable {
    let analysisDate: String
    let windowStart: String
    let windowEnd: String
    let sleepWindowStart: String
    let sleepWindowEnd: String
    let generatedAt: String
    let source: String
    let sleepSamples: [SleepStageSample]
    let quantityMetrics: [HealthQuantityMetric]
    let standHours: [StandHourSample]
    let dataGaps: [String]

    enum CodingKeys: String, CodingKey {
        case analysisDate = "analysis_date"
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case sleepWindowStart = "sleep_window_start"
        case sleepWindowEnd = "sleep_window_end"
        case generatedAt = "generated_at"
        case source
        case sleepSamples = "sleep_samples"
        case quantityMetrics = "quantity_metrics"
        case standHours = "stand_hours"
        case dataGaps = "data_gaps"
    }
}

struct SleepPayload: Codable {
    let sleepDate: String
    let windowStart: String
    let windowEnd: String
    let generatedAt: String
    let source: String
    let samples: [SleepStageSample]

    enum CodingKeys: String, CodingKey {
        case sleepDate = "sleep_date"
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case generatedAt = "generated_at"
        case source
        case samples
    }
}

struct SleepStageSample: Codable, Hashable {
    let stage: String
    let start: String
    let end: String
    let durationMinutes: Double
    let rawValue: Int

    enum CodingKeys: String, CodingKey {
        case stage
        case start
        case end
        case durationMinutes = "duration_minutes"
        case rawValue = "raw_value"
    }
}

struct HealthQuantityMetric: Codable, Hashable {
    let id: String
    let title: String
    let unit: String
    let aggregation: String
    let value: Double?
    let average: Double?
    let minimum: Double?
    let maximum: Double?
    let sampleCount: Int
    let start: String?
    let end: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case unit
        case aggregation
        case value
        case average
        case minimum
        case maximum
        case sampleCount = "sample_count"
        case start
        case end
    }
}

struct StandHourSample: Codable, Hashable {
    let start: String
    let end: String
    let stood: Bool

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case stood
    }
}

struct HealthReport: Codable {
    let reportDate: String
    let overall: ReportOverall
    let sections: [ReportSection]
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        case reportDate = "report_date"
        case overall
        case sections
        case generatedAt = "generated_at"
    }
}

struct ReportOverall: Codable {
    let score: Int
    let title: String
    let assessment: String
    let recommendation: String
}

struct ReportSection: Codable, Identifiable {
    let id: String
    let title: String
    let status: String
    let score: Int
    let assessment: String
    let advice: String
    let metrics: [ReportMetric]
}

struct ReportMetric: Codable, Identifiable {
    let id = UUID()
    let label: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case label
        case value
    }
}

enum SleepWatchError: LocalizedError {
    case healthDataUnavailable
    case sleepTypeUnavailable
    case githubConfigMissing
    case githubRequestFailed(Int, String)
    case summaryNotReady
    case invalidSummaryResponse

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "This watch cannot access HealthKit data."
        case .sleepTypeUnavailable:
            return "Sleep Analysis is unavailable in HealthKit."
        case .githubConfigMissing:
            return "GitHub owner, repo, branch, or token is not configured."
        case .githubRequestFailed(let code, let body):
            return "GitHub request failed with HTTP \(code): \(body)"
        case .summaryNotReady:
            return "The GitHub health report is not ready yet."
        case .invalidSummaryResponse:
            return "GitHub returned an invalid health report response."
        }
    }
}
