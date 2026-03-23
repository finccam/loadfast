default:
    @just --list

test:
    Rscript test_loadfast.R
    Rscript test_loadfast_v1.R

test-loadfast:
    Rscript test_loadfast.R

test-loadfast-v1:
    Rscript test_loadfast_v1.R
