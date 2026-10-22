---
name: convention-angelscript
description: 'Apply AngelScript 2.39.0 WIP-compatible best practices when writing or reviewing scripts. Use for AngelScript APIs, handles, arrays, dictionaries, callbacks, functional-style policy code, memory safety, and performance-sensitive game logic. Targets CircuitAI commit-compatible behavior while distinguishing host APIs from language features.'
metadata:
  compatibility: 'AngelScript 2.39.0 WIP as pinned by CircuitAI at upstream commit 365b8fb; Windows or cross-platform source editing. Host-registered APIs must be verified separately.'
  version: '1.2.0'
  angelscript-baseline: '2.39.0-wip-365b8fb'
---

# AngelScript Conventions

## When to Use

- Writing or reviewing `.as` files.
- Designing script classes, interfaces, funcdefs, callbacks, or modules.
- Working with handles, host reference types, arrays, or dictionaries.
- Refactoring stateful policy code toward a functional core.
- Optimizing allocation-sensitive or frequently invoked script code.
- Checking compatibility with CircuitAI's vendored AngelScript runtime.

## Compatibility Baseline

Target CircuitAI's vendored **AngelScript 2.39.0 WIP**, version integer
`23900`, matching upstream commit `365b8fb` from 2025-10-31.

Do not treat the text `2.39.0 WIP` as a stable release boundary. Upstream WIP
continued changing after CircuitAI's snapshot. Read
[version compatibility](../../../rjm.bar.docs/projects/circuitai/skills/convention-angelscript/references/version-compatibility.md) before using
new or unusual syntax.

For CircuitAI-specific callbacks, native types, and ownership rules, also read
`../rjm.bar.docs/projects/circuitai/angelscript-references.md`.

## Guiding Style

Prefer a **functional core with an imperative shell**:

- Put deterministic decisions in small functions whose result depends only on
  explicit inputs.
- Return decisions or transformed values instead of mutating distant globals.
- Keep native calls, task enqueueing, logging, and state commits near callback
  boundaries.
- Use immutable-by-convention inputs and `const` wherever practical.
- Accept controlled mutation in hot paths when it avoids meaningful allocation,
  copying, garbage collection, or native-call overhead.

AngelScript has function handles and anonymous functions, but anonymous
functions do not capture local variables. Do not design APIs around closures
that the language does not provide.

## Quick Reference

| Concern | Prefer | Avoid |
| --- | --- | --- |
| Optional object | `if (value is null) return;` | Dereference before a guard |
| Handle rebinding | `@dst = @src;` | Ambiguous `dst = src` |
| Identity | `left is right` | `left == right` for identity |
| Read-only large input | `const T& in value` | Unnecessary copies |
| Primitive input | `int value` | `const int& in value` |
| Derived native type | `cast<T>(base)` plus null check | Assuming base exposes derived members |
| Dictionary read | `dict.get(key, value)` | `dict[key]` when absence is possible |
| Array growth | `reserve()` then `insertLast()` | Repeated reallocations |
| Array lookup | Bounds check before indexing | Trusting external indexes |
| State decision | Pure function returning an enum/value | Hidden mutation across helpers |
| Hot loop | Reuse buffers and mutate locally | Allocation-heavy pipelines |
| Enum handling | Qualified value and `default` branch | Magic integers |
| Errors | Guard, log context, return explicit failure | Silent fallback or broad `catch` |
| Host API | Verify registration | Assume a C++ method is script-visible |

## Procedure

1. **Establish the host contract.**
   - Confirm the engine version and exact source pin.
   - Inspect engine properties and registered add-ons.
   - Inspect registration code for every host type or function used.
   - Classify each host object as value, owned reference, borrowed reference, or
     no-handle singleton.

2. **Model data and ownership explicitly.**
   - Use value types for small copied data.
   - Use handles for identity, polymorphism, shared objects, and large
     containers.
   - Use explicit `@` assignment when rebinding a handle.
   - Null-check optional handles and failed casts.
   - Store stable IDs instead of borrowed handles across callbacks.

3. **Separate decisions from effects.**
   - Extract scoring, filtering, thresholds, and state transitions into
     deterministic functions.
   - Pass required state as arguments.
   - Return a decision object, enum, ID, or score.
   - Perform native calls and mutations once at the callback boundary.

