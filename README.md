# CircuitAI / SMRTBARb

C++ Skirmish AI for Recoil, with AngelScript policy and BAR behavior profiles.

| Directory | Developer purpose |
| --- | --- |
| `src/` | Native AI mechanisms, bindings and vendored dependencies |
| `data/` | Active AngelScript policy, profiles and deployed AI metadata |
| `data_sample/` | Upstream reference examples; not the active implementation |
| `tests/` | Native and script test source, including benchmark programs |
| `tools/` | Build, validation, simulation and evidence-publication tooling |
| `platform/`, `packaging/`, `util/` | Platform support, release packaging and development utilities |
| `skills/`, `AGENTS.md` | Reusable runbooks and repository working conventions |

Build definitions, CI, hooks, licenses and small navigation files stay with the
source. Generated evidence does not: keep this checkout focused on code and the
tools needed to build, test and maintain it.

- **Documentation:** [rjm.bar.docs/projects/circuitai](../rjm.bar.docs/projects/circuitai/README.md)
  owns implementation plans, reviews, decisions, changelogs and the test index.
- **Results and artifacts:** [CircuitAI.benchmarks](https://github.com/S3KCentrifugal/CircuitAI.benchmarks)
  owns published benchmarks, raw games and build-validation logs, pinned
  binaries, symbols and snapshots. Large raw artifacts are Git-ignored and
  require separate backup.

Clone the benchmark repository beside this checkout, or set
`CIRCUIT_BENCHMARK_REPO`. Resolve output locations without creating local copies:

```sh
python tools/playtest/benchmark_store.py validation
python tools/playtest/benchmark_store.py raw
```

Use a named session/build directory under the returned validation root. Keep
test definitions and reusable runners here; send their retained output there.
Disposable unit-test scratch may use the OS temporary directory. Build output
required for engine integration remains in its configured external build tree.

See [storage ownership and migration](../rjm.bar.docs/projects/circuitai/benchmark-repository.md)
and [AGENTS.md](AGENTS.md) for the build/validation workflow. The small `doc/`
navigation files and existing local `build-theatres` compatibility junction
support older links; they are not new output locations.
