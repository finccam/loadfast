# loadfast.R
# Standalone replacement for devtools::load_all() with MD5-based incremental
# reloading. On first call does a full teardown+rebuild; on subsequent calls
# for the same path re-sources only files whose MD5 hash changed.
# Requires: rlang (for namespace registry access)
# Usage: source("loadfast.R"); load_fast()

message("Attach load_fast")

.loadfast_file_cache <- new.env(parent = emptyenv())
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

  desc_path <- file.path(abs_path, "DESCRIPTION")
  if (!file.exists(desc_path)) stop("DESCRIPTION file not found at: ", desc_path)
  desc_lines <- readLines(desc_path, warn = FALSE)
  pkg_line <- grep("^Package:\\s*", desc_lines, value = TRUE)
  if (length(pkg_line) == 0L) stop("No 'Package:' field found in DESCRIPTION")
  pkg_name <- trimws(sub("^Package:\\s*", "", pkg_line[1L]))
  if (nchar(pkg_name) == 0L) stop("'Package:' field in DESCRIPTION is empty")

  pkg_env_name <- paste0("package:", pkg_name)
  r_dir <- file.path(abs_path, "R")
  if (!dir.exists(r_dir)) stop("Directory does not exist: ", r_dir)

  r_files <- list.files(r_dir, pattern = "\\.[Rr]$", full.names = TRUE)
  r_files <- r_files[order(basename(r_files))]
  if (length(r_files) == 0L) {
    message("No R files found in ", r_dir)
    return(invisible(NULL))
  }

  current_hashes <- tools::md5sum(r_files)
  names(current_hashes) <- r_files
  .timer("desc + file discovery + md5")

  cached <- NULL
  if (!isTRUE(full) && exists(abs_path, envir = .loadfast_file_cache, inherits = FALSE)) {
    cached <- .loadfast_file_cache[[abs_path]]
  }

  can_incremental <- !is.null(cached) &&
    pkg_name %in% loadedNamespaces() &&
    pkg_env_name %in% search()

  if (can_incremental) {
    ns_env <- cached$ns_env
    pkg_env <- as.environment(pkg_env_name)
    old_hashes <- cached$hashes

    old_files <- names(old_hashes)
    new_files <- names(current_hashes)
    added_files <- setdiff(new_files, old_files)
    common_files <- intersect(new_files, old_files)
    changed_files <- common_files[current_hashes[common_files] != old_hashes[common_files]]

    files_to_source <- c(changed_files, added_files)
    files_to_source <- files_to_source[order(basename(files_to_source))]

    if (length(files_to_source) == 0L) {
      message("No changes in ", r_dir)
      .source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
      .timer("TOTAL (no-change)")
      return(invisible(ns_env))
    }

    old_tle <- getOption("topLevelEnvironment")
    on.exit(options(topLevelEnvironment = old_tle), add = TRUE)
    options(topLevelEnvironment = ns_env)

    for (f in files_to_source) {
      .source_one(f, ns_env)
    }
    .timer(paste0("incr source ", length(files_to_source), " files"))

    list2env(as.list(ns_env, all.names = FALSE), envir = pkg_env)
    list2env(as.list(parent.env(ns_env), all.names = TRUE), envir = pkg_env)
    .timer("incr pkg_env sync")

    .loadfast_file_cache[[abs_path]] <- list(ns_env = ns_env, hashes = current_hashes)

    n_changed <- length(changed_files)
    n_added <- length(added_files)
    parts <- character()
    if (n_changed > 0L) parts <- c(parts, paste0(n_changed, " changed"))
    if (n_added > 0L) parts <- c(parts, paste0(n_added, " added"))
    message("Incremental reload: ", paste(parts, collapse = ", "))

    .source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
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
    .source_one(f, ns_env)
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
    .do_source_helpers(abs_path, pkg_env)
  }
  .timer("source testthat helpers")

  .loadfast_file_cache[[abs_path]] <- list(ns_env = ns_env, hashes = current_hashes)

  message("Load ", length(r_files), " file(s) from ", r_dir)
  .timer("TOTAL (full load)")
  invisible(ns_env)
}

.source_one <- function(f, ns_env) {
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
      warning("Failed to source ", f, ": ", conditionMessage(e), call. = FALSE)
    }
  )
}

.source_helpers <- function(abs_path, pkg_env, helpers, attach_testthat, pkg_name) {
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
    .do_source_helpers(abs_path, pkg_env)
  }
}

.do_source_helpers <- function(abs_path, pkg_env) {
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
