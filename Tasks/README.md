# Tasks

One JSON file per task in `items/` (`T-<yyMMdd>-<4 hex>.json`), so two people adding or updating
different tasks never edit the same file. Use `tools\task.cmd` rather than editing by hand.

| Field | Meaning |
|---|---|
| `id`, `title`, `priority` (1 = highest) | identity and order |
| `status` | `todo` → `doing` (claimed) → `done` (merged with its PR) / `blocked` |
| `paths` | files or folders (globs) the task will touch; claims with overlapping paths are refused |
| `strataRefs` | context ids from `.strata/strata_index.json` (`cs:Namespace.Type`) the agent should read |
| `acceptance` | checks that must pass before `done` |
| `assignee`, `agent`, `branch` | set by `tools\task.cmd claim` (agent = human, claude, codex, codex-local, strata) |
| `createdBy`, `createdAt`, `completedAt`, `notes` | bookkeeping |

**Who is working on what right now** is not in these files: it is the claim ref `refs/claims/<id>` on
origin, created atomically by `tools\task.cmd claim`. Its state goes doing -> review (`done`) or blocked
(`block`), and it is deleted by the `release-claims` GitHub workflow when the task's PR is merged or closed
(or manually with `release`).
`tools\task.cmd list` shows both.
