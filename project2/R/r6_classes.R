Logger <- R6Class("Logger",
  public = list(
    entries = NULL,
    level = NULL,
    initialize = function(level = "INFO") {
      self$entries <- character(0)
      self$level <- level
    },
    log = function(msg) {
      entry <- paste0("[", self$level, "] ", msg)
      self$entries <- c(self$entries, entry)
      invisible(self)
    },
    last = function() {
      if (length(self$entries) == 0L) return(NA_character_)
      self$entries[length(self$entries)]
    },
    size = function() {
      length(self$entries)
    },
    format_entries = function() {
      paste(self$entries, collapse = "\n")
    }
  )
)

Counter <- R6Class("Counter",
  public = list(
    value = 0L,
    initialize = function(start = 0L) {
      self$value <- start
    },
    increment = function(by = 1L) {
      self$value <- self$value + by
      invisible(self)
    },
    decrement = function(by = 1L) {
      self$value <- self$value - by
      invisible(self)
    },
    reset = function() {
      self$value <- 0L
      invisible(self)
    }
  )
)