#!/usr/bin/env bash
# Merges the raw profiles each `swift test --enable-code-coverage` run leaves behind and exports Sources/ coverage as lcov.
# A later run can overwrite an earlier run's profile, so verify.sh calls `save` after every run and `export` once at the end.
# Usage: scripts/coverage-lcov.sh save | export
set -euo pipefail
cd "$(dirname "$0")/.."

out=".build/coverage"
case "${1:-}" in
  save)
    mkdir -p "$out"
    raw_dir="$(swift build --show-bin-path)/codecov"
    # Merge and clear the raw profiles so the next run starts empty and nothing is counted twice.
    find "$raw_dir" -name '*.profraw' -print0 | xargs -0 xcrun llvm-profdata merge -sparse \
      -o "$out/run-$(find "$out" -name 'run-*.profdata' | wc -l | tr -d ' ').profdata" \
      || { echo "coverage-lcov: no profiles under $raw_dir" >&2; exit 1; }
    find "$raw_dir" -name '*.profraw' -delete
    ;;
  export)
    bin_path="$(swift build --show-bin-path)"
    # Each test target links its own copy of the code under test, so every test binary goes in as an object.
    binaries=()
    while IFS= read -r bundle; do
      binaries+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
    done < <(find "$bin_path" -maxdepth 1 -name '*.xctest' | sort)
    [ "${#binaries[@]}" -gt 0 ] || { echo "coverage-lcov: no test binaries under $bin_path" >&2; exit 1; }
    xcrun llvm-profdata merge -sparse "$out"/run-*.profdata -o "$out/merged.profdata"
    xcrun llvm-cov export -format=lcov -instr-profile "$out/merged.profdata" "${binaries[@]}" \
      -ignore-filename-regex='(/\.build/|/Tests/|/checkouts/)' > "$out/lcov.info"
    # Keep only Sources/ records, with repo-relative paths so Codecov maps them to files.
    python3 - "$out/lcov.info" "$PWD" <<'PY'
import sys
path, root = sys.argv[1], sys.argv[2] + "/"
keep, out = False, []
for line in open(path):
    if line.startswith("SF:"):
        file = line[3:].strip()
        keep = file.startswith(root + "Sources/")
        line = "SF:" + file[len(root):] + "\n" if keep else line
    if keep:
        out.append(line)
open(path, "w").write("".join(out))
PY
    [ -s "$out/lcov.info" ] || { echo "coverage-lcov: empty lcov report" >&2; exit 1; }
    echo "coverage-lcov: wrote $out/lcov.info"
    ;;
  *) echo "usage: $0 save|export" >&2; exit 2 ;;
esac
