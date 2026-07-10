#!/usr/bin/env bash
# Strip foreign -target X / --target=X args (defensive: cmake/build aliases may inject
# clang-style -target which the underlying zig subcommand doesn't accept).
_filtered_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -target)
            shift
            [[ $# -gt 0 ]] && shift
            ;;
        --target=*)
            shift
            ;;
        *)
            _filtered_args+=("$1")
            shift
            ;;
    esac
done
exec "@ZIG_BIN@" ranlib "${_filtered_args[@]}"
