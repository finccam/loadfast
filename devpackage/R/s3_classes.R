# S3 classes, generics, and methods for testing loadfast's S3 support.
#
# These exercise the dispatch cases that only work when the namespace S3 methods
# table is populated from the S3method() directives in NAMESPACE: methods on a
# base generic (print/format/as.character) and methods on a generic defined in
# this package (describe_s3). None of the methods are exported by name, so
# dispatch cannot fall back to the search path — it must go through the table.

new_temperature <- function(celsius) {
  structure(list(celsius = celsius), class = "temperature")
}

# Method on the base `print` generic; registered via S3method(print, temperature).
print.temperature <- function(x, ...) {
  cat("Temperature:", x$celsius, "C\n")
  invisible(x)
}

# Method on the base `format` generic.
format.temperature <- function(x, ...) {
  paste0(x$celsius, " C")
}

# Method on the base `as.character` generic; delegates to format() to also
# exercise dispatch from inside another method.
as.character.temperature <- function(x, ...) {
  format(x)
}

# A generic defined in this package plus its methods.
describe_s3 <- function(x, ...) {
  UseMethod("describe_s3")
}

describe_s3.default <- function(x, ...) {
  "an unknown object"
}

describe_s3.temperature <- function(x, ...) {
  paste0("a temperature of ", x$celsius, " degrees Celsius")
}
