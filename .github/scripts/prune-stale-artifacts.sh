#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="${1:-output}"

if [ ! -d "$OUTPUT_ROOT" ]; then
  echo "prune-stale-artifacts: $OUTPUT_ROOT not present, nothing to do"
  exit 0
fi

shopt -s nullglob

for plat_dir in "$OUTPUT_ROOT"/*/; do
  [ -d "$plat_dir" ] || continue
  echo "prune-stale-artifacts: scanning $plat_dir"

  pushd "$plat_dir" >/dev/null

  # List every .conda file, then for each (package_prefix, version) keep the highest _N.conda
  ls -1 *.conda 2>/dev/null | awk '
    {
      file = $0
      # strip trailing .conda
      core = substr(file, 1, length(file) - 6)
      # split on final _ to get build number
      n = length(core)
      while (n > 0 && substr(core, n, 1) != "_") n--
      if (n <= 1) next
      group = substr(core, 1, n - 1)
      build = substr(core, n + 1) + 0
      if (!(group in maxbuild) || build > maxbuild[group]) {
        maxbuild[group] = build
        keep[group] = file
      }
      members[file] = group
    }
    END {
      for (f in members) {
        g = members[f]
        if (keep[g] != f) print f
      }
    }
  ' | while IFS= read -r stale; do
    [ -n "$stale" ] || continue
    echo "  pruning $stale"
    rm -f -- "$stale"
  done

  popd >/dev/null
done

echo "prune-stale-artifacts: done"
