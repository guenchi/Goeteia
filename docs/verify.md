# Verifying a page

```
goeteia verify <page.ss> [--needs draw,interact] [--checks spec.json]
                         [--json] [--out report.json] [--wasm out.wasm]
                         [--script]
```

`goeteia verify` takes one `.ss` whose top level is the browser half of
a page — the shape `docs/llm/core.md` describes — compiles it, runs it
against a mock DOM and a *recording* WebGL context, drives it, and
answers with a structured verdict. Exit status is 0 for a pass, 1 for a
failure, 2 for a usage error, so it composes into a shell loop; `--json`
prints the whole verdict as JSON and nothing else, for callers that want
fields rather than lines.

The point is that it decides. A page can look finished in a screenshot,
read correctly in the source, and still draw nothing, or carry a slider
wired to a handler that ignores it. Those two are what the *draw* and
*interact* stages exist for, and neither is decidable by reading the
program.

## The stages

Four gates, each on the next, and then the spec's own assertions. The
verdict names the first stage that failed in its `stage` field, and
`done` when none did.

**compile** — the self-hosted compiler turns the source into wasm, in a
child process. A failure is parsed into fields rather than dumped:

```json
{ "stage": "compile", "message": "list opened at page.ss line 4 column 3 never closed",
  "file": "…/page.ss", "line": 4, "col": 3, "located": "exact",
  "hint": null, "excerpt": "4 |   (let ((n (create-element \"p\")))\n  |   ^", "fn": null }
```

`located` says how much to trust the position. `exact` is the reader's
own file:line:column. `form` is the enclosing form the compiler was
working on, which is as precise as the loc context gets. `guess` means
the diagnostic named an identifier but no position, and the first place
that identifier occurs in the source was used — a wrong guess you can
see beats no line at all, so it is labelled rather than hidden.

**smoke** — the module instantiates and runs a few animation frames.
The clocks and `Math.random` are stubbed and frames step at a fixed
60 Hz, so a run is a pure function of its bytes and the input it was
given. A wasm trap says four words and names no line, so the verdict
attaches the Scheme-level cause: `illegal cast` becomes a paragraph
about the i31 fixnum range, `unreachable` points at the program's own
stdout, and so on.

**draw** — only when the spec asks. The recorded frames must contain at
least one `drawElements`/`drawArrays` with a non-zero count. The hint
distinguishes the two ways of failing: no GL calls at all (the program
never called `fx-init!`) from a live context that never drew (check the
`fx-loop!` callback and the vertex count).

**interact** — only when the spec asks. Synthesizing user input must
*change* what the page does. This is decided **differentially**: two
runs with identical frame timing, one given the input and one not, are
compared. A picture that merely animates changes between frames all by
itself, and a run compared against itself would call that
interactivity. Before the comparison means anything, two identical
no-input runs are checked to agree byte for byte; if they do not,
something unfrozen is on the render path and the verdict says so rather
than guessing.

Three projections decide "changed", and a check picks one with `by`:

| `by` | what is compared |
|---|---|
| `page` (default) | the frames issued after the input, plus the DOM: structure, attributes, inline style, classes, text |
| `draws` | only the frames — "did the picture change" |
| `text` | only the readable text |

The `value` of a control the harness itself drove is excluded from the
DOM snapshot: that field is the harness's input, not the page's output.

**custom** — the check spec's own assertions, run in order. Every one
appears in the verdict's `checks` array whether it passed or not.

## The check spec

A JSON object. `--checks` takes a path to one, or the object written
out on the command line. `--needs draw,interact` is shorthand for the
two booleans.

```json
{
  "needs_draw": false,
  "needs_interact": false,
  "custom": [
    { "kind": "text_blocks_min", "n": 3 },
    { "kind": "input_changes", "index": 0, "by": "text" }
  ]
}
```

| field | type | meaning |
|---|---|---|
| `needs_draw` | boolean | run the draw stage (default `false`) |
| `needs_interact` | boolean | run the interact stage (default `false`) |
| `custom` | array | assertions, each an object with a `kind` (default `[]`) |

Those three are the whole top-level vocabulary. Any other top-level
key is refused **by name**, with the legal set listed — exit 2 from
the CLI, a throw from `verifyBytes`/`verifyFile` — because a misspelt
requirement silently not enforced is the one answer a verifier must
never give. An explicit `custom: []` is a declaration of zero checks
and stays legal.

Every entry in `custom` may carry a `hint` string, which is attached to
the verdict's error when that entry fails.

### Check kinds

Structure and text, all judged on the no-input run:

| kind | fields | passes when |
|---|---|---|
| `dom_text_matches` | `pattern`, `flags` | the page's readable text matches the regular expression |
| `dom_text_min_length` | `n` | the page has at least `n` characters of text, whitespace collapsed |
| `dom_text_count` | `pattern`, `flags`, `min` | the pattern occurs at least `min` times |
| `element_count` | `tag`, `min`, `max` | that many elements of that tag exist |
| `text_blocks_min` | `n` | at least `n` elements carry text of their own, whatever tag the author chose |
| `console_matches` | `pattern`, `flags` | some console line matches |

Drawing:

| kind | fields | passes when |
|---|---|---|
| `draws_min` | `n` | at least `n` draw calls were issued inside frames |
| `gl_op_present` | `op` | that GL call occurred at least once |
| `uniform_present` | `name` | a uniform of that name was set |
| `max_vertices_per_frame` | `n` | no frame drew more than `n` vertices — i.e. the picture comes from a shader, not from geometry |

