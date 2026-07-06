.loadfast.cache <- new.env(parent = emptyenv())
.loadfast.state <- new.env(parent = emptyenv())
.loadfast.state$stack <- character(0)

# R's namespace registry has no public API for dev loaders: the base wrappers
# around registerNamespace/unregisterNamespace are not exported, and rlang's
# ns_registry_env() is defunct as of rlang 1.2.0. Construct the .Internal()
# calls at runtime instead -- the same approach current pkgload uses.
.loadfast.ns_register <- function(name, env) {
  eval(as.call(list(
    quote(.Internal),
    as.call(list(quote(registerNamespace), name, env))
  )))
  invisible(env)
}

.loadfast.ns_unregister <- function(name) {
  eval(as.call(list(
    quote(.Internal),
    as.call(list(quote(unregisterNamespace), name))
  )))
  invisible(NULL)
}

.onAttach <- function(libname, pkgname) {
  packageStartupMessage("Incremental reload is available via load_fast().")
}

#' Load a package from source with MD5-based incremental reloading
#'
#' `load_fast()` is a lightweight alternative to `devtools::load_all()`.
#' On the first call for a package path it performs a full teardown and rebuild.
#' On subsequent calls for that same path it re-sources only `R/` files whose
#' MD5 hashes changed.
#'
#' Several interdependent source packages can be loaded in the same session:
#' load the dependency first, then the packages that import from it. When a
#' package is reloaded, every loaded package that (directly or transitively)
#' imports from it is flagged, and its next `load_fast()` call is
#' automatically upgraded to a full reload so importers never keep running
#' against a stale snapshot. A full reload also reloads flagged dependencies
#' first, in dependency order.
#'
#' Packages listed in the `Depends` field of `DESCRIPTION` are attached to
#' the search path during a full load, mirroring `library()` semantics.
#'
#' @param path Path to a package root containing `DESCRIPTION`, `NAMESPACE`,
#'   and `R/`. If `path` points inside a package, `load_fast()` walks upward to
#'   the package root.
#' @param helpers If `TRUE`, source `tests/testthat/helper*.R` when testthat is
#'   available.
#' @param attach_testthat If `NULL`, auto-detect whether `testthat` should be
#'   attached. If `TRUE`, attach `testthat`.
#' @param full If `TRUE`, force a complete teardown and rebuild.
#' @param verbose If `TRUE`, emit per-phase timing logs.
#'
#' @return Invisibly returns the namespace environment (or `NULL` for a
#'   package without `R/` files).
#'
#' @examples
#' \dontrun{
#' # Load the package containing the current working directory
#' load_fast()
#'
#' # Load a specific package and force a clean rebuild
#' load_fast("path/to/pkg", full = TRUE)
#' }
#' @export
load_fast <- function(path = ".", helpers = TRUE, attach_testthat = NULL, full = FALSE, verbose = FALSE) {
  if (length(.loadfast.state$stack) > 0L) {
    stop("load_fast() re-entrance detected -- a sourced file is calling load_fast()")
  }
  .loadfast.load(path, helpers = helpers, attach_testthat = attach_testthat, full = full, verbose = verbose)
}

