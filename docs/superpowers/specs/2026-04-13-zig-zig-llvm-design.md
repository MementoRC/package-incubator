# zig-zig-llvm: Cross-compile LLVM using zig's built-in sysroot

**Date**: 2026-04-13
**Status**: PoC
**Branch**: zig18-simplify

## Problem

The `zig-llvm` recipe cross-compiles LLVM using zig-cc but relies on `${{ stdlib('c') }}` for the target platform's sysroot. conda-forge has no sysroot packages for riscv64 or s390x, so cross-builds for these targets cannot work with the current recipe.

Zig ships with built-in libc headers and can cross-compile to these targets without an external sysroot.

## Solution

Create `recipes/zig-zig-llvm/` — a trimmed copy of `recipes/zig-llvm/` that drops the sysroot dependency and uses the native zig compiler's built-in cross-compilation to produce `zig-llvm` packages for sysroot-less targets.

## Scope

**In scope**:
- New recipe directory `recipes/zig-zig-llvm/`
- Targets: `linux-riscv64`, `linux-s390x` (cross-compiled from `linux-64`)
- Output: same `zig-llvm` package name (transparent to downstream consumers)

**Out of scope**:
- CI workflow changes (build.yml matrix updates)
- zig-zig cross-build wiring for riscv64/s390x
- Replacing zig-llvm for targets that have sysroots (linux-64, linux-aarch64, etc.)

## Design

### Recipe: `recipes/zig-zig-llvm/recipe.yaml`

Key differences from `recipes/zig-llvm/recipe.yaml`:

1. **No `${{ stdlib('c') }}`** — zig provides the sysroot via its built-in libc headers
2. **Always uses `zig_${{ build_platform }}`** (native linux-64 zig) as the compiler, regardless of target. No `zig_${{ target_platform }}` dependency (which would pull in a target sysroot).
3. **Only targets `linux-riscv64` and `linux-s390x`** — enforced via `build: skip` or variant constraints. Always cross-compiled from `linux-64`.
4. **Tests limited to `package_contents`** — no functional tests (llvm-config, shared libs) since there's no native execution environment without QEMU.

### Build Scripts

Reused from `recipes/zig-llvm/building/`:
- `build.sh` — already handles cross-compilation via `ZIG_TRIPLET` and cmake cross flags
- `post-install.sh` — same post-install processing
- `remove-unneeded.sh` — same cleanup
- `strip_atexit_from_implib.sh` — not needed (Linux only), but harmless to include

Scripts can be symlinked or copied. For PoC clarity, copying is preferred.

### Patches

Same patches as `recipes/zig-llvm/patches/`. Only the two common patches apply (no Windows-specific patches needed):
- `0001-pass-through-QEMU_LD_PREFIX-SDKROOT.patch`
- `0002-fix-non-unix-zstd-shared-lib-finding.patch`

### Variants

`conda_build_config.yaml` / `variants.yaml`:
- `c_stdlib_version: 2.17` (glibc target version, used in zig triplet)
- No `c_stdlib` key (no sysroot)

### Caching

Same local cache mechanism (`ZIG_LLVM_SKIP_BUILD` + `${RECIPE_DIR}/cache/`). CI caching uses the same `actions/cache` pattern keyed on `hashFiles('recipes/zig-zig-llvm/**')`.

### Dependency Chain

The full build chain for riscv64/s390x:

```
1. zig-llvm (native linux-64)      — LLVM for the build host        [existing]
2. zig-zig (native linux-64)       — zig compiler on build host      [existing]
3. zig-zig-llvm (cross riscv64)    — LLVM for target, built by zig   [NEW]
4. zig-zig (cross riscv64)         — zig for target                  [future]
```

Step 3 requires the native `zig_linux-64` package from step 2 to be available (either from a prior CI run or published to the channel).

## Success Criteria

- `rattler-build build --recipe recipes/zig-zig-llvm --target-platform linux-riscv64` completes on a linux-64 host
- Output `.conda` package contains the expected `lib/zig-llvm/` structure with riscv64 ELF binaries
- `package_contents` test passes
- Same for linux-s390x