Animation, all decided with no input at all:

| kind | fields | passes when |
|---|---|---|
| `animates` | — | the last two frames issue different commands |
| `uniform_varies_over_time` | `name` | that uniform took more than one value across frames |
| `some_uniform_varies_over_time` | — | *any* uniform did — for when the spec cannot dictate what the author names it |

Interaction, all differential:

| kind | fields | passes when |
|---|---|---|
| `input_count_min` | `n` | the page has at least `n` input controls |
| `input_changes` | `index`, `by` | driving control `index` changes the page under that projection |
| `pointer_changes` | `by` | a drag across the canvas changes it |
| `keys_change` | `by` | the arrow keys change it |
| `inputs_change_independently` | `indices`, `by` | every listed control changes the page, **and no two of them the same way** — one slider wired to both joints would otherwise pass the per-control test twice over |

And one escape hatch:

| kind | fields | meaning |
|---|---|---|
| `manual` | `note` | recorded in the verdict, excluded from the pass/fail count |

An unknown `kind` is a failure, not a silent skip, and the error lists
the kinds that exist.

## The verdict

```json
{
  "ok": true,
  "stage": "done",
  "errors": [],
  "checks": [ { "kind": "draws_min", "ok": true, "detail": "6 draw call(s) inside frames" } ],
  "stats": { "bytes": 213648, "frames": 6, "draws": 6, "vertices": 24,
             "gl_ops": 41, "dom_text_len": 0, "elements": 4, "inputs": 0,
             "buttons": 0, "scenarios": 1, "compile_ms": 177, "total_ms": 187 },
  "stdout": "",
  "summary": "1/1 checks passed",
  "source": "…/page.ss"
}
```

`stage` is `done` on a pass and otherwise names the stage that stopped
it: `compile`, `smoke`, `draw`, `interact` or `custom`. Every entry in
`errors` carries `stage`, `message`, and where they apply `file`,
`line`, `col`, `hint` and `excerpt`. `stdout` is whatever the program
wrote, which is where a Scheme-level error message ends up when the
engine only says `unreachable`.

## The mock world

The page the module wakes up on hosts exactly two things:

```
<div id="app">      markup goes here
<canvas id="c">     800 x 600 drawing buffer, pixels go here
```

`goeteia pack` emits exactly these two, so a program that verifies here
finds the same hosts in the packaged single-file page. `document`,
`requestAnimationFrame`, `setTimeout`, `performance`, `matchMedia`,
`getComputedStyle`, `console` and the rest are present and deliberately
wider than any one page needs — what a page is *judged* on is its check
spec, which is data, not what the world happens to provide.

The WebGL context records rather than rasterizes. Every call is kept in
order with the arguments that matter (`drawElements` counts, uniform
names and values, buffer sizes), which is what makes "the picture
changed" a comparison of command streams and not of pixels. Nothing is
rendered, so a shader that compiles to a black screen still passes:
a mock's testimony is weak evidence, and when it disagrees with a real
browser, believe the browser and fix the mock.

`getContext("2d")` answers a recording 2d context of its own — the
glyph-atlas path of `(gfx sprite)` runs on it — whose `measureText`
is deterministic: 8 px per code point. Each canvas keeps one context
per kind, so a page that touches both gets two stable objects and two
logs.

### What the world can and cannot do

The mock world is **deterministic and offline**, and three of its
stubs are easy to misread:

- **No network.** `fetch` *exists* but every call rejects with
  `no network in the mock world` — a poisoned stub, deliberately, so
  a run never depends on what a server said that day. That means
  `typeof fetch` probing cannot tell this world from a browser:
  **capability probes must use the library predicates**, not feature
  sniffing. Note that `(fetch-direct?)` answers whether the host has
  real JSPI suspension — it judges the *await mechanism*, not the
  network, and is `#t` under node with the flag while `fetch` still
  rejects.
- **The clocks are frozen.** `Date.now` answers one constant forever;
  `performance.now` and the timer queue advance only when the harness
  pumps a frame. So two runs of the same bytes agree byte for byte —
  the differential interaction verdict rests on exactly this.
- **`Math.random` is seeded.** It answers the same sequence every
  run; nothing in a verdict may hinge on luck.

One global, not two: `js-eval` code and `(js-global)` see the same
`globalThis` — the bridge evaluates in the instance's global — so a
value planted through either is visible through the other.

## Adding a check kind

`CUSTOM` in `rt/verify.mjs` is one table with one entry per kind. A
handler receives `(spec, ctx)` and returns `{ok, detail}`; `ctx.base`
is the no-input run and `ctx.run(key, act)` memoizes a scenario so
several checks can share one. A new kind is a new entry — not an edit
to the pipeline.

## Packaging

```
goeteia pack <page.ss> <out.html> [--title T] [--script] [--selfcheck]
```

writes one self-contained file. The module rides in an inert
`<script type="goeteia/wasm">` as base64 and the loader is inlined, so
the page fetches nothing and works from `file://`. The loader is not a
second implementation: it is `rt/jsbridge.mjs` plus `rt/web.mjs` with
the module plumbing stripped, the same construction `rt/compile.mjs`
uses for a `conjure` mount point's glue.

`--selfcheck` reads the module back **out of the artifact** and runs
it, then compares its trace signature with the compiled module's —
same frames, same readable state. It also parses the page's inlined
module script with `node --check`, because the mock world exercises the
bridge but never this page's script text. A truncated payload, a
mangled re-encode, or a loader that does not parse each fail a
different one of those.
