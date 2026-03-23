import Foundation

/// Hardcoded resource profiles for Phase 0.
///
/// Inspects the command argv to assign appropriate VM memory and CPU limits.
/// Phase 1 will replace this with a history-driven profile store (§4.6).
struct ActionProfile {
    let memoryMB: Int
    let cpus: Int

    static func forCommand(_ argv: [String]) -> ActionProfile {
        let executable = argv.first ?? ""
        let cmdLine = argv.joined(separator: " ")

        if executable.hasSuffix("verilator") || cmdLine.contains("verilator") {
            // Verilator Verilog→C++ codegen: single-threaded, moderate memory
            return ActionProfile(memoryMB: 512, cpus: 2)
        } else if executable.hasSuffix("make") || executable == "/usr/bin/make" {
            // make -j drives multiple g++ compilations concurrently.
            // Verilator-generated ALL.cpp amalgamation alone peaks ~500 MB;
            // 3 GB gives headroom for 4-6 parallel translation units.
            return ActionProfile(memoryMB: 3072, cpus: 4)
        } else if executable.hasSuffix("clang++") || executable.hasSuffix("g++") {
            // Individual C++ translation unit
            return ActionProfile(memoryMB: 512, cpus: 2)
        } else if cmdLine.contains("link") || cmdLine.contains("-o ") {
            // Link step
            return ActionProfile(memoryMB: 1024, cpus: 2)
        }
        // Default: genrule commands are wrapped as `bash -e <script>` by Buck2,
        // so the argv alone can't distinguish verilate/compile/link steps.
        // 3 GB gives headroom for make -j$(nproc) with Verilator-generated Makefiles
        // (~4 parallel g++ × ~400 MB each = ~1.6 GB peak).
        // Actions run serially (one VM at a time), so this is safe on an 8 GB host.
        return ActionProfile(memoryMB: 3072, cpus: 4)
    }
}
