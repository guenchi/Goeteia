# Changelog

## Unreleased

*185 commits.* Two new families of libraries -- `(gam …)` for the
bookkeeping a game repeats and `(sim …)` for the machinery under it --
and a real GLSL compiler behind page verification, which every shader
defect this tree can produce used to pass.

### Breaking

- A library's `export` clause must name something the library defines.
  A name exported but never defined used to compile, and the failure
  arrived at whoever imported it. **Migration**: delete the name, or
  define it.
- An unclosed block comment is an error rather than a silent end of
  file, and a dot in a list may be followed by exactly one datum and
  then a close. Both were accepted before and both hid the mistake
  that produced them.
- `<=` and `>=` no longer answer `#t` for a NaN. They were built as the
  negation of the opposite strict comparison, which is the same thing
  for every pair of real numbers and not for an unordered one:
  `(>= nan nan)` answered `#t`, so a NaN sorted, compared equal to
  itself, and travelled through guards written to keep it out.
  **Migration**: none, unless code depended on the old answer.

### API — new libraries

- `(gam …)`, thirteen libraries: `abilities`, `effects`, `fields`,
  `inventory`, `modifiers`, `party`, `quest`, `recovery`, `save`,
  `state`, `stats`, `timeline`, `window`. The bookkeeping a game
  repeats, with none of the numbers a game chooses -- a cooldown that
  does not spend the cost it carries, pools that are named rather than
  indexed, a level curve the caller supplies. Ten import nothing but
  `(rnrs)`. `docs/game.md` is the long form: what each one refuses to
  decide, and the failure that refusal prevents.
- `(sim …)`, six libraries: `entity` (a fixed-capacity store whose
  handles carry a generation, so a recycled slot never inherits an old
  handle's identity), `schedule` (systems by priority, never by load
  order), `events` (a topic bus with a depth limit), `step` (a fixed
  timestep whose count is derived from the total, so one frame's
  rounding is never carried into the next), `grid`, `random` (a MINSTD
  generator with a stated bias bound).
- `(lng effect)`: what several sources do to one quantity -- effects
  carry a kind, a source, a priority and a phase, and resolve to a
  single answer.
- `(gfx camera)`: an orbit camera whose eye and look point are damped
  toward goals derived from one aim, so the heading is steady across
  irregular frames.
- `(gfx reflect)`: how much of a reflection target actually needs
  drawing -- `#f` to skip the pass, `#t` for all of it, or a pixel
  rectangle, with every uncertainty answering `#t`.
- `(gfx particles)`, `(gfx lod)`, `(gfx surface)`: a particle system, a
  dithered three-interval detail selector, and a tangent frame derived
  from screen-space derivatives so a mesh need not carry a tangent
  attribute.
- `(aud mix)`: equal-power panning and voice eviction.

### API — additions

Generated from the same export index the suite checks, so these lists
agree with the gate by construction -- which is not the same as having
been checked against what each library actually exports.

- `(gfx collide)`: `ray-heightfield` and `screen-ray` (ground given as
  a height function, and the pick ray built from an inverse
  view-projection rather than from a copy of the field of view),
  `segment-segment-closest` and `capsule-capsule-contact` (the closest
  points, so a caller that needs to know WHERE two capsules meet gets
  it from the arithmetic that decided THAT they meet), and the 2D
  circle half: `circle-circle?`, `segment-circle?`, `move-circle`.
- `(gfx mat)`: `fl-clamp`, `fl-lerp`, `fl-damp`, `fl-turn`,
  `fl-smooth`, `fl-pi`, `fl-tau`, `fl-length2`, `fl-dist2`,
  `fl-heading`, `mat-shader-functions`.
- `(gfx fx)`: `key-went-down?`, `key-went-up?`, `keys-consume-edges!` --
  a key pressed and released between two reads is invisible to a level
  surface, and the loss gets worse as frames get longer.
- Shader accessors, so the text a library emits can be read by
  something other than a driver: `gltf-shaders`, `ibl-shaders`,
  `mesh-shaders`, `post-shaders`, `scene-shaders`, `sprite-shaders`,
  `particles-shaders`, `lod-shader-functions`,
  `surface-shader-functions`, `fx-quad-shaders`.
- `(web dom)`: `need-element-by-id`, and an element cache the caller
  owns -- `make-element-cache`, `cached-element`,
  `set-text-if-changed!`.
- `(aud sfx)`: `audio-voices!`, `audio-voice-count`, `audio-limiter!`.
- `(gfx uastc)`: `uastc-level-bytes`.

### Fixed

Derived from the commits in this range and attributed to them, rather
than re-verified item by item for this document.

- Compiler, where a name resolves: an identifier a macro expansion
  introduces, an identifier written inside a library body or inside the
  prelude, and a reference the compiler synthesises itself (the
  `append` behind quasiquote, the escape behind `call/cc`) now resolve
  where they were written, not at the program's top level. Before
  this, a program that defined `car` changed what `assq` answered, what
  an imported library did six lines inside a procedure the program
  never read, and what `(vector 1 2)` held; each of those is now the
  R6RS answer. Three commits, each with its own red cell first and a
  mutation run after; the part of this that is NOT fixed is under
  KNOWN OPEN.
- Compiler, the specialisation scan: it walked the program as a flat
  list of forms with no knowledge of binding forms, so `(let ((foo 5))
  1)` was a call to `foo`, a `let`-bound `g` anywhere marked a
  program's own `g` escaped, and a function named `g` or `f` lost its
  float specialisation to a binding inside the prelude. The scan now
  carries the names bound around each form -- `let`, named `let`,
  `lambda` and a function's own parameters -- compared as written so a
  binder a macro introduces cannot hide the program's call. Twenty-six
  rows, one per shape; the one victim this had produced (`call/cc`'s
  escape helper) stays listed out of specialisation by name, and dead
  code elimination still keeps such a function alive, which is its own
  open entry below.
- Compiler, every primitive: the prelude, an imported library and the
  compiler's own expansions call primitives by their bare names, and a
  program's top-level definition of `null?`, `cdr`, `eq?`, `+` or `<`
  used to change what they did -- three of those broke the prelude by
  themselves. Every name in the primitive list now resolves to the
  primitive where the prelude, a library or the compiler wrote it,
  including the heads the compiler writes into `case` (which now
  compares with `eqv?`, so a flonum or bignum datum matches),
  quasiquote, internal definitions, boxed variables and the wrapper
  built when a primitive is taken as a value. One row per primitive
  redefines it and checks the prelude did not notice. A definition
  inside a function body shadowing a primitive, which used to end in
  a trap, is fixed by the same change. What remains is the value-form
  top-level definition, under KNOWN OPEN.
- Compiler, dead-code elimination: a `let` binding, a loop parameter
  or a `lambda` formal spelled like a top-level function no longer
  keeps that function in the module when nothing calls it. Binder
  positions are not references; a reference in any init or body still
  is, and so is a reference to a name that also happens to be bound
  around it, by design. Twenty-four rows on the emitted module's name
  section, three of them written against a first version that read a
  list tail as a binding form and pruned a live definition.
