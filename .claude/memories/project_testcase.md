---
name: Verilator Example Test Case
description: Real Buck2 + Verilator project used to validate Phase 0 implementation
type: project
---

**Test Case**: https://github.com/yangm2/verilator-example

This is a production-quality test case for the Apple Containers + REAPI Phase 0 PoC.

**Current Status (unsandboxed local builds)**:
- Build succeeds: `buck2 build //src:Vhello_world` completes in ~8-10 seconds
- Simulation runs: `buck2 run //src:sim100` executes in ~7ms with correct output
- No external cache, direct local execution on macOS

**Why It's Perfect for Phase 0**:
- Exercises all three Verilator pipeline phases: verilate → compile → simulate
- Small enough to run on 8 GB MBP (peak ~500 MB unsandboxed)
- Requires real toolchain: `verilator` + `clang++` + `make`
- Produces measurable outputs: executable + waveforms
- Has assertions that must pass (fail-fast on errors)

**Phase 0 Validation**: Build and simulation must run identically inside Apple Container ephemeral VMs. Success criteria: hermetic build under 7 GB peak memory with <2x wall time overhead vs. unsandboxed.

**How to clone** (with Buck2 prelude submodule):
```bash
git clone --recurse-submodules https://github.com/yangm2/verilator-example.git
cd verilator-example
buck2 build //src:Vhello_world
buck2 run //src:sim100  # Should output cycle-accurate simulation results
```
