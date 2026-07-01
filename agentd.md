# Agent Directive Notes

This file holds narrow process directives that do not need to be loaded for
every task. Open it only when the task asks for a session record or a harness
directive style decision.

## Session Records

Use `docs/session-archive/<yyyy-mm-dd>-<short-topic>/README.md` for session
records.

Write records as concise engineering handoff notes:

- Start with a title and UTC date.
- State the outcome first.
- List the exact files, commands, services, or packages that changed.
- Include validation commands that actually ran.
- Include known blockers or environment caveats without treating them as
  success.
- Keep the record scoped to the session; do not summarize unrelated dirty
  worktree changes as if they were part of the same task.
- Link to deeper notes only when a session is large enough to need separate
  topic files.

Use progressive disclosure:

- Keep `AGENTS.md` as the router and short memory.
- Put reusable workflow rules here or in `docs/agent-harness.md`.
- Put role ownership in `docs/agent-roles.md`, not in session records.
- Put detailed evidence in the session archive only when someone asks for a
  record or when it materially helps the next proof.

Prefer this style:

```text
# Short Topic Session

Date: YYYY-MM-DD UTC

One short paragraph explaining what the record covers.

## Outcome

- Concrete result.
- Concrete result.

## Validation

Commands that ran, in fenced bash blocks.

## Notes

- Blockers, environment caveats, or next command.
```
