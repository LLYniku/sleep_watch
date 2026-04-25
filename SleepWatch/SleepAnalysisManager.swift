import Foundation
import UserNotifications
import WatchKit

final class SleepAnalysisManager {
    private let sleepStore = HealthKitSleepStore()
    private let github = GitHubClient()

    func authorize() async throws {
        try await sleepStore.requestAuthorization()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func uploadPreviousNightAndFetchSummary() async throws -> String {
        try await authorize()
        let payload = try await sleepStore.fetchDailyHealth()
        try await github.dispatchHealthPayload(payload)

        return try await waitForSummary(reportDate: payload.analysisDate)
    }

    func uploadDailyHealthAndFetchReport() async throws -> HealthReport {
        try await authorize()
        let payload = try await sleepStore.fetchDailyHealth()
        try await github.dispatchHealthPayload(payload)

        let report = try await waitForReport(reportDate: payload.analysisDate)
        LastReportStore.save(report)
        return report
    }

    func uploadDailyHealthAndNotifyReport() async throws -> HealthReport {
        let report = try await uploadDailyHealthAndFetchReport()
        await notify(title: "健康报告", body: Self.notificationBody(from: report))
        return report
    }

    func fetchLatestSummary() async throws -> String {
        let payload = try await sleepStore.fetchDailyHealth()
        return try await github.fetchSummary(sleepDate: payload.analysisDate)
    }

    func fetchLatestReport() async throws -> HealthReport {
        let payload = try await sleepStore.fetchDailyHealth()
        let report = try await github.fetchReport(reportDate: payload.analysisDate)
        LastReportStore.save(report)
        return report
    }

    func cachedReport() -> HealthReport? {
        LastReportStore.load()
    }

    func uploadPreviousNightAndNotify() async throws -> String {
        let summary = try await uploadPreviousNightAndFetchSummary()
        let body = Self.notificationBody(from: summary)
        await notify(title: "健康总结", body: body)
        return body
    }

    func runBackgroundAnalysis() async {
        do {
            _ = try await uploadDailyHealthAndNotifyReport()
        } catch SleepWatchError.summaryNotReady {
            await notify(title: "健康分析处理中", body: "数据已上传，稍后打开 App 可再次触发通知。")
        } catch {
            await notify(title: "健康分析失败", body: error.localizedDescription)
        }
    }

    func scheduleNextMorningRefresh() {
        let nextDate = Self.nextMorningDate()
        WKExtension.shared().scheduleBackgroundRefresh(withPreferredDate: nextDate, userInfo: nil) { error in
            if let error {
                print("Failed to schedule background refresh: \(error)")
            }
        }
    }

    private func notify(title: String, body: String) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["daily-health-summary"])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "daily-health-summary", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func waitForReport(reportDate: String) async throws -> HealthReport {
        let delays: [UInt64] = [30, 45, 60, 90, 120, 180]
        for delay in delays {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            do {
                return try await github.fetchReport(reportDate: reportDate)
            } catch SleepWatchError.summaryNotReady {
                continue
            }
        }
        throw SleepWatchError.summaryNotReady
    }

    private func waitForSummary(reportDate: String) async throws -> String {
        let delays: [UInt64] = [30, 45, 60, 90, 120, 180]
        for delay in delays {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            do {
                return try await github.fetchSummary(sleepDate: reportDate)
            } catch SleepWatchError.summaryNotReady {
                continue
            }
        }
        throw SleepWatchError.summaryNotReady
    }

    private static func nextMorningDate(from now: Date = Date()) -> Date {
        var calendar = Calendar.current
        calendar.locale = Locale.current

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = AppConfig.morningHour
        components.minute = AppConfig.morningMinute
        components.second = 0

        let today = calendar.date(from: components) ?? now
        if today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    private static func notificationBody(from markdown: String) -> String {
        let lines = markdown
            .split(separator: "\n")
            .map { line in
                line
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("Generated at") }

        let body = lines
            .filter { !$0.hasPrefix("-") }
            .dropFirst()
            .prefix(3)
            .joined(separator: "\n")

        return body.isEmpty ? "今天的睡眠总结已生成。" : body
    }

    private static func notificationBody(from report: HealthReport) -> String {
        let keySections = report.sections
            .prefix(2)
            .map { "\($0.title)：\($0.status)，\($0.advice)" }
            .joined(separator: "\n")

        let headline = "\(report.overall.title)（\(report.overall.score)分）"
        let recommendation = report.overall.recommendation

        if keySections.isEmpty {
            return "\(headline)\n\(recommendation)"
        }
        return "\(headline)\n\(recommendation)\n\(keySections)"
    }
}

private enum LastReportStore {
    private static let key = "last_health_report_v1"

    static func load() -> HealthReport? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(HealthReport.self, from: data)
    }

    static func save(_ report: HealthReport) {
        guard let data = try? JSONEncoder().encode(report) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
