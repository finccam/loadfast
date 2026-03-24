default:
    @just --list

test:
    Rscript test_loadfast.R

# clone reference packages
setup:
    git clone https://github.com/r-lib/pkgload
    git clone https://github.com/r-lib/devtools