.loadfast.load <- function(path = ".", helpers = TRUE, attach_testthat = NULL, full = FALSE, verbose = FALSE) {
  if (verbose) {
    .t0 <- proc.time()["elapsed"]
    .t_last <- .t0
    .timer <- function(label) {
      now <- proc.time()["elapsed"]
      message(sprintf("[load_fast] %-40s %7.3fs (cumul %7.3fs)", label, now - .t_last, now - .t0))
      .t_last <<- now
    }
  } else {
    .timer <- function(label) invisible(NULL)
  }

  abs_path <- .loadfast.find_package_root(path)
  if (abs_path %in% .loadfast.state$stack) {
    stop("load_fast() re-entrance detected for ", abs_path)
  }
  .loadfast.state$stack <- c(.loadfast.state$stack, abs_path)
  on.exit(
    .loadfast.state$stack <- setdiff(.loadfast.state$stack, abs_path),
    add = TRUE
  )

  path_input <- normalizePath(path, mustWork = TRUE)
  path_display <- if (identical(path, ".")) {
    basename(abs_path)
  } else if (grepl("^(?:[A-Za-z]:[/\\\\]|[/\\\\])", path)) {
    basename(abs_path)
  } else {
    rel_path <- sub(
      paste0("^", gsub("([][{}()+*^$.|\\\\?])", "\\\\\\1", chartr("\\", "/", normalizePath(getwd(), mustWork = TRUE))), "/?"),
      "",
      chartr("\\", "/", path_input)
    )
    if (identical(rel_path, chartr("\\", "/", abs_path))) basename(abs_path) else rel_path
  }
  r_dir_display <- file.path(path_display, "R")

  desc_path <- file.path(abs_path, "DESCRIPTION")
  if (!file.exists(desc_path)) stop("DESCRIPTION file not found at: ", desc_path)
  desc_fields <- read.dcf(desc_path)
  pkg_name <- if ("Package" %in% colnames(desc_fields)) unname(trimws(desc_fields[1L, "Package"])) else ""
  if (!nzchar(pkg_name)) stop("No valid 'Package' field found in DESCRIPTION")

  pkg_env_name <- paste0("package:", pkg_name)
  loaded_pkg_path <- .loadfast.loaded_package_path(pkg_name)

  if (!is.null(loaded_pkg_path) && !identical(loaded_pkg_path, abs_path)) {
    warning(
      "Package '", pkg_name, "' is already loaded from a different path: ",
      loaded_pkg_path,
      ". Reloading from ",
      abs_path,
      " will replace the existing loaded package.",
      call. = FALSE
    )
  }

  r_dir <- file.path(abs_path, "R")
  if (!dir.exists(r_dir)) stop("Directory does not exist: ", r_dir_display)

  r_files <- list.files(r_dir, pattern = "\\.[Rr]$", full.names = TRUE)
  collate_value <- if ("Collate" %in% colnames(desc_fields)) trimws(desc_fields[1L, "Collate"]) else ""
  if (nzchar(collate_value)) {
    collate_entries <- trimws(scan(
      text = collate_value,
      what = character(),
      quiet = TRUE,
      quote = "'\""
    ))
    collate_entries <- collate_entries[nzchar(collate_entries)]
    collate_files <- normalizePath(file.path(r_dir, collate_entries), mustWork = FALSE)
    existing_collate_files <- unique(collate_files[file.exists(collate_files)])
    r_files_norm <- normalizePath(r_files, mustWork = TRUE)
    remaining_files <- r_files[!(r_files_norm %in% existing_collate_files)]
    remaining_files <- remaining_files[order(basename(remaining_files))]
    r_files <- c(existing_collate_files, remaining_files)
  } else {
    r_files <- r_files[order(basename(r_files))]
  }
  if (length(r_files) == 0L) {
    message("No R files found in ", r_dir_display, ".")
    return(invisible(NULL))
  }

  current_hashes <- tools::md5sum(r_files)
  names(current_hashes) <- r_files

  lock_path <- file.path(abs_path, "renv.lock")
  current_lock_hash <- if (file.exists(lock_path)) unname(tools::md5sum(lock_path)) else NA_character_

  .timer("desc + file discovery + md5")

  cached <- NULL
  if (!isTRUE(full) && exists(abs_path, envir = .loadfast.cache, inherits = FALSE)) {
    cached <- .loadfast.cache[[abs_path]]
  }

  active_ns_env <- if (pkg_name %in% loadedNamespaces()) {
    tryCatch(asNamespace(pkg_name), error = function(e) NULL)
  } else {
    NULL
  }

  needs_full_reason <- if (is.null(cached)) NULL else cached$needs_full
  if (!is.null(needs_full_reason)) {
    message("Full reload of '", pkg_name, "': ", needs_full_reason, ".")
  }

  can_incremental <- !is.null(cached) &&
    is.null(needs_full_reason) &&
    !is.null(active_ns_env) &&
    identical(cached$ns_env, active_ns_env) &&
    pkg_env_name %in% search()

  if (can_incremental) {
    ns_env <- cached$ns_env
    pkg_env <- as.environment(pkg_env_name)
    old_hashes <- cached$hashes
    old_lock_hash <- if (is.null(cached$lock_hash)) NA_character_ else cached$lock_hash
    registered_reload_files <- if (is.null(cached$registered_reload_files)) character(0) else cached$registered_reload_files
    pending_reload_message <- if (is.null(cached$pending_reload_message)) NULL else cached$pending_reload_message
    s3_methods_matrix <- if (is.null(cached$s3_methods)) matrix(NA_character_, 0L, 4L) else cached$s3_methods

    if (!identical(current_lock_hash, old_lock_hash)) {
      warning(
        "renv.lock changed since the initial load_fast() call for this path; dependency changes may require restarting R or reinstalling packages.",
        call. = FALSE
      )
    }

    old_files <- names(old_hashes)
    new_files <- names(current_hashes)
    added_files <- setdiff(new_files, old_files)
    common_files <- intersect(new_files, old_files)
    changed_files <- common_files[current_hashes[common_files] != old_hashes[common_files]]

    old_files_cmp <- chartr("\\", "/", old_files)
    new_files_cmp <- chartr("\\", "/", new_files)
    registered_reload_files_cmp <- chartr("\\", "/", registered_reload_files)

    registered_existing_reload_files <- new_files[new_files_cmp %in% intersect(new_files_cmp, registered_reload_files_cmp)]
    registered_added_reload_files <- setdiff(registered_reload_files_cmp, old_files_cmp)
    registered_added_reload_files <- new_files[new_files_cmp %in% intersect(new_files_cmp, registered_added_reload_files)]

    files_to_source <- unique(c(changed_files, added_files, registered_existing_reload_files, registered_added_reload_files))
    # Re-source in the same order as a full load (Collate-aware r_files order),
    # so class definitions still come before methods when both files changed.
    files_to_source <- files_to_source[order(match(files_to_source, r_files))]

    if (length(files_to_source) == 0L) {
      if (!is.null(pending_reload_message)) {
        message(pending_reload_message)
      }
      .loadfast.cache[[abs_path]] <- list(
        ns_env = ns_env,
        pkg_name = pkg_name,
        hashes = current_hashes,
        lock_hash = old_lock_hash,
        s3_methods = s3_methods_matrix,
        import_pkgs = cached$import_pkgs,
        needs_full = NULL,
        registered_reload_files = character(0),
        pending_reload_message = NULL
      )
      message("No changes in ", r_dir_display, ".")
      .loadfast.source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
      .timer("TOTAL (no-change)")
      return(invisible(ns_env))
    }

    old_tle <- getOption("topLevelEnvironment")
    on.exit(options(topLevelEnvironment = old_tle), add = TRUE)
    options(topLevelEnvironment = ns_env)

    for (f in files_to_source) {
      .loadfast.source_one(f, ns_env)
    }
    .timer(paste0("incr source ", length(files_to_source), " files"))

    # Re-sourcing a file replaces its function objects in `ns_env`, but the S3
    # methods table holds separate (eagerly copied) references for methods on
    # local generics, so it must be rebuilt to point at the fresh definitions.
    .loadfast.register_s3(s3_methods_matrix, pkg_name, ns_env, reset = TRUE)
    .timer("incr S3 re-registration")

    list2env(as.list(ns_env, all.names = FALSE), envir = pkg_env)
    list2env(as.list(parent.env(ns_env), all.names = TRUE), envir = pkg_env)
    .timer("incr pkg_env sync")

    .loadfast.cache[[abs_path]] <- list(
      ns_env = ns_env,
      pkg_name = pkg_name,
      hashes = current_hashes,
      lock_hash = old_lock_hash,
      s3_methods = s3_methods_matrix,
      import_pkgs = cached$import_pkgs,
      needs_full = NULL,
      registered_reload_files = character(0),
      pending_reload_message = NULL
    )
    .loadfast.invalidate_dependents(pkg_name, abs_path)

    n_changed <- length(changed_files)
    n_added <- length(added_files)
    n_registered_reloads <- length(unique(c(registered_existing_reload_files, registered_added_reload_files)))
    parts <- character()
    if (n_changed > 0L) parts <- c(parts, paste0(n_changed, " changed"))
    if (n_added > 0L) parts <- c(parts, paste0(n_added, " added"))
    if (n_registered_reloads > 0L) parts <- c(parts, paste0(n_registered_reloads, " registered reload"))

    changed_display <- basename(files_to_source)
    if (length(changed_display) > 5L) {
      changed_display <- c(
        changed_display[seq_len(5L)],
        paste0("and ", length(files_to_source) - 5L, " more file(s)")
      )
    }

    if (!is.null(pending_reload_message)) {
      message(pending_reload_message)
    }

    message(
      "Incremental reload: ",
      paste(parts, collapse = ", "),
      " [",
      paste(changed_display, collapse = ", "),
      "]"
    )

    .loadfast.run_hook(".onLoad", ns_env, abs_path, pkg_name)
    .timer("incr .onLoad")

    .loadfast.source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
    .timer("TOTAL (incremental)")
    return(invisible(ns_env))
  }

  # ---- FULL LOAD ----

  # If the Package field changed in place, the cache entry (and the loaded
  # namespace it references) describe a different logical package; tear the old
  # identity down so it does not linger on the search path.
  prior <- if (exists(abs_path, envir = .loadfast.cache, inherits = FALSE)) {
    .loadfast.cache[[abs_path]]
  } else {
    NULL
  }
  if (!is.null(prior) && !is.null(prior$pkg_name) && !identical(prior$pkg_name, pkg_name)) {
    old_name <- prior$pkg_name
    message(
      "Package name at ", path_display, " changed from '", old_name, "' to '",
      pkg_name, "'; unloading '", old_name, "'."
    )
    .loadfast.teardown(old_name, abs_path)
    rm(list = abs_path, envir = .loadfast.cache)
  }

  depends_pkgs <- .loadfast.parse_depends(desc_fields)
  for (dep in depends_pkgs) {
    if (!paste0("package:", dep) %in% search()) {
      tryCatch(
        library(dep, character.only = TRUE, warn.conflicts = FALSE),
        error = function(e) {
          stop(
            "Failed to attach Depends package '", dep, "': ",
            conditionMessage(e),
            "\nIf it is a source package, load it with load_fast() first.",
            call. = FALSE
          )
        }
      )
    }
  }
  .timer("attach Depends")

  ns_file <- file.path(abs_path, "NAMESPACE")
  nsInfo <- NULL
  dep_pkg_names <- character(0)
  if (file.exists(ns_file)) {
    nsInfo <- parseNamespaceFile(
      basename(abs_path),
      dirname(abs_path),
      mustExist = FALSE
    )
    dep_pkg_names <- unique(c(
      vapply(nsInfo$imports, function(i) as.character(i[[1L]]), character(1L)),
      vapply(nsInfo$importClasses, function(i) as.character(i[[1L]]), character(1L)),
      vapply(nsInfo$importMethods, function(i) as.character(i[[1L]]), character(1L))
    ))
  }
  .timer("parseNamespaceFile")

  # Recursively reload cached dependencies that were flagged as needing a full
  # reload, so this package is rebuilt against fresh namespaces rather than
  # stale ones (dependency order converges in one call).
  for (key in ls(.loadfast.cache, all.names = TRUE)) {
    entry <- .loadfast.cache[[key]]
    if (identical(key, abs_path) || is.null(entry$needs_full)) next
    if (key %in% .loadfast.state$stack) next
    if (!(entry$pkg_name %in% dep_pkg_names)) next
    message("Reloading dependency '", entry$pkg_name, "' first: ", entry$needs_full, ".")
    .loadfast.load(key, helpers = FALSE, attach_testthat = FALSE, full = TRUE, verbose = verbose)
  }
  .timer("reload flagged dependencies")

  .loadfast.teardown(pkg_name, abs_path)
  .timer("detach + unload old ns")

  impenv <- new.env(parent = .BaseNamespaceEnv, hash = TRUE)
  attr(impenv, "name") <- paste0("imports:", pkg_name)

  ns_env <- new.env(parent = impenv, hash = TRUE)
  ns_env$.packageName <- pkg_name

  pkg_version <- if ("Version" %in% colnames(desc_fields)) {
    unname(trimws(desc_fields[1L, "Version"]))
  } else {
    "0.0.0"
  }
  if (is.na(pkg_version) || !nzchar(pkg_version)) pkg_version <- "0.0.0"

  info <- new.env(hash = TRUE, parent = baseenv())
  ns_env[[".__NAMESPACE__."]] <- info
  info[["spec"]] <- c(name = pkg_name, version = pkg_version)
  setNamespaceInfo(ns_env, "exports", new.env(hash = TRUE, parent = baseenv()))
  # `lazydata` must exist even for packages that ship no data: base's
  # `getExportedValue()` (used by `pkg::name`) falls through to it for any name
  # not in `exports`, and `getNamespaceInfo(ns, "lazydata")` errors with
  # "object 'lazydata' not found" if the field is missing. See makeNamespace().
  lazydata_env <- new.env(parent = baseenv(), hash = TRUE)
  attr(lazydata_env, "name") <- paste0("lazydata:", pkg_name)
  setNamespaceInfo(ns_env, "lazydata", lazydata_env)
  setNamespaceInfo(ns_env, "imports", list(base = TRUE))
  setNamespaceInfo(ns_env, "path", abs_path)
  setNamespaceInfo(ns_env, "dynlibs", NULL)
  setNamespaceInfo(ns_env, "nativeRoutines", list())
  setNamespaceInfo(ns_env, "S3methods", matrix(NA_character_, 0L, 4L))
  ns_env[[".__S3MethodsTable__."]] <- new.env(hash = TRUE, parent = baseenv())
  ns_env[[".__DEVTOOLS__"]] <- new.env(parent = ns_env)

  if (isNamespaceLoaded(pkg_name)) {
    .loadfast.ns_unregister(pkg_name)
  }
  .loadfast.ns_register(pkg_name, ns_env)

  # If the load fails from here on (bad source file, failed import), do not
  # leave a half-built namespace registered or attached: the next call would
  # recover anyway, but `loadedNamespaces()` / `pkg::` must not expose a
  # partially loaded package in the meantime.
  full_load_ok <- FALSE
  on.exit(
    {
      if (!full_load_ok) {
        if (pkg_env_name %in% search()) {
          tryCatch(
            detach(pkg_env_name, character.only = TRUE, unload = FALSE, force = TRUE),
            error = function(e) NULL
          )
        }
        if (isNamespaceLoaded(pkg_name) &&
            identical(tryCatch(asNamespace(pkg_name), error = function(e) NULL), ns_env)) {
          tryCatch(.loadfast.ns_unregister(pkg_name), error = function(e) NULL)
        }
      }
    },
    add = TRUE
  )

  if (isNamespaceLoaded("methods")) {
    methods::setPackageName(pkg_name, ns_env)
  }
  .timer("create + register ns env")

  if (!is.null(nsInfo)) {
    for (i in nsInfo$imports) {
      imp_label <- if (is.character(i)) i else i[[1L]]
      tryCatch(
        {
          if (is.character(i)) {
            namespaceImport(ns_env, loadNamespace(i), from = pkg_name)
          } else if (!is.null(i$except)) {
            namespaceImport(
              ns_env,
              loadNamespace(i[[1L]]),
              from = pkg_name,
              except = i$except
            )
          } else {
            namespaceImportFrom(
              ns_env,
              loadNamespace(i[[1L]]),
              i[[2L]],
              from = pkg_name
            )
          }
        },
        error = function(e) {
          stop(
            "Import failed for ",
            deparse(i),
            ": ",
            conditionMessage(e),
            call. = FALSE
          )
        }
      )
      .timer(paste0("  import: ", imp_label))
    }

    for (imp in nsInfo$importClasses) {
      tryCatch(
        namespaceImportClasses(
          ns_env,
          loadNamespace(imp[[1L]]),
          imp[[2L]],
          from = pkg_name
        ),
        error = function(e) {
          stop(
            "importClassesFrom failed for ",
            imp[[1L]],
            ": ",
            conditionMessage(e),
            call. = FALSE
          )
        }
      )
      .timer(paste0("  importClasses: ", imp[[1L]], " [", paste(imp[[2L]], collapse = ","), "]"))
    }
    for (imp in nsInfo$importMethods) {
      tryCatch(
        namespaceImportMethods(
          ns_env,
          loadNamespace(imp[[1L]]),
          imp[[2L]],
          from = pkg_name
        ),
        error = function(e) {
          stop(
            "importMethodsFrom failed for ",
            imp[[1L]],
            ": ",
            conditionMessage(e),
            call. = FALSE
          )
        }
      )
      .timer(paste0("  importMethods: ", imp[[1L]], " [", paste(imp[[2L]], collapse = ","), "]"))
    }
    imports_canonical <- list(base = TRUE)
    for (i in nsInfo$imports) {
      if (is.character(i)) {
        imports_canonical[[i]] <- TRUE
      } else {
        pkg <- i[[1L]]
        syms <- i[[2L]]
        if (isTRUE(imports_canonical[[pkg]])) next
        imports_canonical[[pkg]] <- c(imports_canonical[[pkg]], syms)
      }
    }
    setNamespaceInfo(ns_env, "imports", imports_canonical)
  }

  old_tle <- getOption("topLevelEnvironment")
  on.exit(options(topLevelEnvironment = old_tle), add = TRUE)
  options(topLevelEnvironment = ns_env)

  for (f in r_files) {
    .loadfast.source_one(f, ns_env)
  }
  .timer(paste0("source ", length(r_files), " files"))

  s3_methods_matrix <- matrix(NA_character_, 0L, 4L)
  if (!is.null(nsInfo)) {
    exports <- .loadfast.compute_exports(ns_env, nsInfo, pkg_name)
    if (length(exports) > 0L) {
      namespaceExport(ns_env, exports)
    }
    s3_methods_matrix <- nsInfo$S3methods
    .loadfast.register_s3(s3_methods_matrix, pkg_name, ns_env)
  }
  .timer("exports + S3 registration")

  uses_testthat <- .loadfast.uses_testthat(abs_path)
  if (is.null(attach_testthat)) attach_testthat <- uses_testthat
  .loadfast.attach_testthat(attach_testthat, pkg_name)
  .timer("attach testthat")

  .loadfast.run_hook(".onLoad", ns_env, abs_path, pkg_name)
  .timer(".onLoad")

  pkg_env <- attach(NULL, name = pkg_env_name)
  list2env(as.list(ns_env, all.names = FALSE), envir = pkg_env)
  list2env(as.list(impenv, all.names = TRUE), envir = pkg_env)
  .timer("attach pkg to search path")

  # `.onAttach` is an attach-time hook (search-path attachment happens only on a
  # full load), so it runs here rather than in the incremental path, mirroring
  # library()/load_all(). `.onLoad` above covers the load-time hook.
  .loadfast.run_hook(".onAttach", ns_env, abs_path, pkg_name)
  .timer(".onAttach")

  if (isTRUE(helpers) && uses_testthat) {
    .loadfast.do_source_helpers(abs_path, pkg_env)
  }
  .timer("source testthat helpers")

  .loadfast.cache[[abs_path]] <- list(
    ns_env = ns_env,
    pkg_name = pkg_name,
    hashes = current_hashes,
    lock_hash = current_lock_hash,
    s3_methods = s3_methods_matrix,
    import_pkgs = setdiff(dep_pkg_names, "base"),
    needs_full = NULL,
    registered_reload_files = character(0),
    pending_reload_message = NULL
  )
  .loadfast.invalidate_dependents(pkg_name, abs_path)

  full_load_ok <- TRUE
  message("Load ", length(r_files), " file(s) from ", r_dir_display, ".")
  .timer("TOTAL (full load)")
  invisible(ns_env)
}