4. **Choose clear function contracts.**
   - Pass primitives and small value types by value.
   - Pass larger read-only values as `const T& in`.
   - Use `T& out` only for genuine secondary results and assign every path.
     Object `&out` parameters are default-constructed temporaries copied back
     on return, so they do not reuse caller-owned storage.
   - Use `T& inout` sparingly and make mutation obvious. With CircuitAI's
     unsafe references disabled, `&inout` is limited to object types that
     support handles, such as `array<T>`, not primitives or `AIFloat3`.
   - Do not return references to locals or parameters.

5. **Use idiomatic containers.**
   - Prefer typed classes for fixed schemas and dictionaries for dynamic keys.
   - Use `dictionary.get` for reads that may miss.
   - Do not depend on dictionary iteration order.
   - Reserve array capacity when size is predictable.
   - Do not structurally mutate a container during `foreach`.

6. **Design extensibility deliberately.**
   - Use interfaces for polymorphic contracts.
   - Use funcdefs for strategy callbacks.
   - Mark overrides with `override`.
   - Mark classes or methods `final` when extension is not supported.
   - Null-check optional function handles before invocation.

7. **Make control flow total and defensive.**
   - Use guard clauses to keep the happy path shallow.
   - Include `default` in enum switches because enum variables may hold
     undeclared integers.
   - Check array bounds, divisors, lookup results, and downcasts.
   - Do not assume `assert`, `throw`, or `getExceptionInfo` exists unless the
     host registers it.

8. **Perform a performance pass.**
   - Read the [CircuitAI performance contracts](../../../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md).
     Document complexity, lifetime, invalidation and an equivalence test near
     optimized code; distinguish native calls, CPU time and synchronized orders.
   - Identify callback frequency and collection sizes.
   - Remove repeated native lookups and avoid temporary strings/containers in
     hot loops.
   - Use squared distances when only comparing distances.
   - Reuse scratch arrays where ownership is clear.
   - Keep functional transformations allocation-free in hot paths.
   - Profile before introducing complex caching.

9. **Perform a compatibility pass.**
   - Avoid relying on post-pin WIP fixes.
   - Avoid class/namespace name collisions.
   - Prefer explicit namespace qualification in reusable code.
   - Split complex mixed-width arithmetic into typed intermediate values.
   - Treat warnings as build failures for CircuitAI.

10. **Validate in the actual host.**
    - Run available static diagnostics.
    - Load or compile the affected script through the host application.
    - Exercise null, empty, unknown-enum, and fallback paths.
    - Verify behavior with the interpreter even when a JIT is available.

## Core Rules

### Handles

```angelscript
Unit@ source = FindUnit(id);
if (source is null) {
    return;
}

Unit@ selected;
@selected = @source;

if (selected is source) {
    selected.Act();
}
```

`is` compares identity. `==` invokes value comparison where registered.

`const Unit@ value` prevents mutation through that handle.
`Unit@ const value` prevents rebinding the handle. Keep these meanings distinct.

### Parameters

```angelscript
float Clamp01(float value)
{
    return value < 0.0f ? 0.0f : (value > 1.0f ? 1.0f : value);
}

float Score(const Candidate& in candidate, const Weights& in weights)
{
    return candidate.value * weights.valueWeight
         - candidate.risk * weights.riskWeight;
}
```

Use `const &in` to communicate read-only intent and avoid avoidable copies.
Do not use reference syntax mechanically for primitive inputs.

### Arrays

```angelscript
array<int> CollectPositive(const array<int>& in values)
{
    array<int> result;
    result.reserve(values.length());
    for (uint i = 0; i < values.length(); ++i) {
        if (values[i] > 0) {
            result.insertLast(values[i]);
        }
    }
    return result;
}
```

Returning a fresh array is appropriate for setup, configuration, and small
collections. In hot updates, prefer an output buffer or in-place compaction;
see [performance and safety](../../../rjm.bar.docs/projects/circuitai/skills/convention-angelscript/references/performance-and-safety.md).
When receiving a returned reference container without another copy, bind it to
a handle: `array<int>@ positive = CollectPositive(values);`.

### Dictionaries

Check the boolean result of `dictionary.get`. A missing entry or failed
conversion can overwrite an initialized scalar via its `out` temporary. Set
the fallback **after** failure, or use CircuitAI's `DictIntOr`. D-201's SEA
coverage regression produced millions of nonexistent counter metal when it
ignored this result. See `tests/collection_helpers_tests.as`.

