# Verilator Example Test Case

## Overview

Repository: https://github.com/yangm2/verilator-example

This is a real Buck2 + Verilator project that exercises the complete build+simulate workflow described in §7.6 of DEVELOPMENT.md.

## Setup

```bash
git clone --recurse-submodules https://github.com/yangm2/verilator-example.git
cd verilator-example
```

## Current Status (Phase 0 Sandboxed — 2026-03-23)

✅ **Builds via RE**: `buck2 build //src:Vhello_world` — 2 remote actions, ~10s cold, ~0s rebuild
✅ **Simulation verified**: binary executes inside `verilator-toolchain:latest`, 100 cycles in ~3ms
✅ **Hermeticity confirmed**: build fails when `sim_main.cpp` removed from declared srcs
✅ **Verilator version**: 5.044 (via nix in container, matching host)

## Previous Status (Unsandboxed Local Build)

✅ **Builds successfully**: `buck2 build //src:Vhello_world`
- Runs `verilator` to convert SystemVerilog → C++
- Compiles generated C++ + testbench with `clang++`
- Links into executable simulation binary
- Total time: ~7-10 seconds
- Generated files: VCD/FST waveforms

✅ **Simulation runs**: `buck2 run //src:sim100`
- Executes simulation binary with 100 max cycles
- Produces cycle-accurate output
- All assertions pass
- Walltime: ~7ms

## Build Targets

| Target | What It Does |
|--------|---|
| `//src:verilator` | Run verilator on SystemVerilog sources (genrule) |
| `//src:Vhello_world` | Compile verilated C++ + testbench, link to binary (genrule) |
| `//src:sim100` | Run simulation with MAX_CYCLES=100 (command_alias) |

## Project Structure

```
src/
  BUCK.v2              # Build definition
  hello_world.sv       # Simple DUT with counter
  example_passive_ifc.sv
  example_active_ifc.sv
  sim_main.cpp         # Testbench entry point
  example_vpi.cpp      # VPI/C++ testbench monitor
```

## Design Under Test (DUT)

- **Counter**: Simple incrementing counter with valid interface
- **Testbench**: SV + C++ hybrid, exercises counter, checks outputs
- **Assertions**: Multiple pass/fail checks in testbench
- **Tracing**: VCD/FST waveform generation enabled

## Phase 0 Testing Goals

Using this test case, Phase 0 should:

1. **✓ Hermeticity**: Build inside Apple Container VM without host-level Verilator or C++ toolchain
2. **✓ Isolation**: Each action (verilate, cxx_compile, cxx_link, simulate) runs in ephemeral VM
3. **✓ Reproducibility**: Identical outputs for identical inputs via CAS digests
4. **✓ Simulation**: Simulation binary executes inside container, produces waveforms accessible on host
5. **✓ Performance**: 8 GB MacBook Pro build completes with <2x overhead vs. unsandboxed

## Success Metrics

| Metric | Target | Unsandboxed | Sandboxed |
|--------|--------|-------------|-----------|
| Build time (verilate + compile + link) | <15s | ~8-10s | **~10s** (2 remote actions) |
| Simulation run time | <100ms | ~7ms | **~3ms** (inside container) |
| Peak host memory | <7 GB | ~500 MB | ~3 GB container limit |
| VCD/FST output | readable in GTKWave | ✓ | ✓ (produced in container) |
| Cache hit rate (rebuild) | ≥95% | (no local cache yet) | **100%** (0.02s rebuild) |

## Notes for Phase 0 Implementation

1. **OCI Toolchain Image**: Must contain:
   - `verilator` binary (5.044 or compatible)
   - `clang++` or `g++` with C++20 support
   - `make` (for Verilator's generated Makefile)
   - `libstdc++` development headers
   - Verilator runtime libraries (verilated.h, verilated.mk, libverilated.a)

2. **Action Profile Estimates**:
   - `verilator` on hello_world: ~200-300 MB peak, single-threaded
   - `cxx_compile`: ~100-150 MB per translation unit
   - `cxx_link`: ~300-500 MB for link step
   - `simulate`: <50 MB

3. **Input Root Requirements**:
   - `.sv` source files
   - `sim_main.cpp`, `example_vpi.cpp`
   - `BUCK.v2` (if using genrule; otherwise build definition)
   - Standard C++ headers and libraries from toolchain

4. **Output Capture**:
   - Verilator genrule output: directory of generated C++ files
   - Link genrule output: executable simulation binary
   - Simulate execution: stdout (cycle output), exit code (assert pass/fail)
   - Optional: VCD/FST waveform files (large, but captured as action outputs)

## Potential Extensions

After Phase 0 baseline:

- **Multithreaded Verilator**: Use `--threads 2-4` to stress vCPU allocation
- **Larger designs**: Scale up to designs with hundreds of generated C++ files
- **VCD tracing**: Measure output size and impact on performance
- **Design variations**: Multiple counter widths, pipeline depths to test action cache hit rates
