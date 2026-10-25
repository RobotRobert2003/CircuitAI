#!/usr/bin/env bash
# D-363: the files a pull request adds, changes or renames, one path per line,
# against a base ref (`origin/smrt-test` on the CI runner). Deleted files are
# left out: a linter has nothing to read there.
#
#   tools/ci/changed_files.sh origin/smrt-test            # every changed file
#   tools/ci/changed_files.sh origin/smrt-test cpp        # src/AIExport.* and src/circuit/ C++ only
#   tools/ci/changed_files.sh origin/smrt-test angelscript  # data/script/ .as only
set -euo pipefail
base="${1:?base ref}"
kind="${2:-all}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
all="$(git diff --name-only --diff-filter=ACMR "$base...HEAD")"
case "$kind" in
	all) printf '%s\n' "$all" | sed '/^$/d' ;;
	# The vendored libraries (src/lib), the JIT platform support and util/ are
	# not linted (AGENTS.md: apply the rules to src/AIExport.* and src/circuit/).
	cpp) printf '%s\n' "$all" | grep -E '^(src/AIExport\.(cpp|h)|src/circuit/.*\.(cpp|h|hpp))$' || true ;;
	angelscript) printf '%s\n' "$all" | grep -E '^data/script/.*\.as$' || true ;;
	*) echo "changed_files: kind is all, cpp or angelscript" >&2; exit 2 ;;
esac
