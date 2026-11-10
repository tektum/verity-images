#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

r() {
  docker run --rm --network none --read-only --tmpfs /tmp "$image" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["/usr/bin/R"]' ||
  fail 'unexpected command'

r R --version | grep -E '^R version 4\.6\.[0-9]+' >/dev/null || fail 'R --version does not report 4.6'
r Rscript --version 2>&1 | grep -E 'Rscript \(R\) version 4\.6\.' >/dev/null ||
  fail 'Rscript --version does not report 4.6'

test "$(r Rscript -e 'cat(1+1)')" = 2 || fail 'Rscript arithmetic failed'
r Rscript -e 'library(stats); library(utils); library(methods); cat("ok")' | grep -Fx ok >/dev/null ||
  fail 'base packages failed to load'

# Statistics through the bundled BLAS/LAPACK and a data round trip through a CSV file.
out=$(r Rscript -e '
set.seed(1)
x <- 1:100
y <- 3 * x + 2
fit <- lm(y ~ x)
f <- tempfile(fileext = ".csv")
write.csv(data.frame(x = x, y = y), f, row.names = FALSE)
d <- read.csv(f)
cat(sprintf("slope=%.3f rows=%d", coef(fit)[["x"]], nrow(d)))
') || fail 'statistics script failed'
test "$out" = 'slope=3.000 rows=100' || fail "unexpected statistics output: $out"

# UTF-8 handling.
test "$(r Rscript -e 'cat(nchar("h\u00e9llo"))')" = 5 || fail 'UTF-8 string length is wrong'

# Negative: an R error must exit non-zero and say why.
if r Rscript -e 'stop("smoke failure")' >/dev/null 2>&1; then
  fail 'failing R script unexpectedly exited zero'
fi
r Rscript -e 'stop("smoke failure")' 2>&1 | grep -F 'smoke failure' >/dev/null ||
  fail 'R error message is not readable'

printf 'SMOKE PASS image=%s\n' "$image"