- Compiler, dead-code elimination: a variable named `quote` in front
  of a reference inside a call no longer makes the reference
  disappear. The walk skipped any pair whose head resolved to `quote`,
  tail or not, so the tail of `(vector quote foo)` was skipped whole
  and `foo`'s definition pruned while the program still needed it.
  Present in 1.7.0.
- Compiler: a loop parameter captured by an inner lambda no longer
  lives in a raw slot, so closures made in a loop stop sharing the
  loop's last value; a transformer's arithmetic stops discarding
  arguments it has already evaluated; a record accessor checks its
  type; the one quotient that overflows promotes; an ill-formed
  initialiser is checked before it is eliminated; a reference resolves
  by the identifier it carries before the one it was renamed from.
- Prelude: `memv` and `assv` compare by `eqv?`; `floor` and `truncate`
  return integers; infinities are neither; `inexact` accepts a complex
  number.
- Reader: the six partial scanners become one.
- GLB and glTF: the reader checks the container before it believes it;
  the meshopt decoders read inside the length they were given; a
  deflate stream ends inside its last real byte; a zstd frame keeps the
  promises in its header; a UASTC level is measured against its
  dimensions before a byte is read; vertex attribute sizes come from
  the format's structure, and every width was wrong; four ways an
  invalid primitive or animation got written; a joint's parent is its
  nearest joint ancestor; a primitive is written back to the node it
  came from; the resample grid reaches the last key.
- Rendering: a colour signal moves the generation counter, so a new
  colour reaches the screen; a sheet tinted to zero alpha stops putting
  its colour on the screen; generated quads are wound to agree with the
  normals they carry; a mesh is drawn at the width it was written; the
  bump pointer moves only under a guard; VAOs are keyed by separate
  numeric resource slots; a translucent member is welded only when
  nothing can come between; the reserved GPU slots are derived from the
  group walk.
- Input: attaching the input layer twice no longer counts one event
  twice; a press released off the element no longer stays pressed
  forever; a record of what was attached belongs to whoever asks.
- Web: FFI arguments are staged only after they all convert; a keyed
  list's item effects are released with the list; the class attribute
  merges; an existing component registry is adopted.
- GLSL: a negative literal under a negation printed as the decrement
  operator.
- Compile cache: the key now covers all of `src/`, not a list of files
  the driver was known to read.

### Tests and tooling

- Page verification puts a page's shaders in front of a **real GLSL
  compiler** rather than a recording stub whose `getShaderParameter`
  answered `true`. Every shader defect the tree can produce passed page
  verification before this. Where no browser is reachable the run says
  so in its own output rather than passing quietly, and a compiler that
  cannot be RUN is reported as unverified while a shader a compiler
  REFUSED is a failure -- collapsing those two either restores the
  silent pass or makes the gate flaky enough to be turned off.
- `tools/cdp.mjs` drives a real browser: shader compilation, reading a
  frame back, and comparing two frames inside the page.
- The runner: a right answer from a process that died is not a pass;
  everything is under a timeout; a callback error reported to the
  console is a verdict; a test that ended early says so, so its
  failures read as a lower bound.
- The page verifier stops swallowing an async failure, keeps removed
  nodes out of its snapshot, and agrees with itself between runs.
- Builds: nothing is published before it is verified, no two builds
  share a path, and a page is rebuilt when a library it imports
  changes.
- Comments across the tree are English prose carrying their emphasis in
  words, checked by a gate that reads untracked files too -- so a
  library being written right now is in scope rather than exempt.

### KNOWN OPEN

Five defects are known, reproduced, and NOT fixed in this release. They
are listed here because an unfixed defect that scrolls off a list is one
nobody re-reads at the next decision.

- **A top-level definition written as `(define car <expression>)` does
  not shadow the primitive.** `(define car (lambda (x) 99))` followed
  by `(car (list 1))` answers 1 at every call site in the program:
  the name is compiled as the builtin however the program bound it, and
  there is no diagnostic. The same definition written as
  `(define (car x) 99)` shadows correctly, so the two spellings R6RS
  treats as one differ here. It is the program's OWN calls that are
  affected: the prelude's, a library's and the compiler's own uses of a
  primitive's name are no longer reachable from a program's definition
  (see Fixed). Whether a program may redefine an imported name at all
  is open -- R6RS says it may not without `(except (rnrs) car)` -- and
  the decision is recorded as pending rather than made here. Present
  in 1.7.0. Held red by `defect-c02-shadow-primitive`.
  **Workaround**: use the `(define (name ...) ...)` spelling.
- **A morph target's POSITION accessor can declare a `max` below a
  value the file stores.** The bounds are computed over the values as
  given, and the file holds them as `f32`, so a value that rounds
  upward on the way in lands outside the declared range. This is
  invalid per the glTF specification, and a loader that culls on
  accessor bounds will clip the target. It affects morph-target
  positions only: a primitive's own POSITION bounds are read back out
  of the stored `f32`. **No cell holds this red** -- it is known from
  reading the writer, which is a weaker footing than the others, and a
  reader deciding what to trust cannot tell the two grades of evidence
  apart unless it is said which is which.
  **Computing the bounds correctly is necessary and not sufficient**:
  the declared value is written into JSON by the flonum printer, the
  subject of its own entry here, and does not survive that round trip
  either. The
  two compose, and fixing this one alone would leave the accessor still
  declaring a bound the file does not honour.
- **`state-send!` is documented as raising for an event that cannot
  happen, and does not.** Whether an unknown event raises is decided by
  an `on-unknown` clause in the spec; `make-state-machine` emits no
  such clause, and the default is to answer no actions and stay put. So
  a caller that sends an event its own code chose gets silence and a
  machine that did not move. The comment describes the intended
  behaviour and the shorthand is what should change. Held red by
  `defect-s01-send-is-quiet-about-impossible-events`.