#' Register one or more files for reload on the next `load_fast()` call
#'
#' @param path Package root path.
#' @param files File paths to reload on the next call.
#' @param reason Optional human-readable reason shown in messages.
#'
#' @return Invisibly returns `TRUE` when a reload was registered and `FALSE`
#'   when there is no active cache for the package path.
#' @export
load_fast_register_reload <- function(path = ".", files, reason = NULL) {
  if (missing(files) || length(files) == 0L) stop("'files' must contain at least one path")

  if (identical(path, ".")) {
    tle <- getOption("topLevelEnvironment")
    if (!is.null(tle) && is.environment(tle)) {
      tle_path <- tryCatch(getNamespaceInfo(tle, "path"), error = function(e) NULL)
      if (!is.null(tle_path) && nzchar(tle_path)) {
        path <- tle_path
      }
    }
  }

  abs_path <- normalizePath(path, mustWork = TRUE)

  file_inputs <- as.character(files)
  file_paths <- character(length(file_inputs))
  for (i in seq_along(file_inputs)) {
    file_i <- file_inputs[[i]]
    candidate <- if (grepl("^(?:[A-Za-z]:[/\\\\]|[/\\\\])", file_i)) {
      file_i
    } else if (startsWith(file_i, paste0("R", .Platform$file.sep)) || startsWith(file_i, "R/") || startsWith(file_i, "R\\")) {
      file.path(abs_path, file_i)
    } else {
      file.path(abs_path, "R", file_i)
    }
    file_paths[[i]] <- normalizePath(candidate, mustWork = TRUE)
  }

  abs_path_cmp <- chartr("\\", "/", abs_path)
  file_paths_cmp <- chartr("\\", "/", file_paths)
  if (any(!startsWith(file_paths_cmp, paste0(abs_path_cmp, "/")))) {
    stop("All invalidated files must be inside the package path")
  }

  if (!exists(abs_path, envir = .loadfast.cache, inherits = FALSE)) {
    message("No active load_fast cache for ", abs_path, "; reload registration ignored")
    return(invisible(FALSE))
  }

  cached <- .loadfast.cache[[abs_path]]
  registered_reload_files <- unique(c(cached$registered_reload_files, file_paths))
  registered_reload_display <- file_inputs[match(registered_reload_files, file_paths)]
  registered_reload_display <- registered_reload_display[!is.na(registered_reload_display)]

  registration_message <- paste0(
    "Registered file ",
    paste(sprintf("'%s'", registered_reload_display), collapse = ", "),
    " for reload",
    if (is.null(reason) || !nzchar(reason)) "." else paste0(" (", reason, ").")
  )
  apply_message <- paste0(
    "Applying registered reload for ",
    paste(sprintf("'%s'", registered_reload_display), collapse = ", "),
    if (is.null(reason) || !nzchar(reason)) "." else paste0(" (", reason, ").")
  )

  cached$registered_reload_files <- registered_reload_files
  cached$pending_reload_message <- apply_message
  .loadfast.cache[[abs_path]] <- cached

  message(registration_message)
  invisible(TRUE)
}