```angelscript
bool TryReadWeight(
    const dictionary& in values,
    const string& in key,
    float& out weight)
{
    if (values.get(key, weight)) return true;
    weight = 0.0f;
    return false;
}
```

Avoid `values[key]` for optional reads because non-const indexing may insert a
missing key.

### Funcdefs and Strategy Functions

```angelscript
funcdef float ScoreCandidate(const Candidate& in candidate);

float ScoreEconomy(const Candidate& in candidate)
{
    return candidate.economy - candidate.risk;
}

const Candidate@ SelectBest(
    const array<Candidate@>& in candidates,
    ScoreCandidate@ score)
{
    const Candidate@ best;
    float bestScore = -3.402823e38f;

    for (uint i = 0; i < candidates.length(); ++i) {
        const Candidate@ candidate = candidates[i];
        if (candidate is null) {
            continue;
        }
        const float value = score(candidate);
        if (best is null || value > bestScore) {
            @best = @candidate;
            bestScore = value;
        }
    }
    return best;
}
```

Use named pure functions as strategies. Do not assume anonymous functions can
capture local context. Constness on an array does not propagate through handle
elements, so bind each element to `const T@` when the function must not mutate
the referenced objects.

### Functional Core, Imperative Shell

```angelscript
enum BuildDecision {
    NONE,
    ENERGY,
    FACTORY
}

BuildDecision DecideBuild(
    float metalIncome,
    float energyIncome,
    bool energyStalling)
{
    if (energyStalling || energyIncome < 200.0f) {
        return BuildDecision::ENERGY;
    }
    if (metalIncome >= 20.0f) {
        return BuildDecision::FACTORY;
    }
    return BuildDecision::NONE;
}

void ApplyBuildDecision(BuildDecision decision)
{
    switch (decision) {
        case BuildDecision::ENERGY:
            QueueEnergy();
            return;
        case BuildDecision::FACTORY:
            QueueFactory();
            return;
        case BuildDecision::NONE:
        default:
            return;
    }
}
```

The pure decision function is easy to reason about. The shell contains the
host-specific effects.

## Review Checklist

For local power queries (D-243), retain the original census publication cadence.
A per-frame spatial index must also invalidate on `ai.GetOwnedUnitRevision()`:
transfers/destruction can occur between asks in the same frame. Index candidates,
not mutable eligibility or final floating totals. Sort candidates into the old
ID order before summation, reread task/retirement flags, and retain pending-task
traversal order. This is O(N) once per used frame plus local candidates per query,
not an O(1) economy. `Sea::VerifyPowerIndex` repeats the old scan for correctness;
disable it when measuring performance. Immutable UnitDef names may be classified
once, but mutable role/attribute policy must not inherit that cache lifetime.

- [ ] Exact engine pin and host registration were checked.
- [ ] Every optional handle and downcast is null-checked.
- [ ] Handle assignment and object assignment are not confused.
- [ ] Borrowed native handles do not escape their valid lifetime.
- [ ] Inputs are `const` unless mutation is intentional.
- [ ] Pure decisions are separated from effects where practical.
- [ ] Array accesses are bounded and growth is reserved where useful.
- [ ] Dictionary reads do not accidentally insert keys.
- [ ] Enum switches handle unexpected values.
- [ ] No unavailable add-on API is assumed.
- [ ] No structural mutation occurs during `foreach`.
- [ ] No destructor is relied on for prompt cleanup.
- [ ] No shared mutable state is accessed from parallel script execution.
- [ ] Hot callbacks avoid unnecessary allocations, copies, and logging.
- [ ] Boolean queries stop the outer search only when predicates have no effects.
- [ ] Cache freshness covers same-frame enqueues, transfers and callback re-entry.
- [ ] Ordered decisions and RNG draws match the original; equal sets are insufficient.
- [ ] New nested timers are compared using equivalent inclusive/exclusive scopes.
- [ ] Code remains correct without JIT optimization.
- [ ] CircuitAI code compiles with warnings treated as errors.

## References

- [Popular idioms and examples](../../../rjm.bar.docs/projects/circuitai/skills/convention-angelscript/references/idioms.md)
- [Performance, memory, and safety](../../../rjm.bar.docs/projects/circuitai/skills/convention-angelscript/references/performance-and-safety.md)
- [Version compatibility and sources](../../../rjm.bar.docs/projects/circuitai/skills/convention-angelscript/references/version-compatibility.md)
