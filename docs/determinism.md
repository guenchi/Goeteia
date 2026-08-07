# Numeric determinism

A golden test, a replayed reward, a fitted motion curve — each is an
equality between a value computed now and a value computed somewhere
else, earlier, possibly by a different build on a different engine.
This file says exactly which of those equalities the language
guarantees, which it does not, and what breaks the ones it does.

Everything here is checked, not asserted: `test/determinism-battery.ss`
is a fixed computation list that prints every result as an IEEE 754
bit pattern, and `test/determinism.mjs` runs it through six channels —
two compiler hosts by two targets, at both optimization levels — three
times each, and compares the whole output byte for byte. There is no
tolerance in that comparison and there is nothing to widen.

## What is guaranteed

**Every f64 operation is bit-identical on both targets.** `fl+ fl-
fl* fl/ flsqrt flfloor fltruncate fl<? fl=?` compile to wasm's
`f64.*` instructions and to JavaScript's `Number` operators. Both are
IEEE 754 binary64 with round-to-nearest-even, both are required to
return the correctly rounded result, and neither is permitted to
contract, reassociate or evaluate at a wider precision. A chain forty
matrix multiplies deep comes out the same on both — section
`m4scalar` runs exactly that.

**The optimizer does not change arithmetic.** `-O2` and `-O0` produce
the same bits, checked as two of the six channels. The passes move
boxing and allocation, not rounding.

**The transcendental functions are ours, not the host's.**
`flsin flcos fltan flasin flacos flatan flatan2` in `(gfx mat)` are
polynomial kernels written in Scheme over the guaranteed f64
operations. This is why they are deterministic: `Math.sin` is
implementation-defined in ECMAScript and differs between engines and
engine versions, so a library that called it would have no contract to
offer. Section `trig` sweeps all seven over 400 points and the two
inverse functions over their whole closed domain.

**`q-slerp`, `m4-inverse`, `m4-perspective`, `m4-look-at`,
`m4-frustum-planes` and the `(gfx gltf)` samplers inherit that
guarantee**, being compositions of the above. Sections `slerp` and
`gltf` pin them, the latter through a GLB assembled in staging memory
and sampled at 144 points across LINEAR rotation (shortest-path
nlerp), CUBICSPLINE translation and CUBICSPLINE rotation.

**The f32 lane kernels agree too.** `%f32x4-add! -sub! -mul! -scale!
-axpy! -dot` and therefore `m4-mul` with a scratch region, `m4s-mul!`,
`m4s-trs!` and `m4s-tqs!` are real SIMD on wasm and an emulation over
`Math.fround` and `Float32Array` stores on JS. They agree because f64
carries 53 bits and a correctly rounded f32 operation needs at most
2·24+2 = 50 of them: the emulation's f64 intermediate cannot
double-round on the way to the final f32 store. Section `m4simd`
covers it, including the aliasing case where the destination overlaps
a source.

**Integer arithmetic agrees at every width.** Fixnums are i31 on both
targets; past that, wasm runs its own base-2^14 limb representation
and JS rides the host's `BigInt`. Two entirely different mechanisms —
but every operation in the layer (`+ - * quotient remainder gcd` and
the comparisons) is *exact*, so agreement is forced rather than hoped
for. Section `intbits` sweeps both.

**Exact to inexact is one correctly rounded step.** `exact->inexact`
of a bignum or a ratio, `sqrt` of an exact integer, `string->number`
of a decimal, and the reader's decimal literals all round once, to
nearest, ties to even — the same answer an arbitrary-precision oracle
gives, on both targets and under both compiler hosts. This is a
guarantee the stack did *not* have before the battery existed; the two
defects that made it false are written up under *Where the rounding
lives*. Sections `bigfl` and `numlit` are the nails.

**`number->string` agrees.** The decimal printer is prelude code,
compiled to both targets from one source, so text goldens are as
stable as bit goldens — subject to the printer's own limits, below.
Section `fltext` pins it over ~1500 values.

**There is no parallelism to reorder.** The runtime is single
threaded; no reduction runs in an unspecified order, and no result
depends on how work was divided.

## What is NOT guaranteed

**NaN bit patterns.** The wasm specification lets an arithmetic NaN
carry any payload and either sign. Today both targets produce
`7ff8000000000000`, and section `edge` records that, but a future
engine may not. Never make a golden out of NaN *bits*; `number->string`
of any NaN is `+nan.0` on both, and that is stable.

**Anything computed by the host.** `js-eval` reaching `Math.sin`,
`Math.pow`, `Math.log`, `toFixed`, `toPrecision` or `Number.prototype
.toString` returns whatever that engine does. Those are outside the
contract by construction — that is the reason `(gfx mat)` implements
its own trigonometry.

**Time, entropy, and iteration over host objects.** `Date`,
`performance.now`, `Math.random`, and enumeration order of JS objects
crossing the bridge. A battery run with a single `Math.random()` in it
is caught by the three-runs-per-channel check, which is what that
check is for.

