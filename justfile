default:
    @just --list

# run the behavioral test harness
test:
    Rscript test_loadfast.R

# regenerate NAMESPACE and man/ from roxygen comments
document:
    Rscript -e 'roxygen2::roxygenize(".")'

# build the package tarball and run R CMD check on it
check:
    R CMD build .
    R CMD check --no-manual --as-cran loadfast_*.tar.gz

# clone reference packages
setup:
    git clone https://github.com/r-lib/pkgload
    git clone https://github.com/r-lib/devtools
