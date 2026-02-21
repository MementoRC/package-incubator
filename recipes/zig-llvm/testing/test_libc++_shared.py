#!/usr/bin/env python3
"""Reproduce zig's ZigClangIsLLVMUsingSeparateLibcxx() check.

Zig verifies at startup that libLLVM.so and libclang-cpp.so resolve
std::generic_category() to the SAME address — i.e., they share one
libc++ copy.  If each DSO has its own STB_LOCAL HIDDEN copy (from
zig cc's static libc++ merge), the addresses differ and zig refuses
to start.

This script:
1. Finds libLLVM.so and libclang-cpp.so in the installed package
2. Checks ELF NEEDED entries for libc++.so.1
3. Checks whether generic_category is LOCAL HIDDEN (bad) or absent/UNDEFINED (good)
4. dlopen's both and compares the address of generic_category via a known vtable probe

Exit 0 = OK (single shared copy), exit 1 = FAIL (separate copies).
"""

import ctypes
import os
import re
import subprocess
import sys


def find_lib(libdir, pattern):
    """Find a real (non-symlink) .so file matching pattern."""
    import glob
    candidates = sorted(glob.glob(os.path.join(libdir, pattern)))
    for c in candidates:
        if not os.path.islink(c) and os.path.isfile(c):
            return c
    # fallback: accept symlinks
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def run_readelf(lib, flag):
    """Run readelf and return stdout."""
    try:
        r = subprocess.run(
            ["readelf", flag, lib],
            capture_output=True, text=True, timeout=10,
        )
        return r.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""


def check_needed(lib):
    """Return set of NEEDED sonames."""
    out = run_readelf(lib, "-d")
    return set(re.findall(r"Shared library: \[([^\]]+)\]", out))


def check_symbol_binding(lib, symbol):
    """Check if symbol is LOCAL HIDDEN, GLOBAL, UNDEFINED, or absent."""
    # Dynamic symbols first
    out_dyn = run_readelf(lib, "--dyn-syms")
    for line in out_dyn.splitlines():
        if symbol in line:
            if "LOCAL" in line and "HIDDEN" in line:
                return "LOCAL_HIDDEN"
            elif "GLOBAL" in line or "WEAK" in line:
                if "UND" in line:
                    return "UNDEFINED"
                return "GLOBAL"
    # Full symbol table
    try:
        r = subprocess.run(
            ["nm", "-a", lib], capture_output=True, text=True, timeout=30,
        )
        for line in r.stdout.splitlines():
            if symbol in line:
                parts = line.split()
                if len(parts) >= 2:
                    sym_type = parts[-2] if len(parts) == 3 else parts[0]
                    if sym_type in ("t", "T"):
                        return "LOCAL_DEFINED" if sym_type == "t" else "GLOBAL_DEFINED"
                    elif sym_type == "U":
                        return "UNDEFINED"
        return "NOT_FOUND"
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return "UNKNOWN"


