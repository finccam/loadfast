# S4 dummy classes, generics, and methods for testing loadfast (project2)
# Changes from project1:
# - Animal gains an "age" slot
# - Pet gains a "nickname" slot
# - describe() output changes for both classes
# - greet() output changes for Pet
# - new generic: speak()

# --- Class: Animal (now with age) ---
setClass("Animal", representation(
  name    = "character",
  species = "character",
  legs    = "numeric",
  age     = "numeric"
))

# --- Class: Pet (extends Animal, now with nickname) ---
setClass("Pet", contains = "Animal", representation(
  owner    = "character",
  nickname = "character"
))

# --- Generic: describe ---
setGeneric("describe", function(object, ...) {
  standardGeneric("describe")
})

# --- Generic: greet ---
setGeneric("greet", function(object) {
  standardGeneric("greet")
})

# --- Generic: speak (new in project2) ---
setGeneric("speak", function(object) {
  standardGeneric("speak")
})

# --- Method: describe for Animal (changed output) ---
setMethod("describe", "Animal", function(object, ...) {
  paste0(object@name, " is a ", object@species, ", age ", object@age, ", with ", object@legs, " legs")
})

# --- Method: describe for Pet (changed output) ---
setMethod("describe", "Pet", function(object, ...) {
  base_desc <- callNextMethod()
  paste0(base_desc, ", nicknamed ", object@nickname, ", owned by ", object@owner)
})

# --- Method: greet for Pet (changed output) ---
setMethod("greet", "Pet", function(object) {
  paste0("Hi! I'm ", object@nickname, " (", object@name, ") and ", object@owner, " takes care of me")
})

# --- Method: speak for Animal ---
setMethod("speak", "Animal", function(object) {
  paste0(object@name, " says hello")
})

# --- Method: speak for Pet (override) ---
setMethod("speak", "Pet", function(object) {
  paste0(object@nickname, " says hello to ", object@owner)
})

# --- Convenience constructors (updated signatures) ---
animal <- function(name, species, legs, age) {
  new("Animal", name = name, species = species, legs = legs, age = age)
}

pet <- function(name, species, legs, age, owner, nickname) {
  new("Pet", name = name, species = species, legs = legs, age = age,
      owner = owner, nickname = nickname)
}