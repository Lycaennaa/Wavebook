import Foundation

// Sampling timer and retry scheduling.
extension ListeningHistoryTracker {
    /// Starts periodic listening-history sampling.
    public func startSampling() {
        cancelPersistenceRetryTimer()
        guard samplingTimer == nil else { return }
        let timer = Timer(
            timeInterval: samplingInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.samplingTimerFired()
            }
        }
        samplingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops periodic listening-history sampling.
    public func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        cancelPersistenceRetryTimer()
    }

    func stopSamplingIfIdle() {
        guard valueState.activeSession?.isPlaying != true else {
            cancelPersistenceRetryTimer()
            return
        }
        stopSampling()
        schedulePersistenceRetryTimer()
    }

    func schedulePersistenceRetryTimer() {
        guard samplingTimer == nil else {
            cancelPersistenceRetryTimer()
            return
        }
        let persistence = valueState.persistence
        let retryTimes = [
            persistence.hasPendingMutations ? persistence.retryAtUptime : nil,
            persistence.recoveryPending ? persistence.recoveryRetryAtUptime : nil
        ].compactMap(\.self)
        guard let dueAtUptime = retryTimes.min() else {
            cancelPersistenceRetryTimer()
            return
        }
        cancelPersistenceRetryTimer()
        let delay = max(0, dueAtUptime - normalizedMonotonicTime(nil))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistenceRetryTimer = nil
                self.retryIfDue(atUptime: self.normalizedMonotonicTime(nil))
            }
        }
        persistenceRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPersistenceRetryTimer() {
        persistenceRetryTimer?.invalidate()
        persistenceRetryTimer = nil
    }

    func samplingTimerFired() {
        if let currentSample = sampleProvider() {
            sample(currentSample)
        } else {
            retryIfDue(atUptime: normalizedMonotonicTime(nil))
        }
    }

    func retryIfDue(atUptime: TimeInterval) {
        if valueState.persistence.recoveryPending,
           atUptime >= valueState.persistence.recoveryRetryAtUptime {
            attemptRecovery(atUptime: atUptime)
        }
        if valueState.persistence.hasPendingMutations,
           atUptime >= valueState.persistence.retryAtUptime {
            attemptPending(atUptime: atUptime)
        }
        schedulePersistenceRetryTimer()
    }
}