# Compute the full set of names to export, mirroring base::loadNamespace():
# explicit export(), exportPattern() expansion, and (when the package defines S4
# metadata) exportClasses()/exportClassPattern() and exportMethods(). S4 classes
# are exported as their `.__C__<class>` metadata objects and S4 methods as the
# generic plus its `.__T__<generic>:<pkg>` method table, which is what
# importClassesFrom()/importMethodsFrom() look for in another package.
.loadfast.compute_exports <- function(ns_env, nsInfo, pkg_name) {
  exports <- nsInfo$exports
  for (p in nsInfo$exportPatterns) {
    exports <- c(ls(ns_env, pattern = p, all.names = TRUE), exports)
  }

  has_s4 <- isNamespaceLoaded("methods") && .loadfast.has_s4_metadata(ns_env)
  if (has_s4 && pkg_name != "methods") {
    methods::cacheMetaData(ns_env, TRUE, ns_env)

    for (p in nsInfo$exportPatterns) {
      expp <- ls(ns_env, pattern = p, all.names = TRUE)
      newEx <- !(expp %in% exports)
      if (any(newEx)) exports <- c(expp[newEx], exports)
    }

    expClasses <- nsInfo$exportClasses
    aClasses <- methods::getClasses(ns_env)
    classPatterns <- nsInfo$exportClassPatterns
    if (!length(classPatterns)) classPatterns <- nsInfo$exportPatterns
    pClasses <- unique(unlist(lapply(classPatterns, grep, aClasses, value = TRUE)))
    if (length(pClasses)) {
      good <- vapply(pClasses, methods::isClass, NA, where = ns_env)
      expClasses <- c(expClasses, pClasses[good])
    }
    if (length(expClasses)) {
      missing_classes <- !vapply(expClasses, methods::isClass, NA, where = ns_env)
      if (any(missing_classes)) {
        stop(
          "in package ", pkg_name, " classes ",
          paste(expClasses[missing_classes], collapse = ", "),
          " were specified for export but not defined",
          call. = FALSE
        )
      }
      expClasses <- paste0(methods::classMetaName(""), expClasses)
    }

    allGenerics <- unique(c(
      .loadfast.s4_generic_names(ns_env),
      .loadfast.s4_generic_names(parent.env(ns_env))
    ))
    expMethods <- nsInfo$exportMethods
    addGenerics <- expMethods[is.na(match(expMethods, exports))]
    if (length(addGenerics)) {
      have <- vapply(
        addGenerics,
        function(w) exists(w, mode = "function", envir = ns_env),
        NA, USE.NAMES = FALSE
      )
      exports <- c(exports, addGenerics[have])
    }
    expTables <- character()
    if (length(allGenerics)) {
      expMethods <- unique(c(expMethods, exports[!is.na(match(exports, allGenerics))]))
      tPrefix <- ".__T__"
      allMethodTables <- unique(c(
        .loadfast.s4_method_tables(ns_env),
        .loadfast.s4_method_tables(parent.env(ns_env))
      ))
      needMethods <- (exports %in% allGenerics) & !(exports %in% expMethods)
      if (any(needMethods)) expMethods <- c(expMethods, exports[needMethods])
      # Methods on primitive generics (e.g. `[`, `length`) are exportable even
      # when not listed in exportMethods(), so their method tables can reach an
      # importing package via importMethodsFrom(). Mirrors loadNamespace().
      pm <- allGenerics[!(allGenerics %in% expMethods)]
      if (length(pm)) {
        prim <- vapply(pm, function(pmi) {
          f <- tryCatch(methods::getFunction(pmi, FALSE, FALSE, ns_env), error = function(e) NULL)
          !is.null(f) && is.primitive(f)
        }, logical(1L))
        expMethods <- c(expMethods, pm[prim])
      }
      for (mi in expMethods) {
        if (!(mi %in% exports) && exists(mi, envir = ns_env, mode = "function", inherits = FALSE)) {
          exports <- c(exports, mi)
        }
        ii <- grep(paste0(tPrefix, mi, ":"), allMethodTables, fixed = TRUE)
        if (length(ii)) expTables <- c(expTables, allMethodTables[ii[1L]])
      }
    }
    exports <- c(exports, expClasses, expTables)
  }

  # Internal namespace objects must never be exported, even when an
  # exportPattern() happens to match them. Mirrors base::loadNamespace()'s
  # stoplist, plus loadfast's own `.__DEVTOOLS__` marker.
  stoplist <- c(
    ".__NAMESPACE__.", ".__S3MethodsTable__.", ".__DEVTOOLS__", ".packageName",
    ".First.lib", ".onLoad", ".onAttach", ".conflicts.OK", ".noGenerics"
  )
  exports <- exports[!exports %in% stoplist]
  exports <- exports[!is.na(exports) & nzchar(exports)]
  unique(exports)
}