- **A flonum written and read back is not the number that was
  written.** This is a property of the printer this release ships, not
  a limit of the representation: it walks the fraction by repeated
  multiplication by ten and stops after twelve digits, so the loss
  begins at two significant figures and gets worse downward:

  ```
  0.12    prints as  0.119999999999   reads back as  0.119999999999, not 0.12
  1e-11   prints as  0.000000000009   reads back as  9e-12, low by ten per cent
  9e-12   prints as  0.000000000009   reads back as  9e-12, unchanged
  5e-12   prints as  0.000000000004   reads back as  4e-12
  2e-12   prints as  0.000000000001   reads back as  1e-12
  1e-12   prints as  0.000000000000   reads back as  0
  ```

  The values in the right-hand column are exact, taken outside the
  printer; printing them would show something else again, which is the
  whole subject of this entry.

  **There is no clean threshold, and looking for one is the mistake.**
  Which values survive does not follow their size: 9e-12 comes back
  unchanged while 1e-11, which is larger, comes back a tenth short; and
  1e-12 collapses to zero while 2e-12, just above it, comes back as a
  different non-zero number instead. Losing a value entirely and
  shifting it to another are two views of one walk, not two ranges with
  a line between them. The fate of any particular value belongs to the
  cell rather than to this entry.

  **Printing is not idempotent**, which is the part that spreads:
  0.119999999999 reprints as 0.119999999998, so a golden sample
  refreshed from an older golden sample is not the sample it replaced.
  Not every value moves -- once one has collapsed to 9e-12 it reprints
  unchanged -- and a rule that held for every value would be easier to
  work around than one that holds for some. And this is the property much of the rest of the tree
  leans on without saying so -- **any claim of byte-for-byte identity
  across hosts in this release is a claim about twelve decimal places**,
  since identity is checked by comparing printed output, and not even a
  stable claim about those, since reprinting moves the value. Held red
  on all three hosts by
  `test/defect-n01-flonum-print-does-not-round-trip.ss`, whose
  expectation was verified to be reachable under the host Scheme.
  **A repaired printer that round-trips every double has been written
  and measured, and is deliberately not in this release**, held out on
  its cost at extreme exponents. So a reader who later finds this fixed
  should not conclude the entry was wrong: it describes what ships
  here.

  **Workaround**: do not use printed output as the carrier for a value
  that has to survive; compare flonums by tolerance rather than by
  their text.

## 1.7.0 — 2026-09-08

*8 commits.* Three new libraries under `(lng …)`; an effect can release what
it acquired; a procedure and a primitive are one object wherever they are
named; and library-private helpers stop colliding with each other, which
also takes 36% off the compiler.

### Breaking

- A top-level name defined twice is refused at compile time, naming both
  origins: `top-level name defined twice: root "(web reactive)
  lib/web/reactive.ss:3" "app.ss:33"`. Libraries are spliced into one flat
  top level, so a program that defined a name one of its libraries exports
  used to compile with the last definition winning, while dead-code
  elimination kept only that one's callees — the failure surfaced later as
  `cannot call:` on an unrelated name. The three cases it covers are a
  program redefining a library or prelude name, two libraries exporting one
  name, and one file defining a name twice. **Migration**: rename your own
  definition. Names a macro introduces are not affected: one macro used
  twice defines two distinct helpers, as hygiene says.
- `define` inside a `begin` in expression position is refused rather than
  miscompiled (`cannot call: define`), as R6RS refuses it. At top level, and
  from a macro that expands to one there, it works as before.

### API

- `(lng pred)`: `define-classifier`, `classifier?`, `classifier-name`,
  `classifier-tags`, `classify`, `classify-as`, `declare-subtag!`,
  `subtag?`, `descendants`, `classifier-watch!`, `declare-subset!`,
  `subset?`. A classifier gives each value a tag out of a declared finite
  set, with a subtag lattice over it.
- `(lng generic)`: `make-generic`, `generic?`, `generic-name`,
  `generic-arity`, `classifiers`, `add-handler!`, `add-handlers!`,
  `remove-handler!`, `generic-default!`, `generic-check!`,
  `generic-handlers`, `dispatch-trace`. Dispatch on every argument, not the
  first. In tag mode the tag domain is finite, so two handlers that could
  both apply are found when they are installed rather than settled by
  registration order; every change is a transaction, validated whole,
  committed atomically, and the previous set survives a refusal. Predicate
  mode (`'predicates`) takes open-ended predicates and can only report
  ambiguity at the call.
- `(lng machine)`: `make-machine`, `machine?`, `machine-state`,
  `machine-ctx`, `machine-spec`, `machine-events`, `machine-transitions`,
  `machine-step`, `machine->datum`, `datum->machine`. A state machine is a
  datum: states, an initial state, and transitions whose guards and actions
  are names, the guards bound to procedures when the machine is made. A step
  is pure and returns the new machine and the action names for the caller to
  run. Several guarded transitions on one (state, event) are all evaluated,
  exactly one true takes it, and more than one true is an error naming them,
  so spec order carries no meaning (which assumes pure guards). Duplicates,
  unknown options, non-datums and cycles are refused at construction by
  name; everything handed in or out is deep-copied, except the ctx, which is
  retained as given.
- `(web reactive)`: `on-cleanup`. Called inside an effect body or a root
  body, it registers a thunk for the end of that run: thunks run in reverse
  order of registration before the next run's body, on `dispose-effect!`,
  through a root's disposer, and when a parent takes its children down,
  children before parent. Releasing a tree is one transaction — every thunk
  runs even when an earlier one raised, and the first condition is raised
  after the whole tree. A cleanup that disposes its own effect ends it: the
  new body does not run.
- Arithmetic primitives used as values are as n-ary as they are in a call:
  `(apply + (list 1 2 3))` is 6 where it was 3, and `((let ((f +)) f) 1 2 3)`
  no longer drops an argument. `(+)` and `(*)` answer 0 and 1 in both forms.
  `max` and `min` take one argument or more instead of exactly two; they
  still do not do R6RS inexactness contagion.

### Fixed

- Two libraries' private helpers with one name met on the flat top level and
  the last one spliced won at every call site. `(gfx gltf)` and
  `(gfx meshopt)` each define a `$s8` — one takes a value, the other an
  address — and gltf calls `meshopt-filter-oct!` itself, so **its
  EXT_meshopt_compression path was broken in every program**; `(gfx image)`
  and `(gfx meshopt)` collided on `$u8` the same way. Every name a library
  defines and does not export now carries its library's namespace, so two
  libraries may both call a helper `$u8` without meeting.
- A top-level procedure used as a value was a fresh closure at every
  reference on the wasm target, so `(eq? f f)` was `#f`, `memq` could not
  find a procedure in a list holding it and an `eq-hashtable` could not key
  on one. A primitive used as a value had the same problem on both targets:
  `(eq? car car)` was `#f`. Each is now one object, as in Chez and as R6RS
  says.
- The arity scan that decides which closure types a module needs treated a
  sequence of forms as an application, so every body length produced a
  closure-type pair (one example carried 424 arities, 323 of them above
  100). `goeteia.wasm` goes from 487,725 to 309,862 bytes, its type section
  from 192,368 to 1,287; the example programs shrink by about 30% on wasm
  and are byte-identical on the JS target.

### Tests and tooling

- The differential proofs for the collisions (`test/meshopt-with-gltf.ss`,
  `test/meshopt-with-image.ss`) are the same test as `test/meshopt.ss` with
  one library added to the import list, which is the whole difference
  between red and green. `test/duplicate-top-level.mjs` pins the five
  refusal shapes on both targets, since a compile-time failure cannot be
  written as a `;; expect:` line.
- `test/lng-generic.ss` (13 groups), `test/lng-generic-pred.ss`,
  `test/lng-machine.ss` (17 groups) and `test/reactive-cleanup.ss` (16
  groups), with probes under `test/probes/` for the refusals that used to be
  an accepted order-dependence, a crash or a hang.

