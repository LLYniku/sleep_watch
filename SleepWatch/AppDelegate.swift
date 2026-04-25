import Foundation
import WatchKit

final class AppDelegate: NSObject, WKApplicationDelegate {
    private let manager = SleepAnalysisManager()

    func applicationDidFinishLaunching() {
        manager.scheduleNextMorningRefresh()
    }

    func applicationDidBecomeActive() {
        manager.scheduleNextMorningRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if task is WKApplicationRefreshBackgroundTask {
                Task {
                    await manager.runBackgroundAnalysis()
                    manager.scheduleNextMorningRefresh()
                    task.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

