.fileCache <- new.env(parent = emptyenv())

load_fast <- function(path = ".", helpers = TRUE, attach_testthat = NULL) {
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

  cached <- NULL
  if (exists(abs_path, envir = .fileCache, inherits = FALSE)) {
    cached <- .fileCache[[abs_path]]
  }

  can_incremental <- !is.null(cached) &&
    pkg_name %in% loadedNamespaces() &&
    pkg_env_name %in% search()

  if (can_incremental) {
    ns_env  <- cached$ns_env
    pkg_env <- as.environment(pkg_env_name)
    old_hashes  <- cached$hashes
    old_symbols <- cached$symbols

    old_files <- names(old_hashes)
    new_files <- names(current_hashes)

    deleted_files <- setdiff(old_files, new_files)
    added_files   <- setdiff(new_files, old_files)
    common_files  <- intersect(new_files, old_files)
    changed_files <- common_files[current_hashes[common_files] != old_hashes[common_files]]

    files_to_source <- c(changed_files, added_files)
    # Keep alphabetical order consistent with full load
    files_to_source <- files_to_source[order(basename(files_to_source))]

    if (length(deleted_files) == 0L && length(files_to_source) == 0L) {
      message("Nothing changed in ", r_dir)
      .source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
      return(invisible(ns_env))
    }

    # Remove symbols contributed by deleted and changed files from ns_env
    symbols_to_remove <- character()
    for (f in c(deleted_files, changed_files)) {
      if (!is.null(old_symbols[[f]])) {
        symbols_to_remove <- c(symbols_to_remove, old_symbols[[f]])
      }
    }
    if (length(symbols_to_remove) > 0L) {
      existing <- intersect(symbols_to_remove, ls(ns_env, all.names = TRUE))
      if (length(existing) > 0L) rm(list = existing, envir = ns_env)
    }

    # Remove deleted files from symbol tracking
    for (f in deleted_files) {
      old_symbols[[f]] <- NULL
    }
    # Clear hashes for deleted files
    old_hashes <- old_hashes[setdiff(names(old_hashes), deleted_files)]

    # Source changed and added files, track new symbols
    new_symbols_all <- character()
    if (length(files_to_source) > 0L) {
      old_tle <- getOption("topLevelEnvironment")
      on.exit(options(topLevelEnvironment = old_tle), add = TRUE)
      options(topLevelEnvironment = ns_env)

      for (f in files_to_source) {
        before <- ls(ns_env, all.names = TRUE)
        .source_one(f, ns_env)
        after <- ls(ns_env, all.names = TRUE)
        syms <- setdiff(after, before)
        # For changed files, also include symbols that were removed and re-defined
        if (f %in% changed_files && !is.null(old_symbols[[f]])) {
          re_added <- intersect(old_symbols[[f]], after)
          syms <- unique(c(syms, re_added))
        }
        old_symbols[[f]] <- syms
        new_symbols_all <- c(new_symbols_all, syms)
      }
    }

    # Update pkg_env: remove stale symbols, copy new/changed ones
    stale <- setdiff(symbols_to_remove, new_symbols_all)
    stale_in_pkg <- intersect(stale, ls(pkg_env, all.names = TRUE))
    if (length(stale_in_pkg) > 0L) rm(list = stale_in_pkg, envir = pkg_env)

    for (nm in unique(new_symbols_all)) {
      if (exists(nm, envir = ns_env, inherits = FALSE)) {
        assign(nm, get(nm, envir = ns_env, inherits = FALSE), envir = pkg_env)
      }
    }

    # Update cache
    updated_hashes <- current_hashes
    .fileCache[[abs_path]] <- list(
      ns_env  = ns_env,
      hashes  = updated_hashes,
      symbols = old_symbols
    )

    n_changed <- length(changed_files)
    n_added   <- length(added_files)
    n_deleted <- length(deleted_files)
    parts <- character()
    if (n_changed > 0L) parts <- c(parts, paste0(n_changed, " changed"))
    if (n_added > 0L)   parts <- c(parts, paste0(n_added, " added"))
    if (n_deleted > 0L)  parts <- c(parts, paste0(n_deleted, " deleted"))
    message("Incremental reload: ", paste(parts, collapse = ", "))

    .source_helpers(abs_path, pkg_env, helpers, attach_testthat, pkg_name)
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

  # --- Create namespace env chain ---
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

  # --- Process NAMESPACE imports ---
  ns_file <- file.path(abs_path, "NAMESPACE")
  if (file.exists(ns_file)) {
    nsInfo <- parseNamespaceFile(basename(abs_path), dirname(abs_path),
                                 mustExist = FALSE)
    for (i in nsInfo$imports) {
      tryCatch({
        if (is.character(i)) {
          namespaceImport(ns_env, loadNamespace(i), from = pkg_name)
        } else if (!is.null(i$except)) {
          namespaceImport(ns_env, loadNamespace(i[[1L]]), from = pkg_name,
                          except = i$except)
        } else {
          namespaceImportFrom(ns_env, loadNamespace(i[[1L]]), i[[2L]],
                              from = pkg_name)
        }
      }, error = function(e) {
        warning("Import failed for ", deparse(i), ": ",
                conditionMessage(e), call. = FALSE)
      })
    }
    for (imp in nsInfo$importClasses) {
      tryCatch(
        namespaceImportClasses(ns_env, loadNamespace(imp[[1L]]), imp[[2L]],
                               from = pkg_name),
        error = function(e) {
          warning("importClassesFrom failed for ", imp[[1L]], ": ",
                  conditionMessage(e), call. = FALSE)
        }
      )
    }
    for (imp in nsInfo$importMethods) {
      tryCatch(
        namespaceImportMethods(ns_env, loadNamespace(imp[[1L]]), imp[[2L]],
                               from = pkg_name),
        error = function(e) {
          warning("importMethodsFrom failed for ", imp[[1L]], ": ",
                  conditionMessage(e), call. = FALSE)
        }
      )
    }
    setNamespaceInfo(ns_env, "imports", nsInfo$imports)
  }

  # --- Source all R files, tracking symbols per file ---
  old_tle <- getOption("topLevelEnvironment")
  on.exit(options(topLevelEnvironment = old_tle), add = TRUE)
  options(topLevelEnvironment = ns_env)

  file_symbols <- list()
  for (f in r_files) {
    before <- ls(ns_env, all.names = TRUE)
    .source_one(f, ns_env)
    after <- ls(ns_env, all.names = TRUE)
    file_symbols[[f]] <- setdiff(after, before)
  }

  # --- Attach testthat ---
  uses_testthat <- local({
    test_dirs <- c(file.path(abs_path, "inst", "tests"),
                   file.path(abs_path, "tests", "testthat"))
    any(dir.exists(test_dirs)) && requireNamespace("testthat", quietly = TRUE)
  })
  if (is.null(attach_testthat)) attach_testthat <- uses_testthat
  if (isTRUE(attach_testthat) && pkg_name != "testthat") {
    library("testthat", warn.conflicts = FALSE)
  }

  # --- Attach to search path ---
  pkg_env <- attach(NULL, name = pkg_env_name)
  nms <- ls(ns_env, all.names = FALSE)
  for (nm in nms) {
    assign(nm, get(nm, envir = ns_env), envir = pkg_env)
  }

  # --- Source testthat helpers ---
  if (isTRUE(helpers) && uses_testthat) {
    .do_source_helpers(abs_path, pkg_env)
  }

  # --- Store cache ---
  .fileCache[[abs_path]] <- list(
    ns_env  = ns_env,
    hashes  = current_hashes,
    symbols = file_symbols
  )

  message("Loaded ", length(r_files), " file(s) from ", r_dir)
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
    test_dirs <- c(file.path(abs_path, "inst", "tests"),
                   file.path(abs_path, "tests", "testthat"))
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
  if (!dir.exists(test_dir)) test_dir <- file.path(abs_path, "inst", "tests")
  if (dir.exists(test_dir)) {
    old_not_cran <- Sys.getenv("NOT_CRAN", unset = NA)
    Sys.setenv(NOT_CRAN = "true")
    on.exit({
      if (is.na(old_not_cran)) Sys.unsetenv("NOT_CRAN") else Sys.setenv(NOT_CRAN = old_not_cran)
    }, add = TRUE)
    testthat::source_test_helpers(test_dir, env = pkg_env)
  }
}