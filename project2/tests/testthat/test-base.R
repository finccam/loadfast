test_that("add() sums with offset", {
  expect_equal(add(2, 3), 105)
  expect_equal(add(-1, 1), 100)
  expect_equal(add(0, 0), 100)
})

test_that("scale_vector() centers then scales", {
  expect_equal(scale_vector(c(1, 3), factor = 1), c(-1, 1))
  expect_equal(scale_vector(c(10, 20, 30), factor = 2), c(-20, 0, 20))
})

test_that("summarize_values() now includes range", {
  s <- summarize_values(c(2, 4, 6))
  expect_equal(s$mean, 4)
  expect_equal(s$n, 3)
  expect_true(is.numeric(s$sd))
  expect_equal(s$range, c(2, 6))
})

test_that("Animal S4 class now has age slot", {
  a <- animal("Rex", "dog", 4, 5)
  expect_s4_class(a, "Animal")
  expect_equal(a@name, "Rex")
  expect_equal(a@age, 5)
})

test_that("Pet S4 class now has nickname slot", {
  p <- pet("Milo", "cat", 4, 3, "Alice", "Meowster")
  expect_s4_class(p, "Pet")
  expect_s4_class(p, "Animal")
  expect_equal(p@nickname, "Meowster")
  expect_equal(p@age, 3)
})

test_that("describe() output changed for both classes", {
  a <- animal("Rex", "dog", 4, 5)
  p <- pet("Milo", "cat", 4, 3, "Alice", "Meowster")
  expect_equal(describe(a), "Rex is a dog, age 5, with 4 legs")
  expect_equal(describe(p), "Milo is a cat, age 3, with 4 legs, nicknamed Meowster, owned by Alice")
})

test_that("speak() generic is new in project2", {
  a <- animal("Rex", "dog", 4, 5)
  p <- pet("Milo", "cat", 4, 3, "Alice", "Meowster")
  expect_equal(speak(a), "Rex says hello")
  expect_equal(speak(p), "Meowster says hello to Alice")
})

test_that("Logger R6 class now prefixes entries with level", {
  lg <- Logger$new("WARN")
  lg$log("problem")
  expect_equal(lg$last(), "[WARN] problem")
  expect_equal(lg$level, "WARN")
})

test_that("Logger$format_entries() is new in project2", {
  lg <- Logger$new("INFO")
  lg$log("a")
  lg$log("b")
  expect_equal(lg$format_entries(), "[INFO] a\n[INFO] b")
})

test_that("Counter R6 class now has decrement", {
  ctr <- Counter$new(10L)
  ctr$decrement(by = 3L)
  expect_equal(ctr$value, 7L)
})

test_that("helper make_test_animal() returns updated Animal", {
  a <- make_test_animal()
  expect_s4_class(a, "Animal")
  expect_equal(a@name, "TestAnimal2")
  expect_equal(a@age, 2)
})

test_that("helper make_test_logger() uses DEBUG level", {
  lg <- make_test_logger()
  expect_equal(lg$level, "DEBUG")
  expect_equal(lg$size(), 1L)
  expect_equal(lg$last(), "[DEBUG] init")
})