**Correct rounding below the subnormal floor.** `$exact->fl` builds a
53-bit significand and then scales it by a power of two, which is
exact until the scale drives the value into the subnormal range —
below `2.2250738585072014e-308` the significand no longer fits and
each further halving rounds again. Measured over 200 random decimals
between `1e-323` and `1e-305`: 26 are one ulp from the nearest double,
and **all 200 agree between the two targets**. So this is an accuracy
limit, not a determinism one, and everything at or above the normal
floor is correctly rounded.

**Denormal flush.** Not a wasm or JS behaviour on any engine we
target, and section `edge` walks 80 values from 2^-1000 down past
the subnormal floor to zero to keep it that way — but it is an engine
property, not a language one.

## What breaks it

Ordered by how often it will actually happen.

1. **Calling the host for arithmetic.** `(js->number (js-eval
   "Math.sin(x)"))` is a golden that expires with the next browser
   release. Use `(gfx mat)`.
2. **Reading uninitialised or stale staging memory.** `fx-alloc!` is a
   bump allocator over the wasm linear memory and `fx-release!` hands
   the same bytes out again. A record that outlives the release reads
   whatever was written next. Nothing warns you; see the water-mark
   discipline in `lib/gfx/fx.ss`.
3. **Letting a value cross into f32 in one path and not the other.**
   `m4-mul` routes through the f32 SIMD kernels when `m4-scratch!`
   has been given a region — which `fx-init!` does automatically — and
   through boxed f64 when it has not. Same function, different
   results, decided by whether a canvas was attached. A headless
   golden and a rendered one are not comparable unless both set the
   same scratch state; the battery runs the two paths as separate
   sections for exactly this reason.
4. **Hashing or ordering by address.** Nothing in the language exposes
   an address as a number, but `fx-alloc!` returns one, and a
   computation seeded from an allocation offset is reproducible only
   while the allocation history is.
5. **Rebuilding the compiler.** A change to `src/prelude.ss` changes
   every program's arithmetic; a change to `src/compiler.ss` can
   change the constants it folds. `./build-self.sh` must reach its
   fixpoint and `./run-tests.sh` must stay green across all channels
   before any golden recorded with the old build is trusted.
6. **Comparing text instead of bits when the printer cannot tell them
   apart.** See the next section.

## The printer's limits, for golden TEXT authors

`display` and `number->string` on a flonum are not a
shortest-round-trip dtoa. The printer is `$display-flonum` in
`src/prelude.ss`, and it is the same code on both targets, so it is
*stable* — but it is lossy, and a text golden inherits the loss:

| value | prints as |
|---|---|
| `0.3` | `0.3` |
| `(fl+ 0.1 0.2)` | `0.300000000000` |
| `(fl/ 1.0 3.0)` | `0.333333333333` |
| `123456.78901234567` | `123456.789012345674` |
| `1000000000.0` | `<big-flonum>` |
| `(fl/ 1.0 0.0)` | `<big-flonum>` |
| `(fl* -1.0 0.0)` | `0.0` |
| `(fl/ 0.0 0.0)` | `+nan.0` |

Three consequences:

* **Magnitude 536870911 is the ceiling.** Anything larger, infinities
  included, prints as `<big-flonum>` — a text golden over world-space
  coordinates or timestamps can be comparing two literal strings that
  say nothing.
* **Twelve fractional digits, then truncation.** Two doubles that
  agree to 12 decimals print identically, so a text golden cannot see
  a low-bit difference. Section `fltext` pins the printer; the bit
  sections are what pin the values.
* **Negative zero prints as `0.0`.** The sign survives in the bits and
  in arithmetic, not in the text.

Use bit patterns when the golden is about numbers. Reading them back
costs three lines:

```scheme
(define $buf (fx-alloc! 16))
(define (f64-bits x)                    ; 16 hex digits, big-endian
  (%mem-f64-set! $buf x)
  (let loop ((i 7) (acc ""))
    (if (< i 0) acc
        (loop (- i 1)
              (let ((b (%mem-u8-ref (+ $buf i))))
                (string-append
                 acc (string (string-ref "0123456789abcdef" (quotient b 16))
                             (string-ref "0123456789abcdef" (remainder b 16)))))))))
```

There is no `%f64-bits` primitive; the store-and-read-back above is
the whole technique, and it is exact because `%mem-f64-set!` stores
the double unchanged.

## Where the rounding lives

`exact->inexact` of a bignum, of a ratio, and the reader's decimal
literals all round in exactly one place: `$exact->fl` in
`src/prelude.ss`. That is deliberate. Two of the three used to round
separately, and each of the two was wrong in its own way — one across
the targets, one across the compiler hosts. Both defects are recorded
below because their witnesses are now regression nails in the battery,
and because the shape of the mistake is worth keeping.

