---
name: maintain-changelog
description: 'Create or update a reasoned CircuitAI changelog entry on explicit request. Use only when the user asks to write, maintain, or record a changelog. Produces date-partitioned Markdown entries with full timestamps, implementation details, rationale, affected surfaces, and honest validation status.'
compatibility: 'Windows-safe paths and filenames; Git working tree access required to inspect the change being documented.'
metadata:
  version: '1.0.0'
---

# Maintain Changelog

## When to Use

- The user explicitly asks to create, update, or maintain a changelog.
- The user explicitly asks to record completed work as a change entry.
- The user invokes `maintain-changelog` by name.

Do not invoke this skill merely because code, configuration, documentation, or
other repository files changed. Changelog creation is opt-in.

## Procedure

1. Inspect the completed change and relevant diff before writing the entry.
   Document the actual outcome rather than the original request or intended
   implementation.
2. Group tightly coupled edits from one task into one entry. Use separate
   entries for unrelated outcomes.
3. Determine the local completion timestamp, including seconds and numeric UTC
   offset. Prefer the conversation's current datetime when supplied; otherwise
   obtain it from the local system.
4. Create the entry under `../rjm.bar.docs/projects/circuitai/` using this hierarchy:

   ```text
   changelog/
     YYYY/
       MM/
         DD/
           YYYY-MM-DDTHHMMSS±HHMM-short-description.md
   ```

   Use a lowercase kebab-case description. Omit colons from the time and UTC
   offset so the filename is valid on Windows. Example:

   ```text
   changelog/2026/09/13/2026-09-13T125326-0300-air-role-policy.md
   ```

5. Write a Markdown entry with these sections:

   ```markdown
   # Concise outcome

   ## Summary

   Describe the resulting behavior or repository outcome.

   ## Changes

   List the concrete implementation changes and affected files or surfaces.

   ## Reasoning

   Explain why this approach was selected, including meaningful alternatives,
   constraints, and tradeoffs.

   ## Validation

   Record only checks actually performed. Explicitly identify pending runtime,
   integration, or in-game validation.
   ```

6. Reference related issues, pull requests, commits, requirements, or design
   documents when they materially explain the change.
7. Keep the entry decision-oriented. Do not include a command transcript,
   speculative claims, secrets, credentials, or unrelated working-tree
   changes.
8. Treat committed entries as historical records. Record a later correction or
   reversal in a new timestamped entry rather than rewriting history. An
   uncommitted entry from the current task may be corrected directly.
9. Run `git diff --check` and confirm the new entry is the only changelog file
   created for that coherent task.

## Repository Notes

- All changelog entries must be Markdown files.
- `BARB5_CHANGELOG.md` is the specialized native-integration history. Do not
  use or modify it unless the requested change specifically concerns that
  history.
- Creating the hierarchy on first use is expected; do not create placeholder
  files for empty dates.
