make_test_animal <- function() animal("TestAnimal", "test_species", 2)

make_test_logger <- function() {
  lg <- Logger$new()
  lg$log("init")
  lg
}