## 1.6.2 — 2026-09-07

*14 commits.* The glTF reader keeps the whole material model, the GLB
writer writes it back, skinned normals light correctly under uneven and
mirrored joints, an interrupted crossfade no longer jumps, and a program
that dies tells its host why.

### API

- `(gfx gltf)`: material texture slots are references — `gprim-base-tex`,
  `gprim-mr-tex` (new, metallicRoughness), `gprim-normal-tex`,
  `gprim-emissive-tex`, `gprim-occlusion-tex` return a `gtexref`
  (`gtexref-texture` / `-image` / `-sampler` / `-texcoord` / `-factor`, the
  factor being `normalTexture.scale` or `occlusionTexture.strength`). The file's
  `textures[]` and `samplers[]` arrive verbatim through `gltf-textures` and
  `gltf-samplers` (`gsampler-mag` / `-min` / `-wrap-s` / `-wrap-t`). The older
  `gprim-normal-img` / `-emissive-img` / `-occlusion-img` are projections of the
  references and keep returning image indices.
- `gltf-cameras` and `gltf-node-camera`; `gprim-node` and `gprim-skin`;
  `gprim-morph-normals` and `gprim-morph-tangents` (a target may omit any of
  position / normal / tangent); `gprim-base-color-factor`, the file's own
  `baseColorFactor` or `#f` when absent — `gprim-color` stays the rendering value
  with its grey fallback, which is not the spec default and so cannot say
  whether the key was there.
- `TEXCOORD_1` loads as a trailing `uv1` interleave slot (the `uv` slot is
  padded in when only `TEXCOORD_1` is present). `gltf-draw!` accepts a program
  whose attributes equal the layout or the layout minus that trailing slot, and
  binds with the primitive's stride: `fx-use!` takes the stride as an optional
  third operand. A static vertex shader passed to `gltf-skin-shader` may declare
  `a_uv1`; it composes after the skin inputs.
- `(gfx glb)`: `glb-write!` gains `images` (bytes + mime), `samplers` (a `#f`
  leaves the key out), `textures` as `(image . sampler)` pairs, `materials` with
  the five slots as `(texture texcoord factor)` references and a `#f` colour
  that omits `baseColorFactor`, `cameras`, and `skins` in the plural (the single
  `skin` spelling writes the same bytes). Primitives may name a `material`, a
  `node` (primitives on one node form one mesh, with that node's `skin`) and
  morph `targets` with `weights`. Options that cannot both hold are refused by
  name. A file that uses none of the new options is byte-identical to before.
- `(gfx gl)`: `gl-texture-sampler!`. `(gfx glsl)`: the expression form
  `(?: c a b)`, printed `(c ? a : b)`; `(gfx wgsl)` renders it as `select`.
- Host runners: an unhandled Scheme error rejects `runModule` / `runJsModule`
  with an `Error` whose message is the program's exception line, whose `output`
  is everything the program wrote before dying and whose `cause` is the trap;
  the CLIs print the output on stdout and the message on stderr. A silent trap
  (a stack overflow) keeps the trap's own text.

### Fixed

- Two textures over one image with different samplers were one GL texture and
  sampler state was never applied; now one GL texture per distinct
  (image . sampler) pair, with the sampler's filters and wraps. A texture
  without a sampler keeps the creation parameters (CLAMP_TO_EDGE), a deliberate
  deviation from the spec's REPEAT so that assets without `samplers[]` render
  as they did — the header says so.
- Skinned normals moved by the joint matrix itself and `a_tangent.w` passed
  through, so a joint that scales unevenly or mirrors lit incorrectly. Both the
  CPU kernel and the skin shader now move a normal by the cofactor matrix of
  the blended joint matrix, signed by the determinant; a tangent's `w` flips
  with the determinant. The shader normalizes `g_normal` and `g_tangent.xyz`,
  which changes lighting under scaled joints (the header gives before/after
  values); the static path in `(gfx mesh)` is unchanged.
- Interrupting a live crossfade released the outgoing clip and started the new
  fade from the incoming clip's own pose. The machine now freezes the pose on
  screen and fades from it; frozen nodes the incoming clip does not drive ease
  to bind. Still one transition at a time and no layering or masking.
- A morph target without `POSITION` no longer fails to load.
- The `at FILE:LINE (name)` line of a compile-time diagnostic named the wrong
  line on the Chez-hosted driver (newlines inside a form were never counted,
  so a twenty-line string made the next form report line 4 instead of 26)
  and went to stdout; both hosts now agree with the source line, also after
  multi-line `#;` and `#| |#` comments, and print it on stderr. A `#;` with
  nothing after it is refused by both hosts. Files whose lines end in a bare
  CR or NEL are still counted by LF only.
- A program's argv was published on the real `globalThis`, so two programs
  started together in one process both read the later one's arguments (1.6.1
  shipped this fix; listed here because the test surface around it grew).

### Tests and tooling

- `test/assets/p1.glb`, a Blender export carrying every material slot, two
  samplers, a second UV set, morph targets with normals, two skins, a camera
  and four clips; `test/probes/` for programs a `.mjs` test drives;
  `test/glbcheck.py`, a dependency-free structural checker for written GLBs;
  the writer's re-export of `p1.glb` is compared with the original's JSON and
  re-imported by Blender when Blender is installed.
- `test/docs.mjs` now checks the website manual against the tree: every
  library it names must exist under `lib/` and every documented procedure must
  be exported or defined somewhere. The check found thirty-six library names
  written `(web …)` for libraries that live under `(gfx …)` and `(aud sfx)`;
  the manual is corrected.

## 1.6.1 — 2026-09-06

*3 commits.* One runner fix; no API change.

### Fixed — program arguments

