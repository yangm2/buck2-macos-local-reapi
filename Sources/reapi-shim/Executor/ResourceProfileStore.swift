import Foundation

/// An observed resource profile for a completed action.
struct ObservedProfile {
    /// Peak resident set size of the container process, in mebibytes.
    let memoryMB: Int
    /// Wall-clock duration of the container run, in seconds.
    let wallTimeSec: Double
}

/// In-memory store that accumulates post-hoc resource observations per action
/// and derives VM limit heuristics for future runs of the same action.
///
/// On the first execution of any action the ``ActionProfile/conservative``
/// default is used. On subsequent executions the observed peak memory is
/// inflated by a 25 % headroom factor to size the VM.
actor ResourceProfileStore {
    private var history: [String: ObservedProfile] = [:]

    // MARK: - Recording

    func record(hash: String, memoryMB: Int, wallTimeSec: Double) {
        history[hash] = ObservedProfile(memoryMB: memoryMB, wallTimeSec: wallTimeSec)
    }

    // MARK: - Lookup

    /// Returns a profile derived from past observations, or `nil` if the action
    /// has not been executed before.
    func profile(for hash: String) -> ActionProfile? {
        guard let obs = history[hash] else { return nil }
        let headroom = Int(Double(obs.memoryMB) * 1.25)
        return ActionProfile(memoryMB: max(headroom, 512), cpus: 4)
    }
}
