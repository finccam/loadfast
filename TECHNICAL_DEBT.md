# Technical debt

This document tracks known implementation debt and conscious tradeoffs in `loadfast.R`. It is intentionally short and action-oriented. The goal is to preserve context for future edits without restating the whole implementation.

## Current status

- `loadfast.R` passes the current repo test suite.
- The loader design is broadly sound for the target use case.
- Most debt is in edge-case correctness and maintainability rather than basic functionality.

## High-priority debt

### 1. Source errors are downgraded to warnings during file sourcing
**Why this matters**

If a changed file fails to source, the loader currently warns and continues. That can leave the namespace and attached package environment in a partially updated state.

In incremental mode this is riskier because a failed source can still be followed by cache updates, which means a broken file may no longer be considered changed on the next call.

**Risk**
- Partial reload state
- Broken edit can appear "accepted"
- Next incremental call may say "no changes" even though the file never loaded successfully

**Preferred fix**
- Treat source failures as fatal for the current `load_fast()` call
- At minimum, do not update the incremental cache if any file failed to source

**Priority**
- High

## Medium-priority debt

### 2. Incremental cache validity is inferred too loosely
**Why this matters**

Incremental reload currently checks whether:
- a cache entry exists for the normalized path
- the package name is in `loadedNamespaces()`
- the attached package env is on the search path

That does not fully prove that the cached namespace env is still the active registered namespace for the package.

**Risk**
- Reusing stale env references after manual unloads or namespace manipulation
- Hard-to-debug edge cases in interactive sessions

**Preferred fix**
- Store `pkg_name` in the cache entry
- Verify the cached namespace env matches the currently registered namespace before taking the incremental path

**Priority**
- Medium

### 3. Cache is keyed only by normalized path
**Why this matters**

If the `Package:` field in `DESCRIPTION` changes in place for the same directory, the path-based cache may no longer describe the same logical package.

**Risk**
- Mismatch between cached namespace state and current package identity

**Preferred fix**
- Store `pkg_name` alongside the cache entry
- Force a full reload when the cached package name differs from the current `DESCRIPTION`

**Priority**
- Medium

## Low-priority debt

### 4. Testthat detection logic is duplicated
**Why this matters**

Logic for detecting testthat usage and helper sourcing is repeated in multiple places. The runtime cost is trivial, but the duplication increases maintenance cost.

**Risk**
- Small drift between code paths
- Unnecessary repetition in a file intended to stay copy-paste friendly

**Preferred fix**
- Extract a small helper for detecting whether testthat helpers should be considered available

**Priority**
- Low

### 5. Package env sync logic is duplicated conceptually
**Why this matters**

The full-load and incremental-load paths both bulk-copy namespace and imports into the attached package env. The duplication is reasonable, but it is a maintenance seam.

**Risk**
- Future edits may update one path but not the other

**Preferred fix**
- Optionally extract a small helper for package env synchronization

**Priority**
- Low

### 6. Top-level sourcing message is noisy
**Why this matters**

Sourcing `loadfast.R` emits a message immediately. That is workable in interactive use but slightly noisy for scripts and automated flows.

**Risk**
- Extra console noise
- Less predictable output in scripted workflows

**Preferred fix**
- Consider removing the top-level attach message, or make it opt-in

**Priority**
- Low

## Conscious tradeoffs, not bugs

These should not be "fixed" casually unless the project goals change.

### 1. Incremental reload does not clean up stale symbols
The incremental path does not track which symbols came from which file and does not remove stale objects when files are deleted or functions are removed.

This is intentional. It avoids the symbol-tracking and repeated enumeration costs that made previous approaches too slow on large projects.

**Current rule**
- Use `full = TRUE` when files are deleted or exported objects are removed

### 2. `renv.lock` warning persists until a full reload
When `renv.lock` changes, incremental reload continues to warn on later calls until a full reload resets the baseline.

This is intentional and tested. It favors making dependency drift obvious over silently accepting a new lockfile baseline.

### 3. File ordering is alphabetical rather than `Collate`-aware
The loader sources `R/*.R` in alphabetical filename order.

This is acceptable for the current test package and is partially mitigated by suppressing the harmless S4 "no definition for class" notices that arise from some ordering situations. But it is still a semantic difference from full package loading behavior for packages that rely on `Collate`.

**Current rule**
- Treat this as a scope limitation unless support for `Collate` becomes a project goal

## Suggested implementation order

1. Make source failures fail the load, or at least prevent cache updates after failed sourcing
2. Harden incremental cache validation
3. Store `pkg_name` in cache entries and invalidate on package identity changes
4. Extract tiny helpers for testthat detection and package env sync if the file grows further

## Notes for future reviewers

- Most of the implementation complexity is justified by R namespace machinery, especially S4 behavior and imports metadata shape.
- The current code is more "pragmatic systems R" than elegant, which is appropriate here.
- Avoid refactoring for style alone unless it clearly improves correctness or preserves the copy-paste single-file design.