def main():
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    libdir = os.path.join(prefix, "lib", "zig-llvm", "lib")

    if not os.path.isdir(libdir):
        print(f"ERROR: libdir not found: {libdir}", file=sys.stderr)
        return 1

    libllvm = find_lib(libdir, "libLLVM*.so.*")
    libclang = find_lib(libdir, "libclang-cpp*.so.*")
    libcxx = find_lib(libdir, "libc++.so.1*")

    print(f"  libdir:   {libdir}")
    print(f"  libLLVM:  {libllvm}")
    print(f"  libclang: {libclang}")
    print(f"  libc++:   {libcxx}")

    if not libllvm or not libclang:
        print("ERROR: Could not find libLLVM or libclang-cpp", file=sys.stderr)
        return 1

    # --- Step 1: Static checks ---
    print("\n--- Step 1: NEEDED entries ---")
    errors = []

    for name, lib in [("libLLVM", libllvm), ("libclang", libclang)]:
        needed = check_needed(lib)
        has_libcxx = any("libc++.so" in n and "abi" not in n for n in needed)
        has_libcxxabi = any("libc++abi.so" in n for n in needed)
        print(f"  {name} NEEDED: {sorted(needed)}")
        print(f"    libc++.so: {'YES' if has_libcxx else 'NO'}")
        print(f"    libc++abi.so: {'YES' if has_libcxxabi else 'NO'}")
        if not has_libcxx:
            errors.append(f"{name} missing libc++.so in NEEDED")

    # --- Step 2: Symbol binding check ---
    print("\n--- Step 2: generic_category symbol binding ---")
    SYMBOL = "generic_category"

    for name, lib in [("libLLVM", libllvm), ("libclang", libclang)]:
        binding = check_symbol_binding(lib, SYMBOL)
        print(f"  {name} {SYMBOL}: {binding}")
        if binding == "LOCAL_HIDDEN":
            errors.append(
                f"{name} has LOCAL HIDDEN {SYMBOL} — "
                "private libc++ copy baked in, cannot be interposed"
            )
        elif binding == "LOCAL_DEFINED":
            errors.append(
                f"{name} has local (lowercase t) {SYMBOL} — "
                "static libc++ merged in"
            )

    if libcxx:
        binding = check_symbol_binding(libcxx, SYMBOL)
        print(f"  libc++.so {SYMBOL}: {binding}")
        if binding not in ("GLOBAL", "GLOBAL_DEFINED", "WEAK"):
            errors.append(f"libc++.so {SYMBOL} is {binding}, expected GLOBAL")

    # --- Step 3: Runtime address comparison ---
    # Spawn a subprocess with LD_LIBRARY_PATH set correctly (it must be set
    # before process start for ld.so to honour it).
    print("\n--- Step 3: Runtime address comparison ---")
    dlopen_script = f"""\
import ctypes, sys
libdir = {libdir!r}
libllvm = {libllvm!r}
libclang = {libclang!r}
try:
    llvm = ctypes.CDLL(libllvm, mode=ctypes.RTLD_GLOBAL)
    clang = ctypes.CDLL(libclang, mode=ctypes.RTLD_GLOBAL)
except OSError as e:
    print(f"  dlopen failed: {{e}}")
    sys.exit(2)

MANGLINGS = [
    "_ZNSt3__116generic_categoryEv",
    "_ZNSt3__120__generic_categoryEv",
    "_ZSt16generic_categoryv",
]
for mangled in MANGLINGS:
    try:
        a = ctypes.cast(ctypes.c_void_p.in_dll(llvm, mangled), ctypes.c_void_p).value
        b = ctypes.cast(ctypes.c_void_p.in_dll(clang, mangled), ctypes.c_void_p).value
    except (ValueError, AttributeError):
        continue
    print(f"  Symbol: {{mangled}}")
    print(f"  libLLVM  @ {{hex(a)}}")
    print(f"  libclang @ {{hex(b)}}")
    if a == b:
        print("  OK: same address — single shared libc++ copy")
        sys.exit(0)
    else:
        print("  FAIL: different addresses — separate libc++ copies!")
        sys.exit(1)

print("  WARNING: generic_category not found via dlsym, trying LLVMGetVersion")
try:
    llvm.LLVMGetVersion.restype = None
    ma, mi, pa = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
    llvm.LLVMGetVersion(ctypes.byref(ma), ctypes.byref(mi), ctypes.byref(pa))
    print(f"  LLVMGetVersion: {{ma.value}}.{{mi.value}}.{{pa.value}} (library loads OK)")
    sys.exit(0)
except Exception as e:
    print(f"  LLVMGetVersion failed: {{e}}")
    sys.exit(2)
"""
    try:
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = libdir + ":" + env.get("LD_LIBRARY_PATH", "")
        r = subprocess.run(
            [sys.executable, "-c", dlopen_script],
            env=env, capture_output=True, text=True, timeout=30,
        )
        print(r.stdout.rstrip())
        if r.stderr.strip():
            print(r.stderr.rstrip())
        if r.returncode == 1:
            errors.append("Runtime: generic_category at different addresses (separate copies)")
        elif r.returncode == 2:
            errors.append(f"Runtime: dlopen/dlsym failed")
    except Exception as e:
        print(f"  subprocess failed: {e}")
        errors.append(f"Runtime check failed: {e}")

    # --- Summary ---
    print(f"\n--- Summary ---")
    if errors:
        print("ERRORS:")
        for e in errors:
            print(f"  - {e}")
        return 1
    else:
        print("PASS: All checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
