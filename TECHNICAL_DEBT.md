# Technical debt

This document tracks known implementation debt and conscious tradeoffs in the `loadfast` package implementation under `R/`. It is intentionally short and action-oriented. The goal is to preserve context for future edits without restating the whole implementation.

## Current status

- The package implementation under `R/` passes the current repo test suite.
- The loader design is broadly sound for the target use case.
- Most debt is in edge-case correctness and maintainability rather than basic functionality.

## Medium-priority debt

### 1. Incremental cache validity is inferred too loosely
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

### 2. Cache is keyed only by normalized path
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

## Low-priority debt

### 3. Testthat detection logic is duplicated
**Why this matters**

Logic for detecting testthat usage and helper sourcing is repeated in multiple places. The runtime cost is trivial, but the duplication increases maintenance cost.

**Risk**
- Small drift between code paths
- Unnecessary repetition in package source that now lives in one canonical implementation file

**Preferred fix**
- Extract a small helper for detecting whether testthat helpers should be considered available

**Priority**
- Low

### 4. Package env sync logic is duplicated conceptually
**Why this matters**

The full-load and incremental-load paths both bulk-copy namespace and imports into the attached package env. The duplication is reasonable, but it is a maintenance seam.

**Risk**
- Future edits may update one path but not the other

**Preferred fix**
- Optionally extract a small helper for package env synchronization

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

### 3. `Collate` support is intentionally narrow
The loader now respects the `Collate` field from `DESCRIPTION` when ordering `R/*.R` files, and this behavior is covered by the test suite.

This is still intentionally lightweight rather than a full reproduction of every package-loading edge case. Future changes should preserve the current `Collate` behavior without overcomplicating the package implementation.

**Current rule**
- Treat `Collate` ordering for `R/*.R` as supported behavior
- Be cautious about expanding this area unless a concrete incompatibility appears

## Suggested implementation order

1. Harden incremental cache validation
2. Store `pkg_name` in cache entries and invalidate on package identity changes
3. Extract tiny helpers for testthat detection and package env sync if the file grows further

## Notes for future reviewers

- Most of the implementation complexity is justified by R namespace machinery, especially S4 behavior and imports metadata shape.
- The current code is more "pragmatic systems R" than elegant, which is appropriate here.
- Avoid refactoring for style alone unless it clearly improves correctness, installability, or package ergonomics.