# Inlined equivalents of the small methods-internal helpers used by
# base::loadNamespace() for export computation (.hasS4MetaData, .getGenerics,
# .TableMetaPrefix), so the package does not reach into methods:::. They rely
# on the stable `.__C__` / `.__T__` / `.__A__` S4 metadata naming convention
# that setClass()/setGeneric()/setMethod() write into the namespace.
.loadfast.has_s4_metadata <- function(env) {
  nms <- names(env)
  any(startsWith(nms, ".__C__")) ||
    any(startsWith(nms, ".__T__")) ||
    any(startsWith(nms, ".__A__"))
}

.loadfast.s4_method_tables <- function(env) {
  these <- ls(env, all.names = TRUE)
  these[startsWith(these, ".__T__")]
}

.loadfast.s4_generic_names <- function(env) {
  gsub("^\\.__T__(.*):([^:]+)", "\\1", .loadfast.s4_method_tables(env))
}

# Register S3 methods declared via S3method() in NAMESPACE, mirroring the
# registerS3methods() call inside base::loadNamespace(). Without this, S3
# dispatch fails for any method not resolvable in the calling frame -- notably
# methods on generics defined in other namespaces (e.g. base's `print`) and
# methods declared with S3method() but not exported by name.
.loadfast.register_s3 <- function(s3_methods, pkg_name, ns_env, reset = FALSE) {
  # registerS3methods() appends its input to the namespace's "S3methods" info
  # matrix each call. On incremental reloads we re-register to refresh the table
  # (re-sourced files replace the underlying functions), so reset the matrix
  # first to avoid unbounded growth and keep it in sync with what is declared.
  if (isTRUE(reset)) {
    setNamespaceInfo(ns_env, "S3methods", matrix(NA_character_, 0L, 4L))
  }
  if (is.null(s3_methods) || NROW(s3_methods) == 0L) {
    return(invisible(NULL))
  }
  registerS3methods(s3_methods, pkg_name, ns_env)
  invisible(NULL)
}

