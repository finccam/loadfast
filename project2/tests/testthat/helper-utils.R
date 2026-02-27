make_test_animal <- function() animal("TestAnimal2", "test_species2", 6, 2)

make_test_logger <- function() {
  lg <- Logger$new("DEBUG")
  lg$log("init")
  lg
}