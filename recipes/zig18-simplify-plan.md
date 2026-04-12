# Zig Build 18 Simplification Plan

**Branch:** `zig18-simplify` (from `zig-llvm`)
**Goal:** Remove/simplify workarounds in zig-llvm and zig-zig that zig build 18's capabilities make unnecessary.
**Constraint:** zig-llvm stays — it provides GCC/clang-independent LLVM (critical for riscv64 and other platforms without GCC).

## Context

Zig build 18 (0.15.2) introduces:
- **Internal LLD** for ELF, COFF, Wasm, AND Mach-O (via `-fuse-ld=lld`)
- **`_zig-cc-common.sh`** auto-promotes to LLD when GNU ld flags are detected
- **`libcxx_shared.zig`** probe finds shared libc++ at `lib/zig-llvm/lib/`
- **Native ld script parsing** (relative paths, `-l` flags)
- **`zig-force-load-cc/cxx`** wrappers handle `-all_load`/`-force_load` natively

Reference implementation: `~/PycharmProjects/Conda-Feedstocks/zig-feedstock-2/`

---

## Phase 1: zig-llvm Link Pipeline (highest impact, ~1000 lines)

Replace 3 platform-specific link overrides with zig 18's `-fuse-ld=lld`.

### 1.1 Remove `zig-cxx-shared` wrapper (Linux)
- **File:** `recipes/zig-llvm/building/build.sh` (CMAKE_CXX_CREATE_SHARED_LIBRARY override)
- **What:** Custom wrapper that calls `ld.lld` directly, bypassing zig
- **Replace with:** `zig cc -fuse-ld=lld -shared` (zig routes to internal LLD)
- **Verify:** soname entries correct (no more patchelf NEEDED fixups)
- **Risk:** Medium — must confirm zig 18 doesn't inject static libc++ when `-fuse-ld=lld` is used AND shared libc++ is at probe path

### 1.2 Remove `macos-link-wrapper.sh` (macOS)
- **File:** `recipes/zig-llvm/building/macos-link-wrapper.sh`
- **What:** Delegates linking to `/usr/bin/clang`, filters libc++.a args
- **Replace with:** `zig cc -fuse-ld=lld` (zig 18 has Mach-O LLD)
- **Verify:** No static libc++ merge, symbols not dead-stripped
- **Risk:** High — Mach-O LLD is new in zig 18, test thoroughly
- **Also removes:** libc++.a relocation to `/tmp/`, `LIBRARY_PATH` unsetting

### 1.3 Simplify Windows link template
- **File:** `recipes/zig-llvm/building/build.sh` (Windows CMAKE_CXX_CREATE_SHARED_LIBRARY)
- **What:** Custom `zig cc -shared -target ... --export-all-symbols` template
- **Replace with:** `-fuse-ld=lld` with `--export-all-symbols`
- **Verify:** Check if `--exclude-symbols atexit` works with zig 18's LLD COFF
- **Risk:** Medium — if `--exclude-symbols` not supported, `strip_atexit_from_implib.sh` still needed

### 1.4 Remove `_cmake_project_include.cmake`
- **What:** Injects CMAKE_CXX_CREATE_SHARED_LIBRARY override via CMAKE_PROJECT_INCLUDE
- **Replace with:** Standard cmake link rules (zig 18 as compiler + `-fuse-ld=lld`)
- **Depends on:** 1.1, 1.2, 1.3 all passing

---

## Phase 2: zig-llvm Post-Build Fixups (~300 lines)

### 2.1 Remove patchelf NEEDED path normalization (Linux)
- **File:** `recipes/zig-llvm/building/post-install.sh`
- **What:** `patchelf --replace-needed` to fix build-tree paths in NEEDED entries
- **Why removable:** LLD produces correct sonames natively
- **Depends on:** Phase 1.1 (LLD link produces correct NEEDED)

### 2.2 Remove patchelf `add-needed libc++.so.1` (Linux)
- **File:** `recipes/zig-llvm/building/post-install.sh`
- **What:** Forces libc++ NEEDED entry on libLLVM/libclang-cpp
- **Why removable:** LLD correctly records NEEDED entries
- **Depends on:** Phase 1.1

### 2.3 Remove MinGW import lib pre-generation (Windows)
- **File:** `recipes/zig-llvm/building/build.sh` (`.def` → `dlltool` pipeline)
- **What:** Pre-generates ~400 import libs from zig's MinGW `.def` files
- **Why removable:** `-fuse-ld=lld` doesn't bypass zig's auto-import resolution
- **Depends on:** Phase 1.3

