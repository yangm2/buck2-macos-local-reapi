/// VM resource limits for a single container action.
///
/// The conservative default is applied on the first execution of any action.
/// Subsequent executions use limits derived from observed peak usage recorded
/// in ``ResourceProfileStore``, inflated by a 25 % headroom factor.
struct ActionProfile {
    let memoryMB: Int
    let cpus: Int

    /// Conservative fallback used when no prior observation is available.
    ///
    /// 3 GiB gives headroom for a Verilator `make -j$(nproc)` build
    /// (~4 parallel g++ × ~400 MiB each ≈ 1.6 GiB peak). Actions run
    /// serially (one VM at a time) so this is safe on an 8 GiB host.
    static let conservative = ActionProfile(memoryMB: 3072, cpus: 4)
}
