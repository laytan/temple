# Project Workflow

## Guiding Principles

1. **The Plan is the Source of Truth:** All work must be tracked in `plan.md`.
2. **Test-Driven Development:** Write failing unit/regression tests before or alongside implementing features, and verify zero memory leaks under `odin test`'s tracking allocator.
3. **Atomic Commits:** Use Conventional Commits (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`).
4. **Non-Interactive CI Readiness:** All test commands (`odin test cli`, `odin test .`, `odin test tests`) must run headlessly and deterministically.

## Task Workflow

1. Select the next `[ ]` task in the active track's `plan.md` and mark it `[~]`.
2. Write unit/regression tests covering the expected behavior and edge cases.
3. Implement the minimal, idiomatic Odin code required to pass the tests.
4. Run verification suites:
   - `odin test cli`
   - `odin test .`
   - `odin run cli -- tests . && odin test tests`
5. Mark the task `[x]` in `plan.md` and commit changes.

## Phase Completion Verification and Checkpointing Protocol

At the end of each phase in `plan.md`, execute the phase verification task (`- [ ] Task: Conductor - User Manual Verification '<Phase Name>' (Protocol in workflow.md)`) to ensure all tests pass, documentation is updated, and working tree state is clean.
