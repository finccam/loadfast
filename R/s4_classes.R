# S4 dummy classes, generics, and methods for testing loadfast

# --- Class: Animal ---
setClass("Animal", representation(
  name    = "character",
  species = "character",
  legs    = "numeric"
))

# --- Class: Pet (extends Animal) ---
setClass("Pet", contains = "Animal", representation(
  owner = "character"
))

# --- Generic: describe ---
setGeneric("describe", function(object, ...) {
  standardGeneric("describe")
})

# --- Generic: greet ---
setGeneric("greet", function(object) {
  standardGeneric("greet")
})

# --- Method: describe for Animal ---
setMethod("describe", "Animal", function(object, ...) {
  paste0(object@name, " is a ", object@species, " with ", object@legs, " legs")
})

# --- Method: describe for Pet (overrides Animal) ---
setMethod("describe", "Pet", function(object, ...) {
  base_desc <- callNextMethod()
  paste0(base_desc, ", owned by ", object@owner)
})

# --- Method: greet for Pet ---
setMethod("greet", "Pet", function(object) {
  paste0("Hello! My name is ", object@name, " and I belong to ", object@owner)
})

# --- Convenience constructors ---
animal <- function(name, species, legs) {
  new("Animal", name = name, species = species, legs = legs)
}

pet <- function(name, species, legs, owner) {
  new("Pet", name = name, species = species, legs = legs, owner = owner)
}