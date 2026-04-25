import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SleepViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StatusHeader(
                        title: viewModel.title,
                        message: viewModel.message,
                        isWorking: viewModel.isWorking
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        MetricRow(label: "计划", value: "每天 09:00")
                        MetricRow(label: "模式", value: "健康报告")
                        MetricRow(label: "本地保存", value: viewModel.cachedReportStatus)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if !viewModel.notificationPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("今日通知预览", systemImage: "bell")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(viewModel.notificationPreview)
                                .font(.footnote)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            Task { await viewModel.analyzeNow() }
                        } label: {
                            Label("生成健康报告", systemImage: "waveform.path.ecg")
                        }
                        .disabled(viewModel.isWorking)

                        Button {
                            Task { await viewModel.refreshLatestReport() }
                        } label: {
                            Label("刷新报告", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isWorking)
                    }

                    if let report = viewModel.report {
                        OverallCard(overall: report.overall)

                        ForEach(report.sections) { section in
                            ReportSectionCard(section: section)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("分析板块", systemImage: "chart.bar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MetricRow(label: "恢复", value: "睡眠 / HRV / 静息心率")
                            MetricRow(label: "久坐", value: "步数 / 站立 / 活动")
                            MetricRow(label: "压力", value: "心率 / 呼吸 / 血氧")
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .navigationTitle("健康")
            .task {
                await viewModel.prepare()
            }
        }
    }
}

private struct StatusHeader: View {
    let title: String
    let message: String
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isWorking ? "arrow.triangle.2.circlepath" : "moon.zzz")
                    .imageScale(.medium)
                Text(title)
                    .font(.headline)
            }

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
        }
    }
}

private struct OverallCard: View {
    let overall: ReportOverall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(overall.score)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("总评分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(overall.title)
                    .font(.caption)
            }
            Text(overall.assessment)
                .font(.footnote)
            Text(overall.recommendation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.blue.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReportSectionCard: View {
    let section: ReportSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(section.score)")
                    .font(.caption)
                    .monospacedDigit()
            }

            Text(section.status)
                .font(.caption)
                .foregroundStyle(statusColor)

            ForEach(section.metrics) { metric in
                MetricRow(label: metric.label, value: metric.value)
            }

            Text(section.assessment)
                .font(.footnote)

            Text(section.advice)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusColor: Color {
        switch section.status {
        case "优秀":
            return .green
        case "注意":
            return .yellow
        case "风险":
            return .red
        default:
            return .secondary
        }
    }
}

@MainActor
final class SleepViewModel: ObservableObject {
    @Published var title = "等待授权"
    @Published var message = "首次运行需要允许读取 HealthKit 健康数据。"
    @Published var notificationPreview = ""
    @Published var report: HealthReport?
    @Published var isWorking = false
    @Published var cachedReportStatus = "上一份报告"

    private let manager = SleepAnalysisManager()

    func prepare() async {
        if let cached = manager.cachedReport() {
            report = cached
            notificationPreview = "\(cached.overall.title)：\(cached.overall.recommendation)"
            cachedReportStatus = cached.reportDate
            title = "已载入上次报告"
            message = "这份报告会一直保留，直到下一次分析或刷新成功后覆盖。"
        }

        do {
            try await manager.authorize()
            manager.scheduleNextMorningRefresh()
            if report == nil {
                title = "已准备"
                message = "每天 09:00 会尝试生成个人健康报告。"
            }
        } catch {
            title = "授权失败"
            message = error.localizedDescription
        }
    }

    func analyzeNow() async {
        isWorking = true
        title = "分析中"
        message = "正在读取健康数据、上传 GitHub 并等待 AI 报告。"
        defer { isWorking = false }

        do {
            report = try await manager.uploadDailyHealthAndNotifyReport()
            updateCachedReportStatus()
            title = "报告已生成"
            message = "已完成总体评价和分项建议，并已通过通知弹出。"
        } catch SleepWatchError.summaryNotReady {
            title = "数据已上传"
            message = report == nil ? "Action 还没写入报告，稍后可点刷新报告。" : "Action 还没写入新报告，当前仍显示上一次报告。"
        } catch {
            title = "分析失败"
            message = report == nil ? error.localizedDescription : "\(error.localizedDescription) 当前仍显示上一次报告。"
        }
    }

    func refreshLatestReport() async {
        isWorking = true
        title = "刷新中"
        message = "正在读取最新健康报告。"
        defer { isWorking = false }

        do {
            report = try await manager.fetchLatestReport()
            updateCachedReportStatus()
            title = "报告已更新"
            message = "已载入最新 AI 健康评价。"
        } catch SleepWatchError.summaryNotReady {
            title = "暂无报告"
            message = report == nil ? "GitHub 还没有生成今天的健康报告。" : "GitHub 还没有生成今天的新报告，当前仍显示上一次报告。"
        } catch {
            title = "刷新失败"
            message = report == nil ? error.localizedDescription : "\(error.localizedDescription) 当前仍显示上一次报告。"
        }
    }

    private func updateCachedReportStatus() {
        guard let report else {
            cachedReportStatus = "上一份报告"
            notificationPreview = ""
            return
        }
        cachedReportStatus = report.reportDate
        notificationPreview = "\(report.overall.title)：\(report.overall.recommendation)"
    }
}

#Preview {
    ContentView()
}
