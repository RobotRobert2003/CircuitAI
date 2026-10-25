#!/usr/bin/env bash
# D-363: lint the C++ files a pull request changed, nothing else. Two checks:
#   1. whitespace errors on the changed lines (git diff --check: trailing spaces,
#      space-before-tab, missing final newline);
#   2. cppcheck over each changed file (warning, performance and portability
#      checks; style is left to review), with the repository's include roots.
# Findings are printed as GitHub annotations (::error file=...,line=...) so they
# appear on the changed lines in the pull request, and summarised in the step
# summary. Exit 1 on any finding.
#
#   tools/ci/lint_cpp.sh origin/smrt-test            # files from tools/ci/changed_files.sh
#   tools/ci/lint_cpp.sh origin/smrt-test a.cpp b.h  # these files
set -uo pipefail
base="${1:?base ref}"
shift
root="$(git rev-parse --show-toplevel)"
cd "$root"
if [ $# -gt 0 ]; then
	files=("$@")
else
	mapfile -t files < <(tools/ci/changed_files.sh "$base" cpp)
fi
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }
if [ ${#files[@]} -eq 0 ]; then
	echo "lint_cpp: no C++ files changed"
	summary "| Check | Files | Result |" "|---|---|---|" "| C++ lint | 0 | skipped, nothing changed |"
	exit 0
fi
echo "lint_cpp: ${#files[@]} changed C++ file(s):"
printf '  %s\n' "${files[@]}"
status=0

# 1. whitespace on the changed lines only
if ! git diff --check "$base...HEAD" -- "${files[@]}"; then
	echo "::error title=whitespace::git diff --check found whitespace errors on changed lines (listed above)"
	whitespace="findings"
	status=1
else
	whitespace="clean"
fi

# 2. cppcheck on the changed files
if ! command -v cppcheck > /dev/null; then
	echo "::error title=cppcheck::cppcheck is not installed on this runner"
	exit 1
fi
cppcheck_findings=0
report="$(mktemp)"
cppcheck --std=c++20 --language=c++ --enable=warning,performance,portability --inline-suppr \
	--suppress=missingInclude --suppress=missingIncludeSystem --suppress=unmatchedSuppression \
	--suppress=unknownMacro --quiet -j "$(nproc 2>/dev/null || echo 2)" \
	-I src -I src/circuit -I src/lib \
	--template='::error file={file},line={line},col={column},title=cppcheck {id}::{message}' \
	"${files[@]}" 2> "$report" || true
if [ -s "$report" ]; then
	cat "$report"
	cppcheck_findings="$(grep -c '^::error' "$report" || true)"
	status=1
fi
rm -f "$report"

summary "| Check | Files | Result |" "|---|---|---|" \
	"| whitespace on changed lines | ${#files[@]} | $whitespace |" \
	"| cppcheck (warning, performance, portability) | ${#files[@]} | $cppcheck_findings finding(s) |"
summary "" "Changed C++ files:" "$(printf -- '- `%s`\n' "${files[@]}")"
[ "$status" -eq 0 ] && echo "lint_cpp: clean"
exit "$status"