### 2.4 Simplify `llvm-config` wrapper
- **File:** `recipes/zig-llvm/building/remove-unneeded.sh`
- **What:** Bash wrapper filtering `-Bsymbolic-functions` etc.
- **Why simplifiable:** Zig 18's wrappers filter these flags. But llvm-config is also called by zig's build.zig — check if zig 18's build system handles unknown flags.
- **Risk:** Low if zig's build system passes flags through `-fuse-ld=lld`

---

## Phase 3: zig-llvm Linker Workarounds (~200 lines)

### 3.1 Evaluate `zig-force-load-cxx` removal (macOS)
- **What:** Wrapper handling `-Wl,-all_load` via `ar x` + individual .o passing
- **Why maybe removable:** Zig 18 ships its own force-load wrappers
- **Verify:** Does zig 18's Mach-O LLD support `-all_load` natively now?
- **Risk:** High — if LLD still silently drops `-all_load`, keep it

### 3.2 Evaluate `LLVM_NO_DEAD_STRIP=ON` removal (macOS)
- **What:** Prevents dead-stripping LLVMInitialize* symbols
- **Verify:** With Mach-O LLD, are these symbols preserved without the flag?
- **Risk:** Medium — symbols used by external consumers, not internal refs

### 3.3 Evaluate macOS deployment target patching removal
- **What:** `sed` patches zig wrapper target triples for MACOSX_DEPLOYMENT_TARGET
- **Verify:** Does zig 18 respect the env var or `-mmacosx-version-min=` properly?

---

## Phase 4: zig-zig Simplifications

### 4.1 Remove `-print-file-name` CXX wrapper
- **File:** `recipes/zig-zig/build.sh` (ZIG_CXX_COMPILER wrapper)
- **What:** Intercepts `-print-file-name=libc++.so` for zig-llvm path
- **Why removable:** `libcxx_shared.zig` probe is the primary mechanism in build 18

### 4.2 Remove `.dll.a` → `.a` shim copies (Windows)
- **File:** `recipes/zig-zig/build.sh`
- **What:** Copies `*.dll.a` → `*.a` for zig's gnu-target linker
- **Verify:** Zig 18's LLD COFF handles `.dll.a` directly

### 4.3 Remove `_libc_tuning.sh` ld script workarounds
- **File:** `recipes/zig-zig/build_scripts/_libc_tuning.sh`
- **What:** Replaces ld linker scripts with symlinks (libc.so, libm.so, etc.)
- **Why removable:** Zig 18 has native ld script parsing
- **Keep:** `create_gcc14_glibc28_compat_lib()` — still needed for old glibc

### 4.4 Remove `allow-so-scripts` patch
- **File:** `recipes/zig-zig/patches/linux/link.zig-02-default-allow-so-scripts.patch`
- **Why removable:** Default changed in zig 18

### 4.5 Remove `image-base` patch
- **File:** `recipes/zig-zig/patches/linux/build.zig-05-image-base.patch`
- **Why removable:** LLD handles image base correctly in zig 18

### 4.6 Evaluate LLVM target stub patches (3 patches)
- **Files:** `relax-llvm-required-targets.patch`, `disable-unsupported-llvm-targets.patch`, `comment-unsupported-llvm-target-bindings.patch`
- **Decision:** These depend on how many targets zig-llvm builds, NOT on zig version. If zig-llvm adds all 19 targets → remove. If keeping 8 targets → keep.

---

## Phase 5: Smoke Test Cleanup

### 5.1 Audit pre-build smoke tests
- **File:** `recipes/zig-llvm/building/build.sh`
- **What:** Linker compat, stub lib, export-all-symbols tests
- **Action:** Remove tests for behaviors fixed in zig 18, keep safety rails for remaining risks

---

## Verification Strategy

Each phase must:
1. Build successfully on at least one platform (Linux-64 first, easiest)
2. Pass `generic_category` symbol binding check (Linux) / `debug_libcxx_isolation.py` (macOS)
3. Pass `zig version` / `zig cc hello.c` / `zig test behavior.zig` in resulting zig-zig
4. Confirm no `@rpath` leaks (macOS) or missing NEEDED entries (Linux)

## Order of Operations

```
Phase 1.1 (Linux link) → Phase 2.1 + 2.2 (Linux post-build) → Linux CI
Phase 1.2 (macOS link) → Phase 3.1 + 3.2 + 3.3 (macOS linker) → macOS CI
Phase 1.3 (Windows link) → Phase 2.3 (Windows import libs) → Windows CI
Phase 4.* (zig-zig) → after zig-llvm phases validated
Phase 5 (smoke tests) → last, after all changes stable
```
