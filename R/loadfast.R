message("Incremental reload is available via load_fast().")

.loadfast.cache <- new.env(parent = emptyenv())
.loadfast.state <- new.env(parent = emptyenv())
.loadfast.state$loading <- FALSE

#' Load a package from source with MD5-based incremental reloading
#'
#' `load_fast()` is a lightweight alternative to `devtools::load_all()`.
#' On the first call for a package path it performs a full teardown and rebuild.
#' On subsequent calls for that same path it re-sources only `R/` files whose
#' MD5 hashes changed.
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
#' @return Invisibly returns the namespace environment.
#' @export
load_fast <- function(path = ".", helpers = TRUE, attach_testthat = NULL, full = FALSE, verbose = FALSE) {
  if (.loadfast.state$loading) stop("load_fast() re-entrance detected — a sourced file is calling load_fast()")
  .loadfast.state$loading <- TRUE
  on.exit(.loadfast.state$loading <- FALSE, add = TRUE)

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
  pkg_name <- if ("Package" %in% colnames(desc_fields)) trimws(desc_fields[1L, "Package"]) else ""
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

  can_incremental <- !is.null(cached) &&
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
    files_to_source <- files_to_source[order(basename(files_to_source), files_to_source)]

    if (length(files_to_source) == 0L) {
      if (!is.null(pending_reload_message)) {
        message(pending_reload_message)
      }
      .loadfast.cache[[abs_path]] <- list(
        ns_env = ns_env,
        pkg_name = pkg_name,
        hashes = current_hashes,
        lock_hash = old_lock_hash,
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

    list2env(as.list(ns_env, all.names = FALSE), envir = pkg_env)
    list2env(as.list(parent.env(ns_env), all.names = TRUE), envir = pkg_env)
    .timer("incr pkg_env sync")

    .loadfast.cache[[abs_path]] <- list(
      ns_env = ns_env,
      pkg_name = pkg_name,
      hashes = current_hashes,
      lock_hash = old_lock_hash,
      registered_reload_files = character(0),
      pending_reload_message = NULL
    )

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

  if (file.exists(ns_file)) {
    exports <- nsInfo$exports
    if (length(exports) > 0L) {
      namespaceExport(ns_env, exports)
    }
  }

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
    pkg_name = pkg_name,
    hashes = current_hashes,
    lock_hash = current_lock_hash,
    registered_reload_files = character(0),
    pending_reload_message = NULL
  )

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
