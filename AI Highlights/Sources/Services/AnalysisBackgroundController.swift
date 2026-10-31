import BackgroundTasks
import Foundation
import UIKit

/// Core ML inference switches to CPU-only while backgrounded because this signing profile
/// doesn't include the background GPU or Neural Engine entitlements.
final class AnalysisExecutionPolicy: @unchecked Sendable {
    private let lock = NSCondition()
    private var background = false
    private var foregroundWork = 0
    private var observers: [NSObjectProtocol] = []

    @MainActor
    init() {
        background = UIApplication.shared.applicationState == .background
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setBackground(true) })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setBackground(false) })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setBackground(false) })
    }

    var isBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return background
    }

    private func setBackground(_ value: Bool) {
        lock.lock()
        background = value
        // Stop new GPU work and drain in-flight synchronous work before UIKit returns.
        while value && foregroundWork > 0 { lock.wait() }
        lock.unlock()
    }

    func withFrameAccess<T>(_ body: (Bool) throws -> T) rethrows -> T {
        lock.lock()
        let useBackground = background
        if !useBackground { foregroundWork += 1 }
        lock.unlock()
        defer {
            if !useBackground {
                lock.lock(); foregroundWork -= 1; lock.broadcast(); lock.unlock()
            }
        }
        return try body(useBackground)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class AnalysisBackgroundController {
    static let shared = AnalysisBackgroundController()
    // Signing tools can change the bundle identifier. Continued-processing IDs
    // must use the installed app's namespace, not the original repository's ID.
    private var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "com.openhoopvision.aihighlights") + ".analysis."
    }
    private var requestID: String?
    private var task: BGTask?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var onStart: (() -> Void)?
    private var onExpiration: (() -> Void)?

    func begin(onStart: @escaping () -> Void, onExpiration: @escaping () -> Void) throws {
        guard requestID == nil else { return }
        self.onStart = onStart
        self.onExpiration = onExpiration
        if #available(iOS 26.0, *), permitsContinuedProcessing {
            let id = identifierPrefix + UUID().uuidString
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
                Task { @MainActor in self?.accept(task) }
            }
            guard registered else {
                NSLog("Background analysis registration failed; starting foreground-compatible analysis.")
                beginLegacySession()
                return
            }
            requestID = id
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: String(localized: "Analyzing Game Video", bundle: AppLanguage.current.bundle), subtitle: String(localized: "Preparing to find shots", bundle: AppLanguage.current.bundle))
            do { try BGTaskScheduler.shared.submit(request) }
            catch {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
                requestID = nil
                NSLog("Background analysis submission failed; starting foreground-compatible analysis: %@", error.localizedDescription)
                beginLegacySession()
            }
        } else {
            beginLegacySession()
        }
    }

    private var permitsContinuedProcessing: Bool {
        // A re-signed app may still contain the original app's permitted IDs.
        // Skip registration in that case; foreground inference can still run.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.contains(identifierPrefix + "*")
    }

    private func beginLegacySession() {
        let id = identifierPrefix + UUID().uuidString
        requestID = id
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: String(localized: "Game video analysis", bundle: AppLanguage.current.bundle)) { [weak self] in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                self.onExpiration?()
                self.finish(success: false)
            }
        }
        // Even if the OS denies extra background time, foreground analysis must
        // start. Expiration of an accepted task keeps the existing pause/checkpoint flow.
        onStart?()
    }

    private func accept(_ task: BGTask) {
        guard task.identifier == requestID else { task.setTaskCompleted(success: false); return }
        self.task = task
        let id = task.identifier
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                self.onExpiration?()
                self.finish(success: false)
            }
        }
        onStart?()
    }

    func update(completedJobs: Int, remainingJobs: Int, fraction: Double, message: String) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(max(1, completedJobs + remainingJobs)) * 1000
        task.progress.completedUnitCount = min(task.progress.totalUnitCount,
            Int64(completedJobs * 1000) + Int64(min(1, max(0, fraction)) * 1000))
        task.updateTitle(String(localized: "Analyzing Game Video", bundle: AppLanguage.current.bundle), subtitle: message)
    }

    func finish(success: Bool) {
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask, success {
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task?.setTaskCompleted(success: success)
        task = nil
        if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        requestID = nil
        if legacyTask != .invalid { UIApplication.shared.endBackgroundTask(legacyTask); legacyTask = .invalid }
        onStart = nil
        onExpiration = nil
    }
}