The routine scales the exact numerator against the exact denominator
until the quotient lands in [2^53, 2^54), which puts 53 surviving bits
plus a guard bit in the quotient and the sticky bit in the division
remainder; it rounds to nearest with ties to even; and only then does a
53-bit significand and a power of two cross into f64, both of which f64
represents exactly. Every step before that happens in the exact integer
layer, which the two targets are already forced to agree on — every
operation in that layer being exact.

**If you touch it, these are the nails.** Reverting the ratio branch of
`$->fl` to two conversions and a division puts 62 of section
`numlit`'s 600 literals back into disagreement between the compiler
hosts; reverting `$bn->fl` to its limb accumulation puts 8 of section
`bigfl`'s conversions back into disagreement between the targets. Both
were re-run in that state to confirm the battery still catches them.

### D1 — the self-hosted compiler rounded decimal literals differently
*(fixed; witnesses kept as section `numlit`)*

**Symptom**: the same source compiled by `bin/goeteiac` (Chez-hosted)
and by `rt/compile.mjs goeteia.wasm` (self-hosted) emitted different
f64 constants, so the two builds were not the same program. **62 of
600 random 17-significant-digit literals** differed, always by one ulp,
with the Chez-hosted side correct in all 62.

Witness — `0.42451918914251396`:

| build | before | after |
|---|---|---|
| `bin/goeteiac` | `3fdb2b5288790eec` | `3fdb2b5288790eec` |
| `rt/compile.mjs goeteia.wasm` | `3fdb2b5288790eeb` | `3fdb2b5288790eec` |
| correctly rounded | `3fdb2b5288790eec` | |

**Cause**: the Chez host parses the literal with Chez's reader, which
is correctly rounded. The self-hosted compiler parses it with
`%parse-decimal`, whose comment said "exact digits over a power of ten,
converted to a flonum in one rounding — deterministic across hosts,
unlike floating-point accumulation". The intent was right and the code
did not implement it: it built the exact ratio and handed it to
`$->fl`, which converted numerator and denominator to f64 *separately*
and divided. Past 17 significant digits the numerator no longer fits 53
bits, so that was three roundings, not one.

**Now**: `%parse-decimal` and the ratio branch of `$->fl` both call
`$exact->fl`, so the comment describes the code. All 600 literals agree
between the hosts and all 600 match an arbitrary-precision oracle.
Runtime `string->number` shares the path: over 500 17-digit decimals it
was one ulp off on 52 and is now off on none.

### D2 — the wasm target rounded wide integers differently from JS
*(fixed; witnesses kept as section `bigfl`)*

**Symptom**: `exact->inexact` of an integer wider than 53 bits, and
everything downstream of it (`sqrt` of an exact integer, an exact
division reaching float, a parsed asset's fixed-point accumulator),
differed by an ulp between the two targets.

Witness — `3^54 + 7` = 58149737003040059690390176:

| target | before | after |
|---|---|---|
| wasm | `45480cd7c79aad10` | `45480cd7c79aad11` |
| JS | `45480cd7c79aad11` | `45480cd7c79aad11` |
| correctly rounded | `45480cd7c79aad11` | |

**Cause**: `$bn->fl`. The whole bignum layer is split by target — limbs
on wasm, host `BigInt` on JS — and every other operation in it is
exact, so agreement is forced. `$bn->fl` was the one operation in the
layer that has to *round*, and it was the one that diverged: the wasm
branch accumulated base-16384 limbs in f64, rounding once per limb,
against the JS branch's single correctly rounded `Number(bigint)`.

**Now**: the wasm branch defers to `$exact->fl`; the JS branch keeps
`Number(bigint)`, which is already one correct rounding and is faster.
Two mechanisms, one answer, pinned against each other by section
`bigfl` — degeneracy rather than a shared implementation, which is
worth more: a defect would have to occur twice, identically, to pass.

Verified over 833 conversions (bignums, ratios, `sqrt` of exact
integers, and `1/n` for large `n`): both targets identical, none off
the oracle.

### What the fix cost

`goeteia.wasm` grows from 439602 to 448085 bytes. The whole delta is
the new prelude code: rebuilding from the pre-fix prelude reproduces
the committed `goeteia.wasm` byte for byte, and the compiler sources
contain no decimal literals at all, so nothing the compiler reads
changed its reading. `./build-self.sh` reaches its fixpoint, and three
consecutive rebuilds are byte-identical.

## Running it

```sh
node test/determinism.mjs          # all six channels, three runs each
./run-tests.sh                     # includes the above and the oracle line
```

The battery alone, with its full value list, for locating a
divergence:

```sh
printf v > /tmp/verbose.input
./bin/goeteiac test/determinism-battery.ss /tmp/b.wasm
node rt/run.mjs /tmp/b.wasm /tmp/verbose.input
```

Without an input byte it prints one line of per-section digests, which
is what `run-tests.sh` compares against the `;; expect:` header.