**Two programs started together in one process read their own argv.**
`rt/run.mjs` and `rt/runjs.mjs` published a program's arguments by
assigning the real `globalThis.__goeteia_argv` before their first
`await`, and `__goeteia_*` names resolve per module instance only when
written through that instance's proxy — so two modules started
concurrently in one process both read the list of whichever started
last. Sequential starts, which is what the CLI does, never showed it.
The wasm runner now publishes through the bridge's instance global;
the JS runner through a new `rt.global` export on the emitted module,
alongside `rt.mem`, on every start (an empty list included, because ES
modules are cached per file and a skipped write leaves the previous
start's list in place).

A JS module emitted before `rt.global` existed is refused by name when
given arguments rather than fall back to the real global; argv-less
runs of such a module are unchanged. Recompile it to pass arguments.

Remaining edge, documented in `docs/limits.md`: starting the *same* JS
file twice in one process still shares one module instance and so one
argv; two different files, two processes, or the wasm target are
unaffected.

## 1.6.0 — 2026-09-02

*3 commits.* One notation change, made deliberately.

### Breaking

**A unit's fraction is its digits as written, not hundredths.** In
`(web css)`, `(em 3 4)` is now `3.4em`; it used to be `3.04em`. The
optional third operand is the fraction's minimum width, so `(em 3 4 2)`
is `3.04em` — the model the shader literal `(fl W F [width])` already
used, and the two now share one implementation. Every one of the
fourteen units and the unitless `(dec …)` form changes together.

*Migration:* any call whose fraction has fewer digits than intended —
in practice a single digit that meant hundredths, including spellings
with a leading zero such as `(em 0 02)`, which the reader already read
as `2` — gains an explicit width of `2`. Fractions written with two or
more digits (`(em 0 90)`, `(em 3 40)`, `(em 0 625)`) render as before.
The migrated form `(em 0 2 2)` renders identically under 1.5.x and
1.6.0, so call sites can be migrated before upgrading.

A unit form now refuses extra operands, a negative or non-integer
fraction (the sign belongs to the whole part), and a non-integer width,
where it used to ignore them. A zero fraction renders as the whole part
alone (`1em`, not `1.em`).

### API

`(web frac)` is new: `frac-digits`, the single renderer of a fraction's
digits — pad to the minimum width first, then drop trailing zeros — used
by `(web css)` and `(gfx glsl)` (and through it `(gfx wgsl)`). Its
contract stops at the digits: CSS drops the decimal point on an empty
fraction, GLSL writes `1.0`, and the helper decides neither.

### Changed

The LLM-facing documents under `docs/llm` state the new rule and the
third operand. Each document's byte budget is now recorded in exactly
one place, and a budget failure names what to do instead of the number
to raise.

## 1.5.8 — 2026-09-01

*123 commits.* Numeric and reader conformance.

### API

**New libraries.** `(gfx raster)` — a CPU rasterizer, 103 procedures covering
cameras (`make-rcam`, `rcam-project!`, `rcam-ray!`), frames, masks, images,
meshes, and the entry points `render-frame!`, `render-mask!`,
`render-mask-add!`, `render-textured!`, `frame-diff`, `mask-iou`.
`(gfx image)` — `png-decode!`, `png-encode!`, `png-info`, `tga-decode!`,
`tga-info`, `inflate!`, `zlib-inflate!`, `crc32`, `adler32`.
`(gfx glb)` — `glb-write!`, `glb-offset`, `glb-stride`.
`(gfx retarget)` — `retarget-clip!`, `retarget-write-glb!`, `retarget-report`,
`retarget-glb-node-names`, `retarget-normalize-name`.
`(web fs)` — `fs-slurp!`, `fs-spit!`, `fs-slurp-string`, `fs-spit-string!`,
`fs-exists?`, `fs-size`. `(web args)` — `args-count`, `args-ref`, `args-list`.
`(web utf8)` — `utf8-well-formed?`, moved here so both codecs ask one predicate.

**Added to existing libraries.** `(gfx gltf)` gains 22 node and skin accessors
(`gltf-nodes`, `gltf-node-translation`/`-rotation`/`-scale` with setters,
`gltf-node-parent`, `gltf-pose-at!`, `gltf-skins`, `gltf-skin-positions!`,
`gltf-skin-normals!`, `gltf-skin-program3!`, `gltf-animation-duration`).
`(gfx mat)` gains inverse trigonometry (`flasin`, `flacos`, `flatan`,
`flatan2`) and the quaternion algebra (`q-mul`, `q-conj`, `q-neg`, `q-dot`,
`q-normalize`, `q-slerp`). `(gfx gl)` gains `cmd-read-pixels!` and
`cmd-draw-elements-instanced32!`; `(gfx fx)` gains `fx-read-target!`,
`fx-mark`, `fx-release!`, `fx-program-blocks`; `(gfx glsl)` gains `glsl-check`,
`glsl-uniform-blocks`, `fl-literal->string`; `(gfx wgsl)` gains `wgsl-check`;
`(web json)` gains `json-array?` and `json-array->list`; `(web js)` gains
`js-callback-error!`.

**Added to the prelude**, as top-level bindings: `sin`, `cos`, `tan`, and the
R6RS division operators `div`, `mod`, `div0`, `mod0`.

**New runtime modules**, shipped in the package and importable from a page.
`rt/sexpr.mjs` — a dependency-free s-expression codec, so a page running the
**JS fallback** speaks the same wire as the Wasm build: `read`, `write`,
`toJSON`, `fromJSON`, `rpc`, `rpcJSON`, the `Sym` / `Ratio` / `Vec` /
`DottedList` value types, `base64Encode` / `base64Decode`, and the `MAX_TOKEN`
/ `MAX_SPINE` / `MAX_DEPTH` limits it enforces. `rt/verify.mjs` and
`rt/pack.mjs` back the two new CLI verbs.

**176 library exports, 56 runtime-module exports and 7 prelude bindings added;
none removed.**

### Breaking

- **`(web json)` has one spelling per value.** A JSON array is a **vector** and
  nothing else — a plain list is refused with a message naming `list->vector`.
  A symbol is not a JSON value on the way out, in either position, except
  `null`; an object key must be a string. Previously a list could serialise as
  an array *or* as an object depending on its contents, and `'foo` and `"foo"`
  produced the same document.
- **`(display -0.0)` prints `-0.0`.** It printed `0.0`; the sign survived in the
  bits and in arithmetic but not in the text. `json->string` follows.
- **Unknown string escapes and unrecognised `#` syntax raise.** `"\q"` used to
  read as the letter `q`, and an unimplemented `#` form used to answer an
  end-of-input object that flowed into the data as a value.
- **A character literal above U+007F is refused on both hosts.** Strings in this
  runtime are UTF-8 byte sequences and the self-hosted reader has no spelling
  for such a literal; accepting it on one host only would give the two hosts
  different sets of valid programs.

### Fixed — numbers

- `exact->inexact` is correctly rounded. Rounding happened at 53 bits and the
  result was then scaled into place, rounding a second time below the normal
  floor; the bits are dropped once now, at the width the result actually has. A
  standing measurement of 200 random subnormal decimals went from 26 wrong to 0.
- The flonum printer prints the integer part exactly at any magnitude. Values at
  or above 2^29 printed as `<big-flonum>` — text no parser accepts — and
  `json->string` returned it as success.
- The literal encoder handles every shape an f64 can take: subnormals (which
  killed the compiler with `invalid value -129`), both infinities (`+inf.0` hung
  it in a loop that never ended), NaN (silently encoded as `1.0`), and both
  zeros (a negative zero encoded as positive).
- `list?` terminates on a circular list, as the standard requires. It looped
  forever with no output.
- `equal?` compares bytevectors by content; it fell through to `eqv?`, so two
  bytevectors with identical bytes were never equal.
- `js->number` narrows on the **closed** fixnum range; both endpoint values
  arrived as flonums.
- `(json->string 1+2i)` no longer traps: a JSON number is a real number, not
  merely an exact one.

### Fixed — the reader

- The self-hosted reader accepts what the host accepts: exponent notation with
  all five markers (`e s f d l`), a leading `+`, `.5` and `5.`, the `+inf.0` /
  `+nan.0` spellings, radix and exactness prefixes (`#b #o #d #x #e #i`) in
  either case and either order, at any base under one rule — an exponent marker
  is a letter that is not a digit in the current radix, so `#x1e3` is 483 while
  `#o1e3` is 8³. A generated 6504-row corpus compares the reader against Chez
  Scheme with zero mismatches; the deliberate divergences are listed in the
  generator that builds it.
- The full R6RS string escape set translates, and `\xNN;` encodes to UTF-8
  rather than reading as its own four characters.
- `|...|` symbol names and `\xNN;` in bare identifiers are read; the writer
  emits escapes for any name whose plain spelling would not read back, so a
  symbol containing a space, or an empty symbol, survives a round trip.
- `#| ... |#` block comments nest, and `#;` skips one datum, including inside a
  list and before a dotted tail.
- `#vu8(...)` is read — the writer had always emitted it, so the library could
  not read back its own output.
- The reader's nesting limit, dropped during a port, is restored.
- A negative zero keeps its sign through the JSON reader, the decimal reader and
  the exact-to-float conversion.
- Line endings follow the host: LF, CR, CRLF, NEL, CR+NEL and LS end a line
  wherever a line can end — in a comment, in a string body, and after a
  continuation backslash.
- A source file that is not valid UTF-8 is refused by name on both hosts.
- `set!` of a non-identifier says so instead of reporting an unbound variable.

### Fixed — the two hosts agree

- The hosted driver decodes source as UTF-8 and hands the compiler bytes. It
  read source as latin-1 so raw UTF-8 would pass through, but a `\xNN;` escape
  in the same literal became a code point and was then truncated: `"\x3bb;"`
  compiled to one byte on the host and two under self-hosting, and the JS target
  crashed outright.
- `errorf` has one contract on both hosts. The compiler sources got Chez's
  `errorf` under the hosted driver and the prelude's when self-hosted; the two
  never agreed on what a message means, so `unbound variable ~s` printed with
  the name filled in under one host and with a literal `~s` under the other. All
  48 message strings drop their format directives, and a new test compiles the
  same source with both drivers and compares what they say.

### Changed

- One `(fl ...)` renderer serves both GLSL and WGSL. They had separate
  implementations and the WGSL one ignored the width argument, so the same
  shader source produced values ten times apart on the two backends.
- GLSL and WGSL refuse reserved words where a shader declares a name.
- `goeteia verify` and `goeteia pack` join the CLI.
- `docs/limits.md` declares the number syntax accepted beyond R6RS — fractions
  and exponents at any radix — and what is still refused.

---

## 1.5.7 — 2026-08-07

*37 commits.* The `(gfx gltf)` hardening cycle.

### API

`(gfx gltf)` gains 11 exports: `gltf-skin-shader` — the skin combinator over
vertex shaders — `gltf-prim-world`, and the material slots `gprim-layout`,
`gprim-etex`, `gprim-ntex`, `gprim-otex`, `gprim-emissive`,
`gprim-emissive-img`, `gprim-normal-img`, `gprim-occlusion-img`.
`(gfx fx)` gains `fx-program-attribute-names`, `fx-program-attribute-schema`
and `fx-uniform?`. **14 added, none removed.**

### Fixed

- Sampler interpolation is honoured; `WEIGHTS_0` is dequantized; quantization,
  poses and materials corrected across models; interrupted and instant fades;
  the skinned primitive's world transform; attribute widths checked in
  `gltf-draw!`; an attribute declared after `main` is refused.
- Browser compiler diagnostics are preserved; external auto artifact URLs are
  encoded; stale glyph event listeners are retired; conjure's two-file artifact
  checks are enforced; the external JS fallback runs in isolation; the optimizer
  preserves fallible dead initializers; loop retirement is scoped to mounts;
  glyph lifecycles are scoped and disposed.

---

## 1.5.6 — 2026-08-03

*76 commits.* The JavaScript backend and mount points. No library export
changed; the new surface is at the compiler and CLI level.

### API — toolchain

- **`--js`** compiles to a plain-JavaScript ES module, so a page can run where
  Wasm GC is unavailable. The numeric tower rides native `BigInt`; pairs are
  tagged object literals; non-self tail calls are trampolined, with the
  trampoline elided where chains cannot cycle; the kernel ships by reachable
  group.
- **`conjure`** and the `define-` family of mount-point wrappers stage
  compilation into the host page, dispatching on the head's shape, usable inside
  libraries, with quasiquote suspending a mount and unquote resuming it.
  `define-js` takes a URL form. `goeteia-mount` assembles the two-artifact
  section.
- **`compileGoeteiaFrom`** makes compile-in-the-browser a runtime primitive.
  `rt/web.mjs` also gains `compileGoeteia`, `runGoeteiaBytes`,
  `runGoeteiaInline`, `loadGoeteiaAuto` and `hasWasmGC`, and the new
  `rt/runjs.mjs` runs a JS-target module. **8 runtime exports added.**
- `%target-case` selects code per target.

### Fixed — the JS target

SIMD overlap semantics; real memory growth; traps for integer division by zero,
collection bounds, byte memory bounds and invalid float conversions; dynamic
minimum arity; Unicode export names; operand validation for flonums, pairs,
tagged integers and collections; a plain `ArrayBuffer` fallback when
`WebAssembly` is absent; BigInt normalization bounds.

### Fixed — elsewhere

Dead-code elimination recognises pure construction in top-level initializers,
and no longer swallows observable failures; `define-js` filesystem URLs are
percent-encoded; atomic quasiquote mount scanning; `glyphs-dodge!` retires its
loop on re-run.

---

## 1.5.5 — 2026-07-31

*35 commits.* A security and robustness pass, largely from external
contributions. No API change.

### Fixed

Dev server path containment; JSON number exponents are bounded; CLI output and
playground source are UTF-8; React prop keys and values are tracked; direct
scripts with file URLs are detected; comments are skipped in import clauses;
UASTC scratch stays inside the decoder; Zstd input and output bounds are
enforced, and literal scratch is bounded to the caller's real length; KTX
container ranges are validated; each module instance gets isolated memory; scene
camera cache keys compare completely; tangent spheres stay inside frustums;
command capacity is checked before writes; framebuffers are registered for
restarted XR sessions.

---

## 1.5.3 — 2026-07-18

*5 commits.* No API change.

- **Fixed:** `(web js)` caches JS `true` / `false` so `->js` never re-enters
  argument marshalling.
- The bump was reverted once and re-applied; the published artifact is the
  second one.

---

## 1.5.2 — 2026-07-16

*4 commits.* No API change.

- **Changed:** `(gfx glsl)`'s `(fl ...)` takes a width, for fractions with
  leading zeros.
- **Fixed:** the skybox ball mirrors the sky at grazing angles, so the waterline
  fuses instead of seaming.

---

## 1.5.1 — 2026-07-15

*7 commits.*

### API

`(gfx wgsl)` gains `wgsl-compute->string`. **1 added, none removed.**

### Added

Compute shaders in `(gfx wgsl)` — structs, storage arrays, `gid` — one dialect
fewer between the two GPU paths; `@media` blocks in `(web component)` carry
descendant and pseudo sub-rules, so a component's responsive shape travels with
it.

### Fixed

Malformed `sgl` forms are named instead of trapping; `(gfx zstd)` handles
multi-block frames with persistent entropy state and a bignum-free literals
header; `(web glyphs)` calibrates its advance scale against a DOM probe, so
canvas drift on Firefox no longer wraps text the browser fits.

---

## 1.5.0 — 2026-07-15

*11 commits.*

### API

`(gfx sgpu)` gains `sgpu-occlusion!`. **1 added, none removed.**

### Added

- **Script mode.** `(%opt 0)` or `--script` turns the optimization passes off
  for fast compiles; the cheap older passes stay on.
- `KHR_mesh_quantization` — integer vertex formats — in `(gfx gltf)`; hi-Z
  occlusion culling and GPU-side back-to-front sorting of translucent instances
  in `(gfx sgpu)`; static instanced groups in `(gfx scene)` skip the per-frame
  re-cull and re-upload.

---

## 1.3.8 — 2026-07-14

*12 commits.*

### API

**New libraries:** `(gfx uastc)`, `(web component)` — with `define-component` —
and `(web glyphs)` (7 exports). `(gfx fx)` gains the `fx-mesh` handles
(`fx-mesh!`, `fx-mesh-use!`, `fx-mesh-draw!`, `fx-mesh-count`, `fx-mesh?`);
`(gfx ktx)` gains `ktx-uastc?` and `ktx-uastc-level!`; `(web css)` gains
`palette->root`; `(web dom)` gains `computed-style` and `computed-px`.
**23 added, none removed.**

### Added

`cond`'s `=>` arrow clauses; UASTC LDR 4×4 to RGBA from the basisu transcoder,
and end-to-end UASTC KTX2 decoding; element-attached CSS interned to classes.

### Fixed

Macros defined and used within one library now expand, which removed the
in-library caveat from `(web component)`.

### Changed

The site's working parts moved into the library, and fifteen copies of the
upload dance in the examples retired.

---

## 1.3.7 — 2026-07-14

*23 commits.* Compiler codegen and the compressed-asset pipeline.

### API

**New libraries:** `(gfx meshopt)` — the EXT_meshopt_compression decoder —
`(gfx zstd)` — a Zstandard decompressor from RFC 8878 — and `(gfx sgpu)`, the
declarative scene on WebGPU. `(gfx mesh)` gains `mesh-optimize!`, `mesh-remap!`
and `mesh-acmr`; `(gfx gpu)` gains `gpu-hzb!`, `gpu-hzb-init!`,
`gpu-compute-groupx!`, `gpu-end-pass!`, `gpu-pipeline2-blend!`; `(gfx ktx)`
gains `ktx-stream!` and `ktx-alpha?`; `(gfx gl)` gains `cmd-depth-write!` and
`gl-texture-base-level!`. **25 added, none removed.**

### Added

Named lets lower to Wasm loops — no closure, no call per iteration — and loop
variables earn typed `f64` / `i32` slots across iterations; flonum function
specialization for top-level functions with f64 parameters; Forsyth vertex-cache
ordering; hierarchical-Z occlusion culling; static welding of strangers into one
draw; scene translucency as a back-to-front blended pass.

### Changed

`%f32x4-axpy!` was fused to `relaxed_madd` and then reverted to portable
mul+add after cross-engine benchmarks; the benchmark harness ships.

---

## 1.3.6 — 2026-07-14

*3 commits.*

### API

`(gfx ktx)` gains `ktx-fetch!` and `ktx-upload!`. **2 added, none removed.**

### Added

**The i32 context** — raw machine integers in locals — with an ordering fix.

---

## 1.3.5 — 2026-07-14

*11 commits.*

### API

**New library:** `(gfx ktx)`, the Basis Universal transcoder written in Scheme
from the spec (11 exports). `(gfx gpu)` gains `gpu-draw-indirect!`,
`gpu-draw-indexed-indirect!`, `gpu-indirect!`, `gpu-compute-group*!`,
`gpu-gpu-timer!`, `gpu-gpu-ms`; `(gfx gl)` gains `gl-texture-compressed!`,
`gl-compressed-level!`, `gl-compressed-family`. **20 added, none removed.**

`rt/web.mjs` gains `loadGoeteiaWorker`, with the new `rt/worker.mjs`.

### Added

GPU-driven culling with compute-compacted instances and indirect draws; the
render loop leaves the main thread;
WebGPU frame time through timestamp queries.

### Changed

The f64 context widens — per-binding capture, flonum `if`s, unboxed `fl` tests;
scene matrices cache against a transform generation; singles draw nearest first
and textured passes group by texture; animation channels sample through a play
cursor.

---

## 1.3.3 — 2026-07-14

*11 commits.*

### Breaking

- **`(web typeset canvas)` becomes `(web canvas)`.**
- **Wire format:** `(web sexpr)` and `(web rpc)` encode and decode flonums as
  `#f8"<IEEE base64>"`.

### API

`(gfx mat)` gains the destructive v3 operations (`v3-add!`, `v3-sub!`,
`v3-scale!`, `v3-cross!`, `v3-normalize!`, `v3-copy!`, `v3-set!`),
`m4s-tqs!` and `sphere-in-frustum-xyz?`; `(gfx gl)` gains the texture-array and
GPU-timer entries; `(gfx mesh)` gains `mesh-write-f16!` and
`mesh-vertex-bytes-f16`; `(gfx gltf)` gains `gltf-joint-palette!` and
`gltf-joint-count`; `(gfx fx)` gains `fx-texture-array!`. **23 added, 1 removed
(the renamed library).**

### Changed

v3 hot paths stop allocating; the instanced cull goes SIMD; scene frame globals
ride one `Env` uniform block; skeletons go SIMD-resident; half-precision vertex
streams; texture arrays; GPU frame time in the stats HUD.

---

## 1.3.2 — 2026-07-13

*2 commits.*

### Breaking — the library split

**330 exported names move.** Every graphics library leaves the `web` prefix for
`gfx`, and audio becomes `(aud sfx)`:

| before | after |
|---|---|
| `(web audio)` | `(aud sfx)` |
| `(web collide)` `(web fx)` `(web gl)` `(web glsl)` `(web gltf)` `(web gpu)` `(web ibl)` `(web mat)` `(web mesh)` `(web post)` `(web scene)` `(web sdf)` `(web sprite)` `(web stats)` `(web wgsl)` `(web xr)` | the same names under `gfx` |

The exported names themselves are unchanged; only the library each lives in
moved. `(web ...)` keeps the browser and document libraries.

---

## 1.3.1 — 2026-07-13

*8 commits.*

### API

`(web mat)` gains the staging matrices `m4s-identity!`, `m4s-mul!`, `m4s-trs!`,
`m4s-read`, `m4s-write!`; `(web gpu)` gains `gpu-bundle!` and `gpu-execute!`;
`(web gl)` gains `cmd-uniform-matrix4s!`. **8 added, none removed.**

### Added

The uniform cache; same-geometry single-draw batching and LOD containers in
`(web scene)`; render bundles; the cached shadow map; `fx-skybox` with a sea
that mirrors.

---

## 1.3.0 — 2026-07-13

*31 commits.* The graphics stack becomes an engine.

### API

**New libraries:** `(web gpu)` — the command buffer on WebGPU, 27 exports —
`(web post)` (15), `(web xr)` (7), `(web wgsl)`, `(web sexpr)`, `(web stats)`,
`(web ibl)`, `(web sdf)`. `(web collide)` gains capsules, the swept sphere, the
character controller and the broadphase grid (13); `(web gl)` gains the 32-bit
index and MRT entries (7); `(web gltf)` gains the animation state machine (6);
`(web fx)` gains `fx-loop-fixed!`, `fx-target-mrt!`, `fx-mrt-texture`.
**89 added, none removed.**

### Added

Post-processing chains including depth of field, grade and FXAA; light probes;
deferred shading; one shader source in three dialects; sharp SDF text; the
engine layer (fixed timestep, character controller, broadphase); PCSS soft
shadows and screen-space reflections; Wasm SIMD in the compiler, with `m4-mul`
3.5× wide; 32-bit indices for meshes past 65536 vertices.

---

## 1.2.0 — 2026-07-13

*38 commits.* The 3D renderer.

### API

No new libraries; **74 exports added** to the existing ones. `(web gl)` gains
26 — instancing, cube maps, UBOs, VAOs, transform feedback, MSAA resolve;
`(web fx)` gains 17 render-target entries; `(web gltf)` gains 14 —
`gltf-animate!`, `gltf-animate-blend!`, `gltf-joint-matrices`,
`gltf-load-textures!`, `gltf-weights!`; `(web mesh)` gains 9 — `mesh-bounds`,
`mesh-heightmap`, `mesh-tangents`, the PBR and normal-mapping shaders;
`(web mat)` gains `m4-inverse`, `m4-ortho`, `m4-unproject`,
`m4-frustum-planes`, `sphere-in-frustum?`; `(web glsl)` gains the ES 3.00
dialect entries. **None removed.**

### Added

WebGL 2 and offscreen render targets; instancing; glTF textures, skeletal
animation and morph targets; shadow mapping with PCF and cascades; bloom; normal
mapping; cube maps; particles; mipmaps; linear-space lighting; MSAA; picking;
animation crossfade; frustum culling; Cook-Torrance GGX PBR with the sky as a
light probe; terrain from a height function; water; HDR half-float targets;
SSAO; point-light shadows; GPU particles through transform feedback.

### Fixed

The mesh index writer stores u16 pairs as byte stores rather than packed i32;
anti-feedback-loop opcodes (`cmd-unbind-texture!`, `cmd-unbind-cubemap!`) for
what Chrome rejects.

### Changed

The command region grows from 16 KiB to 64 KiB — the old budget was a 2D budget.

---

## 1.1.0 — 2026-07-13

*10 commits.*

### Breaking

**`(web three)` is removed**, with its 6 exports (`s3d`, `three-loop!`,
`three-ref`, `three-render!`, `three-renderer`, `$s3d-build`). The Three.js
binding is gone; the native stack replaces it.

### API

**New libraries:** `(web gltf)` — `gltf-parse`, `gltf-fetch!`, `gltf-draw!`,
`gltf-prims` and the `gprim-` accessors — `(web collide)` — `ray-sphere`,
`ray-aabb`, `ray-mesh`, `ray-triangle`, `ray-plane`, `sphere-sphere?`,
`sphere-aabb?`, `aabb-aabb?`, `sphere-aabb-push` — and `(web audio)` —
`audio-init!`, `beep!`, `play!`, `load-sound!`, `loop-sound!`, `stop-sound!`,
`audio-time`. `(web mesh)` gains the UV entries; `(web mat)` gains
`m4-from-quat`; `(web fx)` gains pointer lock. **37 added, 6 removed.**

### Added

`(web typeset)` kinsoku line breaking; a textured lit shader; GLB static meshes
from real assets.

---

## 1.0.2 — 2026-07-13

*4 commits.*

### API

**New libraries:** `(web fx)` (24 exports) — the frame loop, programs, targets
and input — `(web mat)` (23), `(web mesh)` (15), `(web sprite)` (22),
`(web typeset)` (13), `(web scroll)` (6), `(web scene)` (4),
`(web typeset canvas)`. `(web gl)` gains 12 command entries; `(web glsl)` gains
`glsl-attributes` and `glsl-uniforms`. **122 added, none removed.**

`rt/compile.mjs` gains `compileSource`, and `rt/repl.mjs` adds `startRepl`.

### Added

The graphics, text and 3D web stack, plus compiler ergonomics.

---

## 1.0.1 — 2026-07-12

*4 commits.* No API change.

- **Changed:** the playground ships inside the npm package.

---

## 1.0.0 — 2026-07-12

*66 commits.* The first published version: a self-hosting Scheme compiler
targeting WebAssembly GC, and a web stack written in the language it compiles.

### API

**15 libraries, 111 exports.** `(web reactive)` — fine-grained signals, effects
and batching — `(web sx)` — reactive DOM templates — `(web react)`,
`(web dom)`, `(web html)`, `(web css)`, `(web js)`, `(web json)`, `(web rpc)`,
`(web fetch)`, `(web ws)`, `(web sse)`, `(web gl)` — raw WebGL through a
command buffer — `(web glsl)`, and `(web three)` (removed in 1.1.0).

### The compiler

Seven milestones: a Scheme subset to Wasm GC end to end; closures, `set!` and
top-level variables; strings, symbols and characters; variadic procedures,
`apply` and `values`; `read`, `write` and runtime symbol interning; hygienic
macros; **self-hosting**. Then `call/cc` as escape continuations over Wasm
exception handling, `dynamic-wind`, the numeric tower (bignums, flonums with
fixnum fast paths, rationals, complex numbers), vectors, bytevectors,
hashtables, `define-record-type`, ports, `guard` / `raise`, the library system
with import resolution and splicing, and dead-code elimination with predicate
test fusion.

### The toolchain

**Six runtime modules, 10 exports:** `rt/compile.mjs` (`compileFile`,
`compileToBytes`), `rt/run.mjs` (`runModule`, `decode`), `rt/web.mjs`
(`loadGoeteia`), `rt/jsbridge.mjs` (`makeJsBridge`, `callMain`,
`jsBridgeStubs`), `rt/react.mjs` (`goeteiaComponent`) and `rt/dev.mjs`
(`startDevServer`). The browser playground; the npm package and CLI.
