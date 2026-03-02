test_that("add() sums two numbers", {
  expect_equal(add(2, 3), 5)
  expect_equal(add(-1, 1), 0)
  expect_equal(add(0, 0), 0)
})

test_that("scale_vector() multiplies by factor", {
  expect_equal(scale_vector(1:3, factor = 2), c(2, 4, 6))
  expect_equal(scale_vector(c(10, 20), factor = 0.5), c(5, 10))
  expect_equal(scale_vector(5, factor = 1), 5)
})

test_that("summarize_values() returns mean, sd, n", {
  s <- summarize_values(c(2, 4, 6))
  expect_equal(s$mean, 4)
  expect_equal(s$n, 3)
  expect_true(is.numeric(s$sd))
  expect_null(s$range)
})

test_that("Animal S4 class works", {
  a <- animal("Rex", "dog", 4)
  expect_s4_class(a, "Animal")
  expect_equal(a@name, "Rex")
  expect_equal(a@species, "dog")
  expect_equal(a@legs, 4)
})

test_that("Pet S4 class extends Animal", {
  p <- pet("Milo", "cat", 4, "Alice")
  expect_s4_class(p, "Pet")
  expect_s4_class(p, "Animal")
  expect_equal(p@owner, "Alice")
})

test_that("describe() dispatches correctly", {
  a <- animal("Rex", "dog", 4)
  p <- pet("Milo", "cat", 4, "Alice")
  expect_equal(describe(a), "Rex is a dog with 4 legs")
  expect_equal(describe(p), "Milo is a cat with 4 legs, owned by Alice")
})

test_that("greet() works on Pet", {
  p <- pet("Milo", "cat", 4, "Alice")
  expect_equal(greet(p), "Hello! My name is Milo and I belong to Alice")
})

test_that("Logger R6 class works", {
  lg <- Logger$new()
  expect_equal(lg$size(), 0L)
  expect_identical(lg$last(), NA_character_)

  lg$log("hello")
  lg$log("world")
  expect_equal(lg$size(), 2L)
  expect_equal(lg$last(), "world")
  expect_equal(lg$entries, c("hello", "world"))
})

test_that("Counter R6 class works", {
  ctr <- Counter$new()
  expect_equal(ctr$value, 0L)

  ctr$increment()
  ctr$increment(by = 5L)
  expect_equal(ctr$value, 6L)

  ctr$reset()
  expect_equal(ctr$value, 0L)
})

test_that("Counter does not have decrement yet", {
  ctr <- Counter$new()
  expect_null(ctr$decrement)
})

test_that("helper make_test_animal() builds an Animal", {
  a <- make_test_animal()
  expect_s4_class(a, "Animal")
  expect_equal(a@name, "TestAnimal")
})

test_that("helper make_test_logger() builds a Logger with one entry", {
  lg <- make_test_logger()
  expect_equal(lg$size(), 1L)
  expect_equal(lg$last(), "init")
})