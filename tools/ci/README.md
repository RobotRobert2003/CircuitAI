# CI scripts

The scripts behind `.github/workflows/pr-checks.yml` (D-369), runnable locally
against any base:

| Script | What it does |
| --- | --- |
| `changed_files.sh <base> [all\|cpp\|angelscript]` | The files a branch adds, changes or renames against `<base>`, optionally only the lintable C++ (`src/AIExport.*`, `src/circuit/`) or the policy scripts (`data/script/*.as`). |
| `lint_cpp.sh <base> [files...]` | `git diff --check` on the changed lines and `cppcheck` (warning, performance, portability) on the changed C++ files only. Needs `cppcheck`. |
| `lint_angelscript.py <base> [files...]` | Includes resolve, brackets balance, no carriage returns on the changed scripts; then `check_script_api.py` and `check_field_isolation.py` over the whole script graph. |
| `../run_native_tests.sh --host --only cpp\|as` | The C++ tests and the AngelScript suites with the host compiler (the default mode cross-compiles in the Recoil build container and runs on Windows). |

Findings print as GitHub annotations (`::error file=...,line=...`) and each
script appends a table to `$GITHUB_STEP_SUMMARY` when that variable is set.

Not covered here, by design or for lack of an input: an AngelScript compile of
the profile graph (needs the engine's interface dump, KI-662), the checkers that
read `../rjm.bar.docs` (`check_invariants.py`, `check_role_docs.py`,
`check_doc_links.py`, `check_unit_helpers.py`), the Python harness tests under
`tools/`, and any game. The two platform builds stay in `smrtbarb-release.yml`.
