# TODO

## Status legend
- `done` resolved and implemented
- `open` still needs a decision or implementation
- `deferred` intentionally postponed

## Checklist

- `done` Import failures are fatal instead of warning-and-continuing.
- `done` Dependency changes should trigger a full rebuild of the dependent package rather than trying to patch an existing namespace in place.
- `open` Make dependency-triggered rebuild messaging explicit: say why the rebuild happened, which dependency triggered it, and what package code is being reloaded.
- `done` Trigger dependency-triggered rebuilds only when imported package state changed, not on every reload of a package with imports.
- `done` Dependency fingerprint tracking now only considers imported packages that were themselves loaded via `load_fast()`.
- `done` Dependency-triggered rebuild messages are implemented and show why the rebuild happened, which imported package changed, and which files are being reloaded.
- `open` Tighten incremental cache validation so cached namespace state is reused only when it is still the active registered namespace.
- `open` Decide whether switching the same package name to a different path should force a full reload.
- `open` Decide whether switching the same package name to a different path should invalidate other cache entries for that package name.
- `open` Fix package root discovery for paths inside a package such as `R/`, individual files, and `tests/testthat/`.
- `open` Decide whether S3 support is required for the current milestone.
- `open` If S3 is required, implement proper S3 registration and reload behavior.
- `open` If S3 is not implemented soon, document it as unsupported or partial.
- `open` Decide how to handle a `Package:` name change in place for the same directory path.
- `open` Decide whether dependent packages should refresh imports after a same-name dependency path switch.
- `open` Confirm that inter-package behavior should target `pkgload::load_all()` semantics where practical.
- `open` Decide whether current failing tests should assert target behavior or only current behavior when the two differ.
- `open` Keep the long-lived session test model or introduce stronger cleanup/isolation between stages.
- `open` Keep warning assertions narrow and scenario-specific instead of asserting “no warnings at all”.
- `open` Clean up invalid test assumptions that relied on synthetic package marker functions.
- `deferred` Define desired `.onLoad()` behavior.
- `deferred` Define desired `.onAttach()` behavior.
- `deferred` Decide whether hook behavior should match `pkgload` closely or be documented as intentionally different.
- `deferred` Decide whether to refactor loader internals before additional feature work beyond small targeted helper extraction.

## Dependency-triggered full rebuild implementation plan

1. Keep the current fast incremental path unchanged for ordinary same-package file edits.
   - No-change reloads and local-file-only reloads should keep current behavior.
   - Existing messaging and stale-symbol tradeoffs should remain intact in this path.

2. Use dependency fingerprints only as a trigger for the rebuild decision.
   - Track only imported packages that were themselves loaded via `load_fast()`.
   - If none of those imported packages changed, do not trigger a rebuild.
   - If one or more changed, rebuild the dependent package fully.

3. Route dependency-triggered rebuilds through a more `pkgload`-like full-load path.
   - The trigger and user-facing message now work.
   - The current full-load path is still not semantically close enough yet for `import(pkg)` and `importFrom(pkg, sym)` rebuild correctness.
   - Improve the full-load path instead of trying to patch imports incrementally.

4. Current precise namespace findings from the rebuild experiments.
   - `import(pkg)` case:
     - dependency-triggered rebuild fires
     - rebuilt function environment is correct
     - rebuilt imports environment is correct
     - imported symbol still resolves to the old function
   - `importFrom(pkg, sym)` case:
     - dependency-triggered rebuild fires
     - rebuilt function environment is correct
     - rebuilt imports environment is correct
     - imported symbol is refreshed correctly
     - rebuilt function still behaves as if it were using the old binding
   - Conclusion:
     - the remaining bug is deeper than trigger logic or messaging
     - the rebuilt namespace still differs from real package-loading semantics
     - the next focused implementation target is import processing, not rebuild triggering

5. Compare the full-load path directly against `pkgload` in this order.
   - Namespace creation:
     - current full-load namespace creation has been extracted into `.loadfast.create_ns_env()`
     - keep behavior stable while reworking helpers one at a time
   - Import processing:
     - this is the next focused task
     - rework `.loadfast.process_imports()` toward `pkgload` / base `loadNamespace` semantics
     - pay special attention to whole-package imports vs `importFrom()`
   - Code sourcing:
     - current full-load code loading has been extracted into `.loadfast.full_load_code()`
     - current parse/eval sourcing should be revisited only after import processing is reworked
   - Export registration:
     - verify export metadata setup is happening at the right point in the rebuild flow

6. Keep dependency-triggered rebuild messaging explicit and stable.
   - Message should say:
     - this is a dependency-triggered rebuild
     - which imported package(s) changed
     - which package files are being reloaded
   - Keep ordinary no-change messaging unchanged when dependency rebuild is not triggered.

7. Add or keep focused tests for the dependency-triggered rebuild path.
   - `import(pkg)` case: rebuilding dependent package picks up changed dependency behavior.
   - `importFrom(pkg, sym)` case: rebuilding dependent package picks up changed dependency behavior.
   - Combined local-change + dependency-change case.
   - Messaging checks: reason and triggering dependency are reported.
   - Negative case: no dependency change does not trigger rebuild messaging.

8. After dependency-triggered rebuild is working, simplify the namespace-refresh experiments.
   - Remove dead incremental import-refresh logic that no longer contributes to behavior.
   - Keep one clear fast path and one clear dependency-triggered rebuild path.

## Recommended next actions

1. Keep dependency fingerprint tracking only as the trigger for rebuild decisions.
2. Rework `.loadfast.process_imports()` toward `pkgload` / base `loadNamespace` semantics.
3. Use the current failing dependency tests as the acceptance checks for that import-processing rework.
4. Keep explicit user-facing messages for dependency-triggered rebuilds.
5. Revisit full-load code sourcing only after import processing is corrected.
6. Decide and document the short-term S3 stance: implement now or mark unsupported.
