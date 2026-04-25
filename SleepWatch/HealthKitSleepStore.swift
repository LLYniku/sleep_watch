import Foundation
import HealthKit

final class HealthKitSleepStore {
    private let healthStore = HKHealthStore()
    private let isoFormatter = ISO8601DateFormatter()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SleepWatchError.healthDataUnavailable
        }

        var readTypes = Set<HKObjectType>()
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readTypes.insert(sleepType)
        }
        if let standType = HKObjectType.categoryType(forIdentifier: .appleStandHour) {
            readTypes.insert(standType)
        }

        for spec in Self.metricSpecs {
            if let type = HKObjectType.quantityType(forIdentifier: spec.identifier) {
                readTypes.insert(type)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SleepWatchError.healthDataUnavailable)
                }
            }
        }
    }

    func fetchDailyHealth(referenceDate: Date = Date()) async throws -> HealthPayload {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: referenceDate)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let windowStart = previousDay
        let windowEnd = dayStart
        let sleepWindowStart = calendar.date(byAdding: .hour, value: 18, to: previousDay) ?? previousDay
        let sleepWindowEnd = calendar.date(byAdding: .hour, value: 12, to: dayStart) ?? referenceDate

        let metrics = await fetchQuantityMetrics(start: windowStart, end: windowEnd)
        var gaps = metrics
            .filter { $0.sampleCount == 0 }
            .map { "\($0.title) has no samples in the analysis window." }

        let sleep = await fetchSleepSamples(start: sleepWindowStart, end: sleepWindowEnd)
        if sleep.isEmpty {
            gaps.append("Sleep Analysis has no samples in the previous-night window.")
        }

        let standHours = await fetchStandHours(start: windowStart, end: windowEnd)
        if standHours.isEmpty {
            gaps.append("Apple Stand Hour has no samples in the analysis window.")
        }

        return HealthPayload(
            analysisDate: Self.dateOnlyFormatter.string(from: referenceDate),
            windowStart: isoFormatter.string(from: windowStart),
            windowEnd: isoFormatter.string(from: windowEnd),
            sleepWindowStart: isoFormatter.string(from: sleepWindowStart),
            sleepWindowEnd: isoFormatter.string(from: sleepWindowEnd),
            generatedAt: isoFormatter.string(from: Date()),
            source: "apple_watch_healthkit",
            sleepSamples: sleep,
            quantityMetrics: metrics,
            standHours: standHours,
            dataGaps: gaps
        )
    }

    func fetchPreviousNight(referenceDate: Date = Date()) async throws -> SleepPayload {
        let health = try await fetchDailyHealth(referenceDate: referenceDate)
        return SleepPayload(
            sleepDate: health.analysisDate,
            windowStart: health.sleepWindowStart,
            windowEnd: health.sleepWindowEnd,
            generatedAt: health.generatedAt,
            source: health.source,
            samples: health.sleepSamples
        )
    }

    private func fetchSleepSamples(start: Date, end: Date) async -> [SleepStageSample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKCategorySample]
        do {
            samples = try await fetchSamples(type: sleepType, predicate: predicate, sort: [sort])
        } catch {
            return []
        }

        return samples.map { sample in
            SleepStageSample(
                stage: Self.stageName(for: sample.value),
                start: isoFormatter.string(from: sample.startDate),
                end: isoFormatter.string(from: sample.endDate),
                durationMinutes: (sample.endDate.timeIntervalSince(sample.startDate) / 60.0).rounded(toPlaces: 1),
                rawValue: sample.value
            )
        }
    }

    private func fetchQuantityMetrics(start: Date, end: Date) async -> [HealthQuantityMetric] {
        var results: [HealthQuantityMetric] = []
        for spec in Self.metricSpecs {
            guard let type = HKObjectType.quantityType(forIdentifier: spec.identifier) else {
                continue
            }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let samples: [HKQuantitySample]
            do {
                samples = try await fetchSamples(type: type, predicate: predicate, sort: [sort])
            } catch {
                samples = []
            }

            let statistics: HKStatistics
            do {
                statistics = try await fetchStatistics(type: type, predicate: predicate, options: spec.statisticsOptions)
            } catch {
                results.append(Self.emptyMetric(for: spec, samples: samples, formatter: isoFormatter))
                continue
            }

            var value: Double?
            var average: Double?
            var minimum: Double?
            var maximum: Double?

            if spec.aggregation == "sum" {
                value = statistics.sumQuantity()?.doubleValue(for: spec.unit).scaled(by: spec.scale)
                average = nil
                minimum = nil
                maximum = nil
            } else {
                average = statistics.averageQuantity()?.doubleValue(for: spec.unit).scaled(by: spec.scale)
                minimum = statistics.minimumQuantity()?.doubleValue(for: spec.unit).scaled(by: spec.scale)
                maximum = statistics.maximumQuantity()?.doubleValue(for: spec.unit).scaled(by: spec.scale)
                value = average
            }

            if value == nil && average == nil && minimum == nil && maximum == nil {
                value = nil
                average = nil
                minimum = nil
                maximum = nil
            }

            results.append(Self.metric(for: spec, samples: samples, value: value, average: average, minimum: minimum, maximum: maximum, formatter: isoFormatter))
        }
        return results
    }

    private func fetchStatistics(
        type: HKQuantityType,
        predicate: NSPredicate,
        options: HKStatisticsOptions
    ) async throws -> HKStatistics {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let statistics else {
                    continuation.resume(throwing: SleepWatchError.healthDataUnavailable)
                    return
                }
                continuation.resume(returning: statistics)
            }
            healthStore.execute(query)
        }
    }

    private func fetchStandHours(start: Date, end: Date) async -> [StandHourSample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .appleStandHour) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKCategorySample]
        do {
            samples = try await fetchSamples(type: type, predicate: predicate, sort: [sort])
        } catch {
            return []
        }

        return samples.map { sample in
            StandHourSample(
                start: isoFormatter.string(from: sample.startDate),
                end: isoFormatter.string(from: sample.endDate),
                stood: sample.value == HKCategoryValueAppleStandHour.stood.rawValue
            )
        }
    }

    private static func emptyMetric(for spec: MetricSpec, samples: [HKQuantitySample], formatter: ISO8601DateFormatter) -> HealthQuantityMetric {
        metric(for: spec, samples: samples, value: nil, average: nil, minimum: nil, maximum: nil, formatter: formatter)
    }

    private static func metric(
        for spec: MetricSpec,
        samples: [HKQuantitySample],
        value: Double?,
        average: Double?,
        minimum: Double?,
        maximum: Double?,
        formatter: ISO8601DateFormatter
    ) -> HealthQuantityMetric {
        HealthQuantityMetric(
            id: spec.id,
            title: spec.title,
            unit: spec.unitLabel,
            aggregation: spec.aggregation,
            value: value,
            average: average,
            minimum: minimum,
            maximum: maximum,
            sampleCount: samples.count,
            start: samples.first.map { formatter.string(from: $0.startDate) },
            end: samples.last.map { formatter.string(from: $0.endDate) }
        )
    }

    private func fetchSamples<T: HKSample>(type: HKSampleType, predicate: NSPredicate, sort: [NSSortDescriptor]) async throws -> [T] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [T] ?? [])
            }
            healthStore.execute(query)
        }
    }

    private struct MetricSpec {
        let id: String
        let title: String
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let unitLabel: String
        let aggregation: String
        let scale: Double
        let statisticsOptions: HKStatisticsOptions

        init(
            id: String,
            title: String,
            identifier: HKQuantityTypeIdentifier,
            unit: HKUnit,
            unitLabel: String,
            aggregation: String,
            scale: Double = 1
        ) {
            self.id = id
            self.title = title
            self.identifier = identifier
            self.unit = unit
            self.unitLabel = unitLabel
            self.aggregation = aggregation
            self.scale = scale
            self.statisticsOptions = aggregation == "sum" ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        }
    }

    private static let metricSpecs: [MetricSpec] = [
        MetricSpec(id: "heart_rate", title: "心率", identifier: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "bpm", aggregation: "average"),
        MetricSpec(id: "resting_heart_rate", title: "静息心率", identifier: .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "bpm", aggregation: "average"),
        MetricSpec(id: "hrv_sdnn", title: "心率变异性", identifier: .heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), unitLabel: "ms", aggregation: "average"),
        MetricSpec(id: "respiratory_rate", title: "呼吸频率", identifier: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "次/分", aggregation: "average"),
        MetricSpec(id: "oxygen_saturation", title: "血氧", identifier: .oxygenSaturation, unit: .percent(), unitLabel: "%", aggregation: "average", scale: 100),
        MetricSpec(id: "steps", title: "步数", identifier: .stepCount, unit: .count(), unitLabel: "步", aggregation: "sum"),
        MetricSpec(id: "active_energy", title: "活动能量", identifier: .activeEnergyBurned, unit: .kilocalorie(), unitLabel: "kcal", aggregation: "sum"),
        MetricSpec(id: "exercise_minutes", title: "锻炼时间", identifier: .appleExerciseTime, unit: .minute(), unitLabel: "分钟", aggregation: "sum"),
        MetricSpec(id: "stand_minutes", title: "站立时间", identifier: .appleStandTime, unit: .minute(), unitLabel: "分钟", aggregation: "sum"),
        MetricSpec(id: "walking_distance", title: "步行距离", identifier: .distanceWalkingRunning, unit: HKUnit.meterUnit(with: .kilo), unitLabel: "km", aggregation: "sum"),
        MetricSpec(id: "flights_climbed", title: "爬楼", identifier: .flightsClimbed, unit: .count(), unitLabel: "层", aggregation: "sum")
    ]

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func stageName(for rawValue: Int) -> String {
        switch rawValue {
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            return "in_bed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return "asleep_unspecified"
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return "awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return "asleep_core"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return "asleep_deep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return "asleep_rem"
        default:
            return "unknown_\(rawValue)"
        }
    }
}

private extension Double {
    func scaled(by scale: Double) -> Double {
        (self * scale).rounded(toPlaces: 1)
    }

    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
