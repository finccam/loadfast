# loadfast.R
# Standalone, simplified replacement for devtools::load_all().
# Reads the package name from DESCRIPTION (the "Package:" field).
# Requires: rlang (for namespace registry access)
# Usage: source("loadfast.R"); load_fast()

load_fast <- function(path = ".") {
  # --- Read package name from DESCRIPTION ---
  desc_path <- file.path(path, "DESCRIPTION")
  if (!file.exists(desc_path)) {
    stop("DESCRIPTION file not found at: ", desc_path)
  }
  desc_lines <- readLines(desc_path, warn = FALSE)
  pkg_line <- grep("^Package:\\s*", desc_lines, value = TRUE)
  if (length(pkg_line) == 0L) {
    stop("No 'Package:' field found in DESCRIPTION")
  }
  pkg_name <- trimws(sub("^Package:\\s*", "", pkg_line[1L]))
  if (nchar(pkg_name) == 0L) {
    stop("'Package:' field in DESCRIPTION is empty")
  }

  pkg_env_name <- paste0("package:", pkg_name)
  r_dir <- file.path(path, "R")

  # --- Detach and unregister if already loaded ---
  if (pkg_env_name %in% search()) {
    detach(pkg_env_name, character.only = TRUE, unload = FALSE, force = TRUE)
  }
  if (pkg_name %in% loadedNamespaces()) {
    tryCatch(unloadNamespace(pkg_name), error = function(e) {
      # Force-remove from namespace registry if normal unload fails
      reg <- rlang::ns_registry_env()
      if (exists(pkg_name, envir = reg, inherits = FALSE)) {
        rm(list = pkg_name, envir = reg)
      }
    })
  }

  # --- Discover R source files ---
  if (!dir.exists(r_dir)) {
    stop("Directory does not exist: ", r_dir)
  }

  r_files <- list.files(r_dir, pattern = "\\.[Rr]$", full.names = TRUE)
  r_files <- r_files[order(basename(r_files))]

  if (length(r_files) == 0L) {
    message("No R files found in ", r_dir)
    return(invisible(NULL))
  }

  # --- Create a proper namespace (required for S4 setClass/setMethod) ---
  # We replicate what base::loadNamespace's internal makeNamespace() does,
  # using rlang::ns_registry_env() to register the namespace.

  # 1. Imports environment: parent chain is <imports:pkg> -> <namespace:base>
  impenv <- new.env(parent = .BaseNamespaceEnv, hash = TRUE)
  attr(impenv, "name") <- paste0("imports:", pkg_name)

  # 2. Namespace environment: parent is the imports env
  ns_env <- new.env(parent = impenv, hash = TRUE)
  ns_env$.packageName <- pkg_name

  # 3. Namespace metadata (.__NAMESPACE__.)
  info <- new.env(hash = TRUE, parent = baseenv())
  ns_env[[".__NAMESPACE__."]] <- info
  info[["spec"]] <- c(name = pkg_name, version = "0.0.0")
  setNamespaceInfo(ns_env, "exports", new.env(hash = TRUE, parent = baseenv()))
  setNamespaceInfo(ns_env, "imports", list(base = TRUE))
  setNamespaceInfo(ns_env, "path", normalizePath(path, mustWork = TRUE))
  setNamespaceInfo(ns_env, "dynlibs", NULL)
  setNamespaceInfo(ns_env, "S3methods", matrix(NA_character_, 0L, 4L))
  ns_env[[".__S3MethodsTable__."]] <- new.env(hash = TRUE, parent = baseenv())

  # 4. Register in R's namespace registry so isNamespace() returns TRUE
  reg <- rlang::ns_registry_env()
  reg[[pkg_name]] <- ns_env

  # 5. Tell the methods package about this namespace
  if (isNamespaceLoaded("methods")) {
    methods::setPackageName(pkg_name, ns_env)
  }

  # --- Process NAMESPACE imports ---
  # Parse the NAMESPACE file and load imported symbols into the imports env.
  # This uses base R's parseNamespaceFile and the same import functions
  # (namespaceImport, namespaceImportFrom, etc.) that loadNamespace uses.
  ns_file <- file.path(path, "NAMESPACE")
  if (file.exists(ns_file)) {
    abs_path <- normalizePath(path, mustWork = TRUE)
    nsInfo <- parseNamespaceFile(basename(abs_path), dirname(abs_path),
                                 mustExist = FALSE)

    # import(pkg)              -> whole-namespace import
    # importFrom(pkg, sym ...) -> selective import
    for (i in nsInfo$imports) {
      tryCatch({
        if (is.character(i)) {
          # import(pkg) — import all exports
          namespaceImport(ns_env, loadNamespace(i), from = pkg_name)
        } else if (!is.null(i$except)) {
          # import(pkg, except = ...) — import all except some
          namespaceImport(ns_env, loadNamespace(i[[1L]]), from = pkg_name,
                          except = i$except)
        } else {
          # importFrom(pkg, sym1, sym2, ...)
          namespaceImportFrom(ns_env, loadNamespace(i[[1L]]), i[[2L]],
                              from = pkg_name)
        }
      }, error = function(e) {
        warning("Import failed for ", deparse(i), ": ",
                conditionMessage(e), call. = FALSE)
      })
    }

    # importClassesFrom(pkg, cls1, cls2, ...)
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

    # importMethodsFrom(pkg, meth1, meth2, ...)
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

    # Store the parsed imports in namespace metadata
    setNamespaceInfo(ns_env, "imports", nsInfo$imports)
  }

  # --- Source all R files into the namespace ---
  old_tle <- getOption("topLevelEnvironment")
  on.exit(options(topLevelEnvironment = old_tle), add = TRUE)
  options(topLevelEnvironment = ns_env)

  # Suppress S4 "no definition for class" notices that occur when setMethod()
  # is sourced before the corresponding setClass() due to alphabetical file
  # ordering. These are harmless: methods still register correctly and work
  # once all files have been sourced. Installed packages never hit this because
  # they load from pre-compiled lazy-load databases.
  # NOTE: depending on R version this is emitted as a message() or warning(),
  # so we must handle both.
  s4_pattern <- "no definition for class"

  for (f in r_files) {
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

  # --- Attach to search path so objects are visible ---
  pkg_env <- attach(NULL, name = pkg_env_name)

  # Copy everything from the namespace into the attached package env
  nms <- ls(ns_env, all.names = FALSE)
  for (nm in nms) {
    assign(nm, get(nm, envir = ns_env), envir = pkg_env)
  }

  message("Loaded ", length(r_files), " file(s) from ", r_dir)
  invisible(ns_env)
}
