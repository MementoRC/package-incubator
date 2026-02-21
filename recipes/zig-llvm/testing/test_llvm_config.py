#!/usr/bin/env python3
"""Verify llvm-config works and returns valid paths."""

import os
import subprocess
import sys


def run_llvm_config(*args):
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    llvm_config = os.path.join(prefix, "lib", "zig-llvm", "bin", "llvm-config")
    r = subprocess.run(
        [llvm_config, *args],
        capture_output=True, text=True, timeout=10,
    )
    if r.returncode != 0:
        print(f"  llvm-config {' '.join(args)} FAILED (rc={r.returncode})", file=sys.stderr)
        print(f"  stderr: {r.stderr.strip()}", file=sys.stderr)
        return None
    return r.stdout.strip()


def main():
    errors = []

    # Check llvm-config binary exists
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    llvm_config = os.path.join(prefix, "lib", "zig-llvm", "bin", "llvm-config")
    if not os.path.isfile(llvm_config):
        print(f"ERROR: llvm-config not found at {llvm_config}", file=sys.stderr)
        return 1

    # --version
    version = run_llvm_config("--version")
    print(f"  version:    {version}")
    if version is None:
        errors.append("llvm-config --version failed")

    # --prefix
    pfx = run_llvm_config("--prefix")
    print(f"  prefix:     {pfx}")
    if pfx is None:
        errors.append("llvm-config --prefix failed")

    # --libdir
    libdir = run_llvm_config("--libdir")
    print(f"  libdir:     {libdir}")
    if libdir is None:
        errors.append("llvm-config --libdir failed")
    elif not os.path.isdir(libdir):
        errors.append(f"libdir does not exist: {libdir}")

    # --includedir
    incdir = run_llvm_config("--includedir")
    print(f"  includedir: {incdir}")
    if incdir is None:
        errors.append("llvm-config --includedir failed")
    elif not os.path.isdir(incdir):
        errors.append(f"includedir does not exist: {incdir}")

    # --components (just check it returns something)
    components = run_llvm_config("--components")
    if components:
        comp_list = components.split()
        print(f"  components: {len(comp_list)} ({', '.join(comp_list[:10])}...)")
    else:
        errors.append("llvm-config --components returned nothing")

    if errors:
        print("\nERRORS:")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("PASS: llvm-config works correctly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
