#!/bin/sh
# Build goeteia.dev/cdn/<version>/ from a goeteia source tree.
#
#   sh build-cdn.sh <goeteia-tree> <version>
#   e.g.  sh build-cdn.sh ../03-goeteia 1.5.8
#
# What goes in, and why only that:
#   * the browser-runnable half of rt/ -- web.mjs, jsbridge.mjs,
#     worker.mjs, sexpr.mjs, react.mjs -- minified one file at a time so
#     the relative imports between them (and web.mjs's
#     `new URL('./worker.mjs', import.meta.url)`) keep resolving inside
#     this directory.  Bundling would break the worker URL.
#   * goeteia.wasm, the self-hosted compiler snapshot, copied as is: wasm
#     is already binary and the edge compresses it in transit.
#   * src/prelude.ss and every lib/**.ss, verbatim: a page that compiles
#     Scheme in the browser feeds the compiler the prelude and the
#     libraries as TEXT, and those must be the same version as the
#     compiler -- a 1.5.8 compiler over a 1.5.7 prelude is a mismatch
#     nothing reports.  Publishing them beside the compiler makes one
#     URL prefix name one consistent version of all three.
#   * NOT the Node-only tools (compile, run, runjs, dev, pack, verify,
#     repl): they import node:fs and friends, and a browser importing
#     them fails at load, so publishing them here would only mislead.
#
# A published byte never changes.  If cdn/<version>/ already exists,
# every file this script would write there is compared against what is
# published: identical bytes are left alone, a differing artifact
# aborts the run, and only files that did not exist yet are added.
# SHA256SUMS and manifest.json are indexes over the directory and are
# regenerated to cover the additions -- they are the one thing here
# that may change, and a reader pinning bytes should pin the artifact's
# hash, not the index.
set -eu
SRC=${1:?goeteia source tree}
VER=${2:?version}
ESBUILD=esbuild@0.24.0
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/cdn/$VER"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/goeteia-cdn.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"
for f in web jsbridge worker sexpr react; do
  npx --yes "$ESBUILD" "$SRC/rt/$f.mjs" --minify --format=esm --target=es2022 \
      --legal-comments=none --outfile="$STAGE/$f.mjs" 2>&1 | grep -v '^$' || true
done
cp "$SRC/goeteia.wasm" "$STAGE/goeteia.wasm"
mkdir -p "$STAGE/src"; cp "$SRC/src/prelude.ss" "$STAGE/src/prelude.ss"
( cd "$SRC" && find lib -name '*.ss' -type f ) | while read -r f; do
  mkdir -p "$STAGE/$(dirname "$f")"; cp "$SRC/$f" "$STAGE/$f"
done
# reconcile with what is already published: never change a byte
added=0; kept=0
( cd "$STAGE" && find . -type f | sed 's|^\./||' ) | sort > "$STAGE.list"
while read -r f; do
  if [ -f "$OUT/$f" ]; then
    if cmp -s "$STAGE/$f" "$OUT/$f"; then kept=$((kept+1)); else
      echo "REFUSED: cdn/$VER/$f is published with different bytes; a version is never rebuilt in place" >&2; exit 1; fi
  else
    mkdir -p "$OUT/$(dirname "$f")"; cp "$STAGE/$f" "$OUT/$f"; added=$((added+1))
  fi
done < "$STAGE.list"
rm -f "$STAGE.list"
# indexes, generated over everything now published
( cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name manifest.json | sed 's|^\./||' | sort | xargs shasum -a 256 > SHA256SUMS )
( cd "$OUT" && {
  echo '{'
  echo "  \"version\": \"$VER\","
  echo "  \"source\": \"$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)\","
  echo '  "files": {'
  first=1
  find . -type f ! -name SHA256SUMS ! -name manifest.json | sed 's|^\./||' | sort | while read -r f; do
    [ "$first" = 1 ] || echo ','
    first=0
    printf '    "%s": {"bytes": %s, "sha256": "%s", "integrity": "sha384-%s"}' \
      "$f" "$(wc -c < "$f" | tr -d ' ')" \
      "$(shasum -a 256 "$f" | cut -c1-64)" \
      "$(openssl dgst -sha384 -binary "$f" | openssl base64 -A)"
  done
  echo; echo '  }'; echo '}'
} > manifest.json )
echo "cdn/$VER: $kept unchanged, $added added; $(grep -c . "$OUT/SHA256SUMS") files indexed"