# Detach and unload a package by name. `unloadNamespace()` refuses to unload a
# namespace that other loaded namespaces import, which is the *normal* case in
# multi-package sessions; the fallback then runs `.onUnload` best-effort and
# force-removes the namespace from R's registry so a fresh one can take over.
# Importers keep references into the old (now unregistered) namespace until
# they are reloaded themselves; see .loadfast.invalidate_dependents().
.loadfast.teardown <- function(pkg_name, abs_path) {
  pkg_env_name <- paste0("package:", pkg_name)
  if (pkg_env_name %in% search()) {
    detach(pkg_env_name, character.only = TRUE, unload = FALSE, force = TRUE)
  }
  if (pkg_name %in% loadedNamespaces()) {
    old_ns <- tryCatch(asNamespace(pkg_name), error = function(e) NULL)
    tryCatch(unloadNamespace(pkg_name), error = function(e) {
      if (!is.null(old_ns) && exists(".onUnload", envir = old_ns, inherits = FALSE)) {
        tryCatch(
          get(".onUnload", envir = old_ns, inherits = FALSE)(dirname(abs_path)),
          error = function(e2) {
            warning(
              "Error in .onUnload() for '", pkg_name, "': ", conditionMessage(e2),
              call. = FALSE
            )
          }
        )
      }
      if (isNamespaceLoaded(pkg_name)) {
        tryCatch(.loadfast.ns_unregister(pkg_name), error = function(e2) NULL)
      }
    })
  }
  invisible(NULL)
}

