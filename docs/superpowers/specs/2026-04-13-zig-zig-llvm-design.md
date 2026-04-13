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

1. **No `${{ stdlib('c') }}`** — the sysroot comes from this dependency; removing it means zig's built-in libc headers are used instead.
2. **Always uses `zig_${{ build_platform }}`** (native linux-64 zig) as the compiler. There are no `zig_linux-riscv64` or `zig_linux-s390x` packages, and none are needed — zig cross-compiles by design via `-target`.
3. **Only targets `linux-riscv64` and `linux-s390x`** — enforced via `build: skip` or variant constraints. Always cross-compiled from `linux-64`.
4. **Tests limited to `package_contents`** — no functional tests (llvm-config, shared libs) since cross-compiled binaries can't execute natively on the linux-64 build host.

### Build Scripts

Copied from `recipes/zig-llvm/`:
- `build.sh` (recipe root) — already handles cross-compilation via `ZIG_TRIPLET` and cmake cross flags
- `building/post-install.sh` — same post-install processing
- `building/remove-unneeded.sh` — same cleanup

Not needed (Linux-only targets):
- `build.bat` — Windows entry point, not applicable
- `building/strip_atexit_from_implib.sh` — Windows import lib processing
- `building/debug-macos-dylib.sh` — macOS dylib debugging
- `building/fix-libcxx-needed.sh` — macOS libc++ fix

### Patches

Same patches as `recipes/zig-llvm/patches/`. Only the two common patches apply (no Windows-specific patches needed):
- `0001-pass-through-QEMU_LD_PREFIX-SDKROOT.patch`
- `0002-fix-non-unix-zstd-shared-lib-finding.patch`

### Variants

`conda_build_config.yaml`:
- `c_stdlib_version: 2.17` — declared so the `zig_triplet` jinja template can resolve `c_stdlib_version` (e.g. `riscv64-linux-gnu.2.17`)
- No `c_stdlib` key — omitting this prevents rattler-build from trying to resolve a sysroot package

`variants.yaml`:
- Same `c_stdlib_version` declaration for consistency

### Caching

Same local cache mechanism (`ZIG_LLVM_SKIP_BUILD` + `${RECIPE_DIR}/cache/`).

**Known limitation**: The existing cache validation in `build.sh` runs `llvm-config --version` which requires native execution. For cross-compiled caches (riscv64/s390x binaries on a linux-64 host), this will fail without QEMU. The new recipe may need to modify the cache check to verify file presence only (skip the version invocation).

CI caching uses the same `actions/cache` pattern keyed on `hashFiles('recipes/zig-zig-llvm/**')`.

### Package Contents Tests

Linux-only subset of the existing `package_contents` block:

```yaml
- package_contents:
    files:
      - lib/zig-llvm/bin/llvm-config
      - lib/zig-llvm/bin/llvm-config.real
      - lib/zig-llvm/bin/llvm-dlltool
      - lib/zig-llvm/include/c++/*
      - lib/zig-llvm/include/clang/*
      - lib/zig-llvm/include/clang-c/*.h
      - lib/zig-llvm/include/lld/Common/*{.inc,.h}
      - lib/zig-llvm/include/llvm/*
      - lib/zig-llvm/include/llvm-c/*.h
      - lib/zig-llvm/lib/clang/20/include/*
      - lib/zig-llvm/lib/cmake/{clang,lld,llvm}/*{.cmake,.cpp.in}
      - lib/zig-llvm/lib/liblld*.a
      - lib/zig-llvm/lib/libclang-cpp*.so*
      - lib/zig-llvm/lib/libc++*.so*
      - lib/zig-llvm/lib/libLLVM*.so*
      - lib/zig-llvm-path.txt
```

Removed from zig-llvm's original test block:
- Windows DLL entries (`Library/lib/zig-llvm/bin/*.dll`)
- `${{ library }}` prefix (always empty on Linux)
- `${{ exe }}` suffix (always empty on Linux)
- Post-install test resources conditional (`build_platform == target_platform` — always false)
- All functional test sections (llvm-config, shared libs, libc++ shared, zig integration)

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
