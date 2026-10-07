import CoreVideo
import Foundation
import UIKit

enum VitalStatus: Equatable {
    case noHuman
    case moving
    case still(TimeInterval)
    case deceased
}

enum ModelState: Equatable {
    case idle
    case downloading(Float)
    case ready
    case failed(String)
}

/// Wires camera -> Vision presence/motion -> state machine -> recorder, and runs the
/// on-device LFM2.5-VL observer in a loop on the latest frame.
@MainActor
@Observable
final class BlackboxEngine {
    let recorder = FlightRecorder()
    let camera = CameraService()

    private(set) var status: VitalStatus = .noHuman
    private(set) var modelState: ModelState = .idle
    private(set) var lastObservation = ""
    private(set) var lastObservationMs = 0
    private(set) var startedAt = Date()
    private(set) var usingFrontCamera = false

    /// Demo mode declares death after 10 s; "real" mode after 2 h.
    var demoMode = true
    var inactivityLimit: TimeInterval { demoMode ? 10 : 2 * 60 * 60 }

    @ObservationIgnored private let monitor = HumanMonitor()
    @ObservationIgnored private let observer = SceneObserver()
    @ObservationIgnored private let frameLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var latestFrame: CVPixelBuffer?
    @ObservationIgnored nonisolated(unsafe) private var lastAnalysis = Date.distantPast

    @ObservationIgnored private var humanPresent = false
    @ObservationIgnored private var lastSeen = Date.distantPast
    @ObservationIgnored private var lastMovement = Date()
    @ObservationIgnored private var lastLoo = Date.distantPast
    @ObservationIgnored private var motionHistory: [Bool] = []
    @ObservationIgnored private var started = false

    /// How long a human stays "present" after Vision last saw them (covers detector flicker).
    private let presenceHold: TimeInterval = 8

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        recorder.record(.sessionStart, "Blackbox armed. Crew declared lost after \(limitLabel) without movement.")

        camera.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.frameLock.lock()
            self.latestFrame = buffer
            let due = Date().timeIntervalSince(self.lastAnalysis) > 0.2
            if due { self.lastAnalysis = Date() }
            self.frameLock.unlock()
            guard due else { return }
            let sample = self.monitor.analyze(buffer)
            Task { @MainActor in self.ingest(sample) }
        }
        camera.start()

        Task { await loadModelAndObserve() }
        Task { await tick() }
    }

    func toggleCamera() {
        usingFrontCamera.toggle()
        camera.toggleCamera()
        motionHistory.removeAll()
        recorder.record(.system, "Switched to \(usingFrontCamera ? "front" : "back") camera.")
    }

    var limitLabel: String { demoMode ? "10 s (demo)" : "2 h" }

    private func currentFrame() -> CVPixelBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return latestFrame
    }

    // MARK: - Vitals state machine

    private func ingest(_ sample: HumanSample) {
        let now = Date()
        if sample.humanPresent { lastSeen = now }

        // Debounce: a single noisy frame must not reset the death timer.
        motionHistory.append(sample.box != nil && sample.moved)
        if motionHistory.count > 3 { motionHistory.removeFirst() }
        let moved = motionHistory.filter { $0 }.count >= 2
        if moved { lastSeen = now }
        let present = now.timeIntervalSince(lastSeen) < presenceHold

        if present && !humanPresent {
            humanPresent = true
            lastMovement = now
            recorder.record(.humanDetected, "Astronaut in view and alive.", jpeg: snapshot())
        } else if !present && humanPresent {
            humanPresent = false
            if status != .deceased {
                recorder.record(.humanLeft, "No astronaut visible.", jpeg: snapshot())
                status = .noHuman
            }
        }

        if moved {
            motionHistory.removeAll()
            let stillFor = now.timeIntervalSince(lastMovement)
            lastMovement = now
            if status == .deceased {
                recorder.record(.revived, "Movement detected. Astronaut is alive.", jpeg: snapshot())
            } else if stillFor > 5 {
                recorder.record(.movementResumed, String(format: "Moved after %.0f s still.", stillFor))
            }
            status = .moving
        }
    }

    /// Advances the stillness timer even when no new samples change state.
    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard humanPresent || status == .deceased else { continue }
            guard status != .deceased else { continue }
            let still = Date().timeIntervalSince(lastMovement)
            if still >= inactivityLimit {
                status = .deceased
                recorder.record(.deceased,
                                "No movement for \(limitLabel). Astronaut declared lost. Last scene: \(lastObservation.isEmpty ? "n/a" : lastObservation)",
                                jpeg: snapshot())
            } else if still > 1 {
                status = .still(still)
            } else {
                status = .moving
            }
        }
    }

    private func snapshot() -> Data? {
        currentFrame().flatMap { observer.jpegData(from: $0) }
    }

    // MARK: - On-device VLM observer

    private func loadModelAndObserve() async {
        modelState = .downloading(0)
        do {
            try await observer.load { progress in
                Task { @MainActor in self.modelState = .downloading(progress) }
            }
            modelState = .ready
            recorder.record(.system, "\(SceneObserver.modelName) loaded on-device via Melange.")
        } catch {
            modelState = .failed(error.localizedDescription)
            recorder.record(.system, "Model failed to load: \(error.localizedDescription)")
            return
        }

        while !Task.isCancelled {
            guard let frame = currentFrame() else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            let begin = Date()
            let observer = observer
            let text = (try? await Task.detached(priority: .userInitiated) {
                try await observer.describe(frame)
            }.value) ?? ""
            lastObservationMs = Int(Date().timeIntervalSince(begin) * 1000)
            if !text.isEmpty {
                // The VLM is a second, slower presence detector covering Vision dropouts.
                if Self.mentionsPerson(text) { lastSeen = Date() }
                guard text != lastObservation else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                lastObservation = text
                recorder.record(.observation, text, jpeg: snapshot())
                checkForLoo(text)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    static func mentionsPerson(_ text: String) -> Bool {
        let lower = text.lowercased()
        let negations = ["no person", "no one", "nobody", "no people", "no human", "not visible", "no visible person", "empty"]
        if negations.contains(where: lower.contains) { return false }
        let subjects = ["person", "man", "woman", "people", "someone", "human", "boy", "girl", "child", "individual"]
        return subjects.contains { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    private func checkForLoo(_ text: String) {
        let lower = text.lowercased()
        let words = ["toilet", "bathroom", "restroom", "lavatory", "loo", "urinal", "washroom", "wc"]
        // A keyword counts only if no negation ("no", "not", "n't") appears just before it.
        let positive = words.contains { (word: String) -> Bool in
            var searchRange = lower.startIndex..<lower.endIndex
            while let hit = lower.range(of: "\\b\(word)\\b", options: .regularExpression, range: searchRange) {
                let before = lower[(lower.index(hit.lowerBound, offsetBy: -60, limitedBy: lower.startIndex) ?? lower.startIndex)..<hit.lowerBound]
                let negated = before.range(of: "\\b(no|not|without)\\b|n't", options: .regularExpression) != nil
                if !negated { return true }
                searchRange = hit.upperBound..<lower.endIndex
            }
            return false
        }
        guard positive, Date().timeIntervalSince(lastLoo) > 30 else { return }
        lastLoo = Date()
        recorder.record(.loo, "Astronaut on a loo break. \(text)", jpeg: snapshot())
    }
}