# Depends packages must be attached to the search path (not just loaded):
# package code resolves them through the environment chain below the base
# namespace, exactly as for an installed package loaded via library().
.loadfast.parse_depends <- function(desc_fields) {
  if (!("Depends" %in% colnames(desc_fields))) return(character(0))
  raw <- desc_fields[1L, "Depends"]
  if (is.na(raw) || !nzchar(trimws(raw))) return(character(0))
  entries <- strsplit(raw, ",", fixed = TRUE)[[1L]]
  entries <- gsub("\\([^)]*\\)", "", entries)
  entries <- trimws(gsub("[[:space:]]+", " ", entries))
  entries <- entries[nzchar(entries)]
  setdiff(entries, "R")
}

# After a package is re-sourced (fully or incrementally), every cached package
# that imports from it -- directly or through other cached packages -- holds
# stale references: namespaceImportFrom() copies bindings at import time, so
# importers do not see re-sourced definitions. Flag them so their next
# load_fast() call is upgraded to a full reload.
.loadfast.invalidate_dependents <- function(pkg_name, skip_path) {
  keys <- ls(.loadfast.cache, all.names = TRUE)
  flagged <- pkg_name
  repeat {
    changed <- FALSE
    for (key in keys) {
      if (identical(key, skip_path)) next
      entry <- .loadfast.cache[[key]]
      if (is.null(entry$pkg_name) || entry$pkg_name %in% flagged) next
      if (!any(entry$import_pkgs %in% flagged)) next
      flagged <- c(flagged, entry$pkg_name)
      if (is.null(entry$needs_full)) {
        entry$needs_full <- paste0("dependency '", pkg_name, "' was reloaded")
        .loadfast.cache[[key]] <- entry
      }
      changed <- TRUE
    }
    if (!changed) break
  }
  invisible(NULL)
}

