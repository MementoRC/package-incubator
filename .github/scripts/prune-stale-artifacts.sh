#!/usr/bin/env bash
# Usage: prune-stale-artifacts.sh <output_root> [pkg_glob]
#   output_root: typically "output"
#   pkg_glob:    shell glob to limit which packages are pruned (default: '*')
#                The script appends '.conda' to this glob.
#
# For each platform dir under output_root, groups matching .conda files by
# (name-version-hash) and keeps the file with the NEWEST mtime in each group
# (i.e. the one rattler-build just wrote). Older builds of the same package
# (e.g. restored from actions/cache with a stale build_number) are deleted.
#
# Bash 3.2 compatible (no associative arrays) — runs on macOS /bin/bash.
set -euo pipefail

OUTPUT_ROOT="${1:-output}"
PKG_GLOB="${2:-*}"

if [ ! -d "$OUTPUT_ROOT" ]; then
  echo "prune-stale-artifacts: $OUTPUT_ROOT not present, nothing to do"
  exit 0
fi

# Portable mtime: Linux (stat -c %Y) vs macOS/BSD (stat -f %m)
mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

is_numeric() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

shopt -s nullglob
for plat_dir in "$OUTPUT_ROOT"/*/; do
  [ -d "$plat_dir" ] || continue
  echo "prune-stale-artifacts: scanning $plat_dir (glob: $PKG_GLOB)"

  # Build a list of "<mtime>\t<group>\t<basename>" lines, then keep the
  # newest mtime per group (sort by group asc, mtime desc, awk picks first).
  to_delete=$(
    for f in "$plat_dir"${PKG_GLOB}.conda; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      core="${base%.conda}"
      build="${core##*_}"
      is_numeric "$build" || continue
      group="${core%_*}"
      m=$(mtime "$f")
      printf '%s\t%s\t%s\n' "$m" "$group" "$base"
    done | sort -t "$(printf '\t')" -k2,2 -k1,1nr | awk -F'\t' '
      { if ($2 != prev) { prev=$2 } else { print $3 } }
    '
  )

  if [ -n "$to_delete" ]; then
    while IFS= read -r stale; do
      [ -n "$stale" ] || continue
      echo "  pruning $stale"
      rm -f -- "$plat_dir$stale"
    done <<< "$to_delete"
  fi
done

echo "prune-stale-artifacts: done"
