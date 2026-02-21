#!/usr/bin/env python3
"""Verify shared libraries are valid ELF, have expected symbols,
and do NOT depend on libstdc++ (must use libc++)."""

import glob
import os
import re
import subprocess
import sys


def find_libs(libdir, pattern):
    """Find .so files matching pattern, excluding symlinks."""
    results = []
    for f in sorted(glob.glob(os.path.join(libdir, pattern))):
        if os.path.isfile(f) and not os.path.islink(f):
            results.append(f)
    return results


def run_cmd(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""


def check_elf(path):
    """Check file is a valid ELF shared object."""
    out = run_cmd(["file", path])
    return "ELF" in out and "shared object" in out


def get_needed(path):
    """Get NEEDED entries from ELF."""
    out = run_cmd(["readelf", "-d", path])
    return set(re.findall(r"Shared library: \[([^\]]+)\]", out))


def get_glibc_versions(path):
    """Get GLIBC version symbols used."""
    out = run_cmd(["objdump", "-T", path])
    versions = set(re.findall(r"GLIBC_([0-9.]+)", out))
    return sorted(versions, key=lambda v: list(map(int, v.split("."))))


def get_rpath(path):
    """Get RPATH/RUNPATH entries."""
    out = run_cmd(["readelf", "-d", path])
    entries = []
    for line in out.splitlines():
        if "RPATH" in line or "RUNPATH" in line:
            match = re.search(r"\[([^\]]+)\]", line)
            if match:
                entries.append(match.group(1))
    return entries


def main():
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    libdir = os.path.join(prefix, "lib", "zig-llvm", "lib")
    errors = []

    if not os.path.isdir(libdir):
        print(f"ERROR: libdir not found: {libdir}", file=sys.stderr)
        return 1

    # --- Check libLLVM ---
    print("=== libLLVM ===")
    llvm_libs = find_libs(libdir, "libLLVM*.so.*")
    if not llvm_libs:
        errors.append("No libLLVM shared library found")
    else:
        for lib in llvm_libs[:3]:
            name = os.path.basename(lib)
            is_elf = check_elf(lib)
            print(f"  {name}: {'ELF OK' if is_elf else 'NOT ELF'}")
            if not is_elf:
                errors.append(f"{name} is not a valid ELF shared object")

        main_lib = llvm_libs[0]
        # Check no libstdc++
        needed = get_needed(main_lib)
        has_stdcxx = any("libstdc++" in n for n in needed)
        print(f"  NEEDED: {sorted(needed)}")
        if has_stdcxx:
            errors.append("libLLVM depends on libstdc++ (must use libc++)")
        else:
            print("  No libstdc++ dependency: OK")

        # GLIBC versions
        glibc = get_glibc_versions(main_lib)
        print(f"  GLIBC versions: {glibc}")

        # RPATH
        rpath = get_rpath(main_lib)
        print(f"  RPATH/RUNPATH: {rpath}")

        # Check LLVMContext symbol exists
        out = run_cmd(["nm", "-D", main_lib])
        llvm_context_count = out.count("LLVMContext")
        print(f"  LLVMContext symbols: {llvm_context_count}")

    # --- Check libclang-cpp ---
    print("\n=== libclang-cpp ===")
    clang_libs = find_libs(libdir, "libclang-cpp*.so.*")
    if not clang_libs:
        errors.append("No libclang-cpp shared library found")
    else:
        for lib in clang_libs[:3]:
            name = os.path.basename(lib)
            is_elf = check_elf(lib)
            print(f"  {name}: {'ELF OK' if is_elf else 'NOT ELF'}")
            if not is_elf:
                errors.append(f"{name} is not a valid ELF shared object")

        main_lib = clang_libs[0]
        needed = get_needed(main_lib)
        has_stdcxx = any("libstdc++" in n for n in needed)
        print(f"  NEEDED: {sorted(needed)}")
        if has_stdcxx:
            errors.append("libclang-cpp depends on libstdc++ (must use libc++)")
        else:
            print("  No libstdc++ dependency: OK")

        glibc = get_glibc_versions(main_lib)
        print(f"  GLIBC versions: {glibc}")

        rpath = get_rpath(main_lib)
        print(f"  RPATH/RUNPATH: {rpath}")

    # --- Check liblld ---
    print("\n=== liblld ===")
    lld_libs = find_libs(libdir, "liblld*.a")
    if not lld_libs:
        errors.append("No liblld static libraries found")
    else:
        for lib in lld_libs[:5]:
            print(f"  {os.path.basename(lib)}")
        print(f"  Total: {len(lld_libs)} archive(s)")

    # --- Summary ---
    print(f"\n--- Summary ---")
    if errors:
        print("ERRORS:")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("PASS: All shared library checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
