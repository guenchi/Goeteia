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
#   * NOT the Node-only tools (compile, run, runjs, dev, pack, verify,
#     repl): they import node:fs and friends, and a browser importing
#     them fails at load, so publishing them here would only mislead.
# Every file gets a SHA-256 in SHA256SUMS and an SRI hash in
# manifest.json, so a page can pin what it loads.  The version is a
# directory, never overwritten: a URL under cdn/<version>/ means the
# same bytes forever, which is what lets _headers mark it immutable.
set -eu
SRC=${1:?goeteia source tree}
VER=${2:?version}
ESBUILD=esbuild@0.24.0
OUT="$(cd "$(dirname "$0")" && pwd)/cdn/$VER"
[ -e "$OUT" ] && { echo "cdn/$VER already exists; a published version is never rebuilt in place" >&2; exit 1; }
mkdir -p "$OUT"
for f in web jsbridge worker sexpr react; do
  npx --yes "$ESBUILD" "$SRC/rt/$f.mjs" --minify --format=esm --target=es2022 \
      --legal-comments=none --outfile="$OUT/$f.mjs" 2>&1 | grep -v '^$' || true
done
cp "$SRC/goeteia.wasm" "$OUT/goeteia.wasm"
( cd "$OUT" && shasum -a 256 *.mjs goeteia.wasm > SHA256SUMS )
# manifest: name, bytes, sha256, sri (sha384, base64) -- generated, not typed
( cd "$OUT" && {
  echo '{'
  echo "  \"version\": \"$VER\","
  echo "  \"source\": \"$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)\","
  echo '  "files": {'
  first=1
  for f in *.mjs goeteia.wasm; do
    [ $first = 1 ] || echo ','
    first=0
    printf '    "%s": {"bytes": %s, "sha256": "%s", "integrity": "sha384-%s"}' \
      "$f" "$(wc -c < "$f" | tr -d ' ')" \
      "$(shasum -a 256 "$f" | cut -c1-64)" \
      "$(openssl dgst -sha384 -binary "$f" | openssl base64 -A)"
  done
  echo; echo '  }'; echo '}'
} > manifest.json )
echo "built cdn/$VER:"; ( cd "$OUT" && ls -l | awk 'NR>1{printf "  %8s  %s\n",$5,$9}' )
