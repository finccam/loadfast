# Standalone replacement for devtools::load_all() with MD5-based incremental
# reloading. On first call does a full teardown+rebuild; on subsequent calls
# for the same path re-sources only files whose MD5 hash changed.
# Source of truth lives at https://github.com/finccam-com/loadfast/
# This file is intended to be copied into every repo that uses it.
# Make changes in that upstream repo, then copy the updated file down.
# Requires: rlang (for namespace registry access)
# Usage: source("loadfast.R"); load_fast()

message("Incremental reload is available via load_fast().")

.loadfast.cache <- new.env(parent = emptyenv())
.loadfast_loading <- FALSE

load_fast <- function(path = ".", helpers = TRUE, attach_testthat = NULL, full = FALSE, verbose = FALSE) {
  if (.loadfast_loading) stop("load_fast() re-entrance detected — a sourced file is calling load_fast()")
  .loadfast_loading <<- TRUE
  on.exit(.loadfast_loading <<- FALSE, add = TRUE)

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

  abs_path <- normalizePath(path, mustWork = TRUE)
  path_display <- if (identical(path, ".")) {
    basename(abs_path)
  } else if (grepl("^(?:[A-Za-z]:[/\\\\]|[/\\\\])", path)) {
    basename(abs_path)
  } else {
    path
  }
  r_dir_display <- file.path(path_display, "R")

  desc_path <- file.path(abs_path, "DESCRIPTION")
  if (!file.exists(desc_path)) stop("DESCRIPTION file not found at: ", desc_path)
  desc_lines <- readLines(desc_path, warn = FALSE)
  pkg_line <- grep("^Package:\\s*", desc_lines, value = TRUE)
  if (length(pkg_line) == 0L) stop("No 'Package:' field found in DESCRIPTION")
  pkg_name <- trimws(sub("^Package:\\s*", "", pkg_line[1L]))
  if (nchar(pkg_name) == 0L) stop("'Package:' field in DESCRIPTION is empty")

  pkg_env_name <- paste0("package:", pkg_name)
  r_dir <- file.path(abs_path, "R")
  if (!dir.exists(r_dir)) stop("Directory does not exist: ", r_dir_display)

  r_files <- list.files(r_dir, pattern = "\\.[Rr]$", full.names = TRUE)
  r_files <- r_files[order(basename(r_files))]
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

  can_incremental <- !is.null(cached) &&
    pkg_name %in% loadedNamespaces() &&
    pkg_env_name %in% search()

  if (can_incremental) {
    ns_env <- cached$ns_env
    pkg_env <- as.environment(pkg_env_name)
    old_hashes <- cached$hashes
    old_lock_hash <- if (is.null(cached$lock_hash)) NA_character_ else cached$lock_hash
    invalidated_files <- if (is.null(cached$invalidated_files)) character(0) else cached$invalidated_files
    pending_invalidation_message <- if (is.null(cached$pending_invalidation_message)) NULL else cached$pending_invalidation_message

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
    invalidated_files_cmp <- chartr("\\", "/", invalidated_files)

    invalidated_existing_files <- new_files[new_files_cmp %in% intersect(new_files_cmp, invalidated_files_cmp)]
    invalidated_added_files <- setdiff(invalidated_files_cmp, old_files_cmp)
    invalidated_added_files <- new_files[new_files_cmp %in% intersect(new_files_cmp, invalidated_added_files)]

    files_to_source <- unique(c(changed_files, added_files, invalidated_existing_files, invalidated_added_files))
    files_to_source <- files_to_source[order(basename(files_to_source), files_to_source)]

    if (length(files_to_source) == 0L) {
      if (!is.null(pending_invalidation_message)) {
        message(pending_invalidation_message)
      }
      .loadfast.cache[[abs_path]] <- list(
        ns_env = ns_env,
        hashes = current_hashes,
        lock_hash = old_lock_hash,
        invalidated_files = character(0),
        pending_invalidation_message = NULL
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

    list2env(as.list(ns_env, all.names = FALSE), envir = pkg_env)
    list2env(as.list(parent.env(ns_env), all.names = TRUE), envir = pkg_env)
    .timer("incr pkg_env sync")

    .loadfast.cache[[abs_path]] <- list(
      ns_env = ns_env,
      hashes = current_hashes,
      lock_hash = old_lock_hash,
      invalidated_files = character(0),
      pending_invalidation_message = NULL
    )

    n_changed <- length(changed_files)
    n_added <- length(added_files)
    n_invalidated <- length(unique(c(invalidated_existing_files, invalidated_added_files)))
    parts <- character()
    if (n_changed > 0L) parts <- c(parts, paste0(n_changed, " changed"))
    if (n_added > 0L) parts <- c(parts, paste0(n_added, " added"))
    if (n_invalidated > 0L) parts <- c(parts, paste0(n_invalidated, " invalidated"))

    changed_display <- basename(files_to_source)
    if (length(changed_display) > 5L) {
      changed_display <- c(
        changed_display[seq_len(5L)],
        paste0("and ", length(files_to_source) - 5L, " more file(s)")
      )
    }

    if (!is.null(pending_invalidation_message)) {
      message(pending_invalidation_message)
    }

    message(
      "Incremental reload: ",
      paste(parts, collapse = ", "),
      " [",
      paste(changed_display, collapse = ", "),
      "]"
    )

    .loadfast.source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
    .timer("TOTAL (incremental)")
    return(invisible(ns_env))
  }

  # ---- FULL LOAD ----

  if (pkg_env_name %in% search()) {
    detach(pkg_env_name, character.only = TRUE, unload = FALSE, force = TRUE)
  }
  if (pkg_name %in% loadedNamespaces()) {
    tryCatch(unloadNamespace(pkg_name), error = function(e) {
      reg <- rlang::ns_registry_env()
      if (exists(pkg_name, envir = reg, inherits = FALSE)) {
        rm(list = pkg_name, envir = reg)
      }
    })
  }
  .timer("detach + unload old ns")

  impenv <- new.env(parent = .BaseNamespaceEnv, hash = TRUE)
  attr(impenv, "name") <- paste0("imports:", pkg_name)

  ns_env <- new.env(parent = impenv, hash = TRUE)
  ns_env$.packageName <- pkg_name

  info <- new.env(hash = TRUE, parent = baseenv())
  ns_env[[".__NAMESPACE__."]] <- info
  info[["spec"]] <- c(name = pkg_name, version = "0.0.0")
  setNamespaceInfo(ns_env, "exports", new.env(hash = TRUE, parent = baseenv()))
  setNamespaceInfo(ns_env, "imports", list(base = TRUE))
  setNamespaceInfo(ns_env, "path", abs_path)
  setNamespaceInfo(ns_env, "dynlibs", NULL)
  setNamespaceInfo(ns_env, "S3methods", matrix(NA_character_, 0L, 4L))
  ns_env[[".__S3MethodsTable__."]] <- new.env(hash = TRUE, parent = baseenv())

  reg <- rlang::ns_registry_env()
  reg[[pkg_name]] <- ns_env

  if (isNamespaceLoaded("methods")) {
    methods::setPackageName(pkg_name, ns_env)
  }
  .timer("create + register ns env")

  ns_file <- file.path(abs_path, "NAMESPACE")
  if (file.exists(ns_file)) {
    nsInfo <- parseNamespaceFile(
      basename(abs_path),
      dirname(abs_path),
      mustExist = FALSE
    )
    .timer("parseNamespaceFile")

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
          warning(
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
          warning(
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
          warning(
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

  uses_testthat <- local({
    test_dirs <- c(
      file.path(abs_path, "inst", "tests"),
      file.path(abs_path, "tests", "testthat")
    )
    any(dir.exists(test_dirs)) && requireNamespace("testthat", quietly = TRUE)
  })
  if (is.null(attach_testthat)) attach_testthat <- uses_testthat
  if (isTRUE(attach_testthat) && pkg_name != "testthat") {
    library("testthat", warn.conflicts = FALSE)
  }
  .timer("attach testthat")

  pkg_env <- attach(NULL, name = pkg_env_name)
  list2env(as.list(ns_env, all.names = FALSE), envir = pkg_env)
  list2env(as.list(impenv, all.names = TRUE), envir = pkg_env)
  .timer("attach pkg to search path")

  if (isTRUE(helpers) && uses_testthat) {
    .loadfast.do_source_helpers(abs_path, pkg_env)
  }
  .timer("source testthat helpers")

  .loadfast.cache[[abs_path]] <- list(
    ns_env = ns_env,
    hashes = current_hashes,
    lock_hash = current_lock_hash,
    invalidated_files = character(0),
    pending_invalidation_message = NULL
  )

  message("Load ", length(r_files), " file(s) from ", r_dir_display, ".")
  .timer("TOTAL (full load)")
  invisible(ns_env)
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

load_fast_invalidate <- function(path = ".", files, reason = NULL) {
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
    message("No active load_fast cache for ", abs_path, "; invalidation ignored")
    return(invisible(FALSE))
  }

  cached <- .loadfast.cache[[abs_path]]
  invalidated_files <- unique(c(cached$invalidated_files, file_paths))
  invalidated_display <- file_inputs[match(invalidated_files, file_paths)]
  invalidated_display <- invalidated_display[!is.na(invalidated_display)]

  message_text <- paste0(
    "Applying requested invalidation: ",
    paste(invalidated_display, collapse = ", "),
    if (is.null(reason) || !nzchar(reason)) "." else paste0(" (", reason, ").")
  )

  cached$invalidated_files <- invalidated_files
  cached$pending_invalidation_message <- message_text
  .loadfast.cache[[abs_path]] <- cached

  invisible(TRUE)
}

.loadfast.source_helpers <- function(abs_path, pkg_env, helpers, attach_testthat, pkg_name) {
  uses_testthat <- local({
    test_dirs <- c(
      file.path(abs_path, "inst", "tests"),
      file.path(abs_path, "tests", "testthat")
    )
    any(dir.exists(test_dirs)) && requireNamespace("testthat", quietly = TRUE)
  })
  if (is.null(attach_testthat)) attach_testthat <- uses_testthat
  if (isTRUE(attach_testthat) && pkg_name != "testthat") {
    if (!paste0("package:testthat") %in% search()) {
      library("testthat", warn.conflicts = FALSE)
    }
  }
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
