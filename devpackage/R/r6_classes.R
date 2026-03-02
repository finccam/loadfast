Logger <- R6Class("Logger",
  public = list(
    entries = NULL,
    initialize = function() {
      self$entries <- character(0)
    },
    log = function(msg) {
      self$entries <- c(self$entries, msg)
      invisible(self)
    },
    last = function() {
      if (length(self$entries) == 0L) return(NA_character_)
      self$entries[length(self$entries)]
    },
    size = function() {
      length(self$entries)
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
    reset = function() {
      self$value <- 0L
      invisible(self)
    }
  )
)