.loadfast.attach_testthat <- function(attach_testthat, pkg_name) {
  if (isTRUE(attach_testthat) &&
      pkg_name != "testthat" &&
      !("package:testthat" %in% search()) &&
      requireNamespace("testthat", quietly = TRUE)) {
    attachNamespace(loadNamespace("testthat"))
  }
  invisible(NULL)
}

.loadfast.run_hook <- function(hook, ns_env, abs_path, pkg_name) {
  if (!exists(hook, envir = ns_env, inherits = FALSE)) return(invisible(NULL))
  tryCatch(
    get(hook, envir = ns_env, inherits = FALSE)(dirname(abs_path), pkg_name),
    error = function(e) {
      warning("Error in ", hook, "() for '", pkg_name, "': ", conditionMessage(e), call. = FALSE)
    }
  )
  invisible(NULL)
}

.loadfast.source_one <- function(f, ns_env) {
  s4_pattern <- "no definition for class"
  tryCatch(
    withCallingHandlers(
      sys.source(f, envir = ns_env, keep.source = TRUE),
      warning = function(w) {
        if (grepl(s4_pattern, conditionMessage(w), fixed = TRUE)) {
          invokeRestart("muffleWarning")
        }
      },
      message = function(m) {
        if (grepl(s4_pattern, conditionMessage(m), fixed = TRUE)) {
          invokeRestart("muffleMessage")
        }
      }
    ),
    error = function(e) {
      stop("Failed to source ", f, ": ", conditionMessage(e), call. = FALSE)
    }
  )
}

.loadfast.loaded_package_path <- function(pkg_name) {
  if (!(pkg_name %in% loadedNamespaces())) {
    return(NULL)
  }

  tryCatch(
    {
      loaded_path <- getNamespaceInfo(asNamespace(pkg_name), "path")
      if (is.null(loaded_path) || !nzchar(loaded_path)) NULL else normalizePath(loaded_path, mustWork = FALSE)
    },
    error = function(e) NULL
  )
}

.loadfast.uses_testthat <- function(abs_path) {
  test_dirs <- c(
    file.path(abs_path, "inst", "tests"),
    file.path(abs_path, "tests", "testthat")
  )
  any(dir.exists(test_dirs)) && requireNamespace("testthat", quietly = TRUE)
}

.loadfast.source_helpers <- function(abs_path, pkg_env, helpers, attach_testthat, pkg_name) {
  uses_testthat <- .loadfast.uses_testthat(abs_path)
  if (is.null(attach_testthat)) attach_testthat <- uses_testthat
  .loadfast.attach_testthat(attach_testthat, pkg_name)
  if (isTRUE(helpers) && uses_testthat) {
    .loadfast.do_source_helpers(abs_path, pkg_env)
  }
}

.loadfast.do_source_helpers <- function(abs_path, pkg_env) {
  test_dir <- file.path(abs_path, "tests", "testthat")
  if (!dir.exists(test_dir)) {
    test_dir <- file.path(abs_path, "inst", "tests")
  }

  if (dir.exists(test_dir)) {
    old_not_cran <- Sys.getenv("NOT_CRAN", unset = NA)
    Sys.setenv(NOT_CRAN = "true")
    on.exit({
      if (is.na(old_not_cran)) Sys.unsetenv("NOT_CRAN") else Sys.setenv(NOT_CRAN = old_not_cran)
    }, add = TRUE)
    testthat::source_test_helpers(test_dir, env = pkg_env)
  }
}

.loadfast.find_package_root <- function(path = ".") {
  current <- normalizePath(path, mustWork = TRUE)

  if (file.exists(current) && !dir.exists(current)) {
    current <- dirname(current)
  }

  repeat {
    if (file.exists(file.path(current, "DESCRIPTION")) &&
        file.exists(file.path(current, "NAMESPACE")) &&
        dir.exists(file.path(current, "R"))) {
      return(normalizePath(current, mustWork = TRUE))
    }

    parent <- dirname(current)
    if (identical(parent, current)) {
      stop("Could not find package root from path: ", path, call. = FALSE)
    }
    current <- parent
  }
}
