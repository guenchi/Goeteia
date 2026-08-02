#!/bin/sh
# Regenerate counter-embedded.html by running the site-generator
# program: the page's interactive part compiles inside its
# (conjure auto ...) mount point at generation time.
set -e
cd "$(dirname "$0")/.."
./bin/goeteiac examples/counter-page.ss /tmp/counter-page.wasm
node rt/run.mjs /tmp/counter-page.wasm > examples/counter-embedded.html
rm -f /tmp/counter-page.wasm
echo "examples/counter-embedded.html regenerated"
