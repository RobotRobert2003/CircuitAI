---
name: write-pull-request
description: 'Write the title and description of a CircuitAI pull request so a maintainer can read it in two minutes and merge with confidence. Use whenever the user asks to open, update or describe a pull request. Produces a short lead, one table per area with a verification column, one short code sample per feature cut from the source at the head, a performance table when runtime code changed, a docs line and an honest limits line; sourced from the branch, the decision record, playtest results and CI, never from memory.'
compatibility: 'Needs the branch checked out, the gh CLI authenticated against the fork, and read access to ../rjm.bar.docs/projects/circuitai for decisions, invariants and known issues.'
metadata:
  version: '1.1.0'
---

# Write a pull request

A pull request description is read by the owner on GitHub, on a phone as often
as on a desktop, usually without the branch checked out. It has one job: let
that reader see what changes in the game, how each change was proven, and what
is still open, without scrolling through commits or files. Everything else
(the reasoning, the rejected alternatives, the evidence) already has a home in
`../rjm.bar.docs/projects/circuitai/` and is linked, not repeated.

The model for this skill is
[the behaviour fix batch, PR #9](references/example-batch-pr.md), which the owner
accepted as "detailed, beautified and user friendly" while "concise and non
verbose". Read that example once before writing a batch PR.
[The commander lane batch, PR #26](references/example-samples-pr.md) adds the
form the owner asked for on 2026-10-24 and called "good looking": under each
table a short code sample per row, cut from the source at the head, showing
how the mechanism works and which lever controls it. Use that form by default
for any batch that changes native or script rules, and whenever the user asks
for code samples. Two earlier descriptions show what to avoid: PR #2 buried
every number in prose and ran to five screens, and PRs #5 to #8 had no body at
all.

## When to use

- The user asks to create, open, update or write a pull request.
- The user asks to "commit and push and make a PR" at the end of a task.
- A PR already exists and its scope changed (new commits, dropped items,
  corrected claims). The body always describes the final head, so edit it.

Do not write a PR description from the conversation summary alone. Gather the
facts below first; a description that claims more than the branch proves is
worse than none.

## Gather before writing

Run these on the branch and keep the outputs beside you. Everything in the body
must trace to one of them.

1. **Scope.** `git log --oneline <base>..HEAD` and `git diff --stat <base>..HEAD`.
   Note which trees changed: `src/circuit/` (native), `data/script/` and
   `data/config/` (policy), `tools/playtest/` (harness), docs. A PR with no
   `src/` or `data/` changes needs no performance section and no play claims.
2. **Decisions.** The `D-nnn` entries this branch added to
   `../rjm.bar.docs/projects/circuitai/decisions.md`. Each one names its
   verification state in the record's vocabulary: Built, Checked, Symbolised,
   Played. Use that word, never a stronger one.
3. **Invariants and known issues.** The `INV-nnn` rows added and the `KI-nnn`
   entries opened or closed. Ranges go in the docs line; anything left broken
   goes in the limits line.
4. **Play evidence.** The watch verdicts and the one number that proves each
   fix (units built, shots not fired, minutes saved, kills). Take them from the
   archived playtest reports in the benchmark checkout, not from recollection.
5. **Performance.** If runtime code changed, the before/after table from the
   full-match comparison, with the method named (map, team size, AI count,
   number of shared windows). If no comparison was run, say so in the limits
   line rather than omitting the section.
6. **CI and publish.** Whether the build workflow passed on the head, and
   whether the build was published to the required install output with
   script/DLL parity at zero.
7. **Docs location.** If the documentation lives in another checkout or branch
   (it currently does: `rjm.bar.docs`, branch `circuitai-docs-reconstructed`),
   name it, because the reviewer cannot see it in the diff.
8. **Source lines.** For every table row, the function or rule that
   implements it, found with grep at the head and read there: the pure rule
   in a header (with its unit test) when one exists, else the call site, else
   the script that sets the option. Note the file and the lever names it
   reads. Every sample in the body is cut from these lines, never retyped
   from memory or from the conversation summary.

## Title

One line, under about 110 characters, naming the areas touched in the reader's
words. For a batch: `<kind> batch: <area>: <items>, <area>: <items>`. For one
fix: `<Role or unit>: <what changes in the game>`.

```text
Behaviour fix batch: TECH heavies/gantries/turrets/reclaim, AIR escorts/fusions, Legion build power, Fatboy/Starlight/scouts
Fatboy: skip identified Ticks and over-fast radar dots, keep blind fire
```

Game names (Fatboy, Tick, Starlight), not UnitDef ids (`armfboy`). No ticket
numbers in the title; they belong in the docs line.

## Body

Write the body to a file in the scratchpad and pass it with `--body-file`;
never type a long body inline. The shape, top to bottom:

### 1. Lead (two or three sentences)

What the PR is, how many items, the pattern they share, which profile, and the
overall verification state. The reader should be able to stop here.

> Ten owner-reported unit-behaviour issues, fixed as AngelScript policy with
> small native levers, each with an invariant, a playtest case and a decision
> record. All ten are verified in play on the published build. Primary profile
> `experimental_balanced`; legacy profiles untouched.

If any item is not Played, the lead says so: "eight of ten are verified in
play; the two reclaim items are Built and Checked only."

### 2. One table per area

Group by role or subsystem (`### 🏭 TECH`, `### ✈️ AIR`, `### ⚔️ Land units`,
`### 🧪 Harness`). One emoji per heading is the whole decoration budget; none
inside cells. Three columns, header row left blank for the first:

```markdown
| | Fix | Status |
|---|---|---|
| **No late-game Marauders** | After a one-way "late" latch (20 min or 400 M/s), gantries build the terrain's heavy: Thor / Karganeth / Railtank on land, Titan-class on maps with assault beaches. | ✅ Played: 10 Titans, 0 Marauders (Supreme); 8 Thors (Glitters) |
```

- **First column**: the fix as the owner would say it, bold, three to five
  words, outcome not mechanism ("Fatboys ignore Ticks", not "avoid_categories").
- **Fix column**: one or two sentences. What the AI now does, then the lever
  that controls it (a settings name, a JSON key, a rule row) so the reader
  knows it is tunable. Correct a misreading the owner raised in review
  explicitly ("Radar dots stay valid blind-fire targets; only identified Ticks
  and dots moving too fast to hit are skipped").
- **Status column**: the verification word, then the single number that proves
  it, with the baseline when one exists ("0 Tick shots (baseline fired at
  52 s)"). `✅ Played`, `🟡 Built, Checked` or `⚠️ Not played` are the only
  three forms. An item not played is not hidden in the Harness section.
- **Every lever named is explained.** Writing a key in backticks is not a
  description. Each lever a Fix cell names gets a clause saying what it does
  in the game and what it does not do when a reader would assume more ("a
  shot-score multiplier; it never moves the unit toward the target"). PR #26
  first shipped "`press_static` with `commander_priority`" and the owner had
  to ask what the second one did.
- **One mechanism per row.** When a row carries two mechanisms with different
  verification (a press that was played and a target preference that was
  not), split it into two rows so each Status is true. A Status that covers
  only the first mechanism in the cell is a false claim about the second.

Harness changes are a bullet list, not a table: what the runner does now and
why it had to change, one line each. Count new cases/checks/widgets once.

### 3. One sample per feature

Under each area's table, one block per table row, in row order. Each block is
a bold name of three to five words (the row's first column or its mechanism),
one sentence saying what the sample shows and where it lives, then a fenced
code block. The example is
[the commander lane batch, PR #26](references/example-samples-pr.md).

````markdown
**Home latch.** Once latched the lane has no front for this commander; the base rungs keep it busy.

```cpp
bool CCommanderControl::PushHome(CCircuitUnit* unit, State& s, int frame) {
    if (s.pushHome || options.frontPushAhead <= 0) return s.pushHome;
    const float riot = enemies->GetEnemyCost(ROLE_TYPE(RIOT));        // observed metal in riot hulls
    if (options.frontPushHomeRiot > 0 && riot >= options.frontPushHomeRiot) reason = "riot";
    ...
    s.pushHome = true;  // for the game
}
```
````

- **Cut, do not write.** The lines come from the source at the head (gather
  step 8), trimmed to the two to nine lines that carry the rule, with `...`
  where lines were dropped. Names, signatures and constants stay as the source
  has them; a reader will grep for them. Whitespace may be re-aligned.
- **Pick the purest form.** A header rule with a unit test beats its call
  site; the call site beats the controller loop around it; a predicate or
  lambda beats the function that installs it.
- **Annotate the levers.** One trailing comment per line at most, naming the
  JSON key or the derived window the line reads ("own-400 .. min(own+600,
  anchor)"), so the sample explains itself without the Fix column.
- **Pair script with native** when one rule spans both: the script block that
  sets the option, then the native block that checks the invariant. Two
  fenced blocks under one bold name, no prose between them.
- **Close the area with its levers.** After the last sample, one `json` block
  with the area's new keys and the balanced profile's values, so the knob
  sits beside the rule it turns. A row whose whole mechanism is one JSON
  number needs no sample of its own; the lever block covers it.
- **A sample per lever, not per row.** Every key a Fix cell names appears in
  a block being read, so the reader sees where in the decision it acts (the
  last multiplier after admission reads differently from a gate before it).
  A key that appears only in the closing `json` block, with no line reading
  it, is a lever the body has not explained.
- **Harness gets a case fragment**, not a runner excerpt: the new case keys
  as a fixture uses them.
- Language tags are `cpp`, `angelscript`, `json`, `lua`, `python`. No block
  without a tag.
- A single-fix PR carries one sample. A docs-only or refactor PR carries none.

### 4. Performance (when runtime code changed)

A four-row table, baseline against the published build, then one paragraph of
method and caveats.

```markdown
### 📈 Performance (natural 8v8, Supreme Isthmus, 16 AIs, 33 shared windows)
| | baseline | published build |
|---|---|---|
| AI mean ms/frame | 2.14 | 1.93 |
| AI p99 ms | 9.01 | 8.28 |
| sim speed | 4.42× | 5.02× |
```

The paragraph names any intermediate regression and its fix, states that
natural games vary and same-state exactness is not claimed, and pins the
measured build (commit and DLL hash prefix). Never infer FPS from an
asymptotic argument; if only a microbenchmark exists, say "component cost
only, whole-game FPS not measured".

### 5. Docs line

One paragraph: the decision range, invariant range, known-issue range, which
role documents moved, where they live if not in this repo, and the checkers
that passed (`check_invariants`, `check_role_docs`, `check_script_api`,
`check_doc_links`) with their finding counts. Pre-existing failures are named
as pre-existing with the count.

### 6. Limits (only when something is open)

Bullets, one line each, for anything a reviewer would otherwise discover
after merging: an item not played, a profile family not covered, a known issue
opened by this work, an owner decision still pending. Link each to its
`KI-nnn` or `D-nnn`. If nothing is open, omit the section rather than writing
"none".

### 7. Attribution

End with the attribution lines the session was given for pull requests, when
there are any. Nothing after them.

## Style rules

- Length budget: the prose of a ten-item batch (lead, tables, bullets,
  paragraphs) stays under 600 words; a single fix in about 15 lines. Code
  samples are outside that budget but each stays within two to nine lines, so
  a ten-feature batch with samples runs to about 1,900 words in all. If a
  section is longer than its table, cut the prose, not the table, and never
  cut a sample to make room for prose.
- Short sentences, one idea each. No em-dashes, no semicolons, no nested
  parentheses. Arrows are allowed only inside a Status cell to show a
  sequence ("target 1 → 2 → second gantry").
- Numbers live in tables or Status cells, not in prose. A number without its
  baseline or its unit is not evidence.
- Name a file only when the reviewer must open it. Commit hashes appear once,
  in the performance paragraph, as a short prefix.
- No commit-log dump, no file list, no narrative of the session ("first we
  tried", "the agent then"). The reader wants the result.
- No hedging adverbs ("should", "hopefully") and no superlatives. State what
  was measured, and in the limits line state what was not.
- Use the repo's verification vocabulary exactly: Built (compiles), Checked
  (static checkers at zero), Symbolised (crash traced), Played (observed in a
  game). "Tested" and "verified" on their own mean nothing here.
- Keep the body in GitHub-flavoured Markdown that renders on a phone: tables
  of three columns at most, no HTML, no images unless the user supplied them.

## Create or update

```bash
gh pr create --base <base> --head <branch> --title "<title>" --body-file "<scratchpad>/pr-body.md"
gh pr edit <number> --body-file "<scratchpad>/pr-body.md"   # after scope changes
gh pr view <number> --json mergeable,mergeStateStatus,statusCheckRollup
```

After creating, read the body back once with `gh pr view <number>` and fix any
table that lost its alignment. Then run the lever audit: list every
backticked key in the body and, for each, confirm three things: a clause says
what it does, a sample shows a line reading it, and a Status cell or a Limits
bullet states its own verification. A key that fails any of the three is
either explained in the same turn or removed from the body; it is never left
as a bare name. When later commits change what the body
claims (a corrected rule, an item dropped, a new play result), edit the body
in the same turn you push; a PR whose description lags its head misleads the
merger.

## Checklist

- [ ] Every row's Status column uses Built / Checked / Symbolised / Played and
      carries one number with its baseline.
- [ ] The lead states the overall verification state truthfully, including
      any item that is not Played.
- [ ] Performance section present if `src/` or `data/script/` changed, with
      method, pinned build and caveats; or the limits line says no comparison
      was run.
- [ ] Docs line names the checker results and where the docs live.
- [ ] Limits section lists every open `KI-` this work created and every
      pending owner decision, or is omitted because there are none.
- [ ] One sample per table row, cut from the source at the head, two to
      nine lines, tagged, with the area's lever values in a closing `json`
      block; a single fix carries one sample.
- [ ] Lever audit passed: every backticked key has a clause saying what it
      does, a sample line reading it, and its own verification in a Status
      cell or a Limits bullet. No row carries two mechanisms with different
      verification.
- [ ] Title under about 110 characters, game names not UnitDef ids.
- [ ] Prose under 600 words for a batch, 150 for a single fix; read back on
      GitHub once and count the fenced blocks against the table rows.
- [ ] Attribution lines last, when the session has them.

## Related

- `skills/maintain-changelog/SKILL.md`: the opt-in changelog entry, a
  different artifact with a different audience; a PR body does not replace
  it and is never copied into it.
- `../rjm.bar.docs/projects/circuitai/decisions.md`: where the reasoning the
  PR leaves out is kept.
- `../rjm.bar.docs/projects/circuitai/known-issues.md`: the source of the
  limits section.
