# The s-expression wire, from plain JavaScript

`rt/sexpr.mjs` is the wire codec for consumers that do not compile
through this toolchain: an ordinary page, a React app, any JavaScript
that has to talk to a node speaking the same format. Zero dependencies,
one ES module, the same source in a browser and in node.

```js
import { rpc, rpcJSON, read, write, sym, ratio } from './rt/sexpr.mjs';

// rpc answers in the WIRE model: an alist comes back as an array of
// DottedList, not as a plain object.  rpcJSON is the one that converts.
await rpc('/api', 'get-user', 42);
//   -> [Sym('ok'), [DottedList{items: [Sym('name')], tail: 'ada'}]]
await rpcJSON('/api', 'get-user', 42);
//   -> ['ok', {name: 'ada'}]
```

There are three implementations of this format — `(igropyr sexpr)` in
Chez, `(web sexpr)` here, and this one. **The Chez one is the
authority.** Neither of the other two is ever checked against the
other: `test/sexpr-vectors.json` is generated from the authority by
`test/gen-sexpr-vectors.sc`, and each implementation is held to those
bytes. Twins drift, and the way it is usually discovered is that two of
them agree with each other and are both wrong.

## The value model

| wire | JavaScript |
|---|---|
| `(a b c)` | `Array` |
| `()` | `[]` |
| `(a . b)` | `DottedList {items, tail}` |
| symbol | `Sym {name}` — build with `sym("get-user")` |
| `"text"` | `string` |
| exact integer | **`BigInt`, always** |
| exact ratio | `Ratio {num, den}` — build with `ratio(1n, 3n)` |
| flonum `#f8"…"` | **`number`, always** |
| `#(a b)` | `Vec {items}` |
| `#vu8"…"` | `Uint8Array` |
| `#t` / `#f` | `boolean` |

The two **always** are one decision. JavaScript cannot tell `1` from
`1.0`, so exactness cannot be recovered from the value at write time:
a `BigInt` is therefore always an exact integer and a `number` is
always a flonum. `write(42n)` puts `42` on the wire; `write(42)` puts
`#f8"…"` on it. A consumer that means the exact integer says so with a
`BigInt` — and `fromJSON` does that for you, turning every safe
integer into one, with `-0` as the deliberate exception: it is a safe
integer with no exact form that carries its sign, so it crosses as a
flonum, where the wire holds the sign bit.

Two shapes are deliberately not representable twice. A dotted tail that
is itself a list is not a distinct datum — `(a . (b c))` **is**
`(a b c)` — so `dotted()` folds it and the `DottedList` constructor
refuses the shape outright.

Ratios follow the same rule from the other side: **wide in, narrow
out.** `new Ratio(2n, 4n)` and `new Ratio(1n, -2n)` are accepted and
normalized, so the wire sees `1/2` and `-1/2` — the only bytes the
authority would ever produce for those values. What is *refused* is a
ratio that reduces to a whole number: `new Ratio(4n, 2n)` throws rather
than quietly writing `2`, because a caller who built a ratio and got an
integer back on the far side has been surprised silently. `ratio(4n,
2n)` does the collapse deliberately and returns `2n`. A zero
denominator is refused everywhere.

## The JSON view

`toJSON(value, opts)` and `fromJSON(json)` cross between the wire model
and plain JSON. Three conversions happen unconditionally, because JSON
can carry the whole value: a `Sym` becomes its name, a `Vec` becomes an
array, and an exact integer inside the safe range becomes a number.
Every *other* loss is a refusal by default rather than a silent
conversion:

| what | default | opt-in |
|---|---|---|
| `BigInt` past 2^53−1 | throws | `{bigint: 'string'}` |
| `Ratio` | throws | `{ratio: 'number'}` |
| `Uint8Array` | throws | `{bytes: 'base64'}` |
| `NaN`, `±Infinity` | throws | — |
| a dotted pair outside an alist | throws | — |
| `null` (in `fromJSON`) | throws | — |

An array of single-`Sym`-headed pairs becomes an object (turn it off
with `{alist: false}`; a mistyped option name is refused rather than
ignored, because `{alists: false}` would otherwise leave the rule on
and change the result's shape without a word), and that object has a
**null prototype**: a key
named `__proto__` or `constructor` is data here, not a reach into
`Object.prototype`. A duplicate key throws rather than dropping half
the payload.

One asymmetry is worth knowing before you rely on the round trip: an
object whose value is an array flattens. `{tags: ['x','y']}` writes as
`((tags "x" "y"))`, because `(k . (v…))` **is** `(k v…)` on this wire,
and reading it back gives a list rather than an object. Scalar-valued
objects round-trip exactly — non-empty ones, at least: `{}` writes as
`()` and reads back as `[]`, because this wire has no empty object
distinct from the empty list.

This is the format's semantics, not a gap in this port — a Scheme peer
cannot express the difference either. **The escape hatch is a vector:**
`(k . #(…))` stays a genuine dotted pair, so a server that wants an
object-with-array-values to survive the round trip sends the value as
`#(…)` rather than as a list:

```js
write([dotted([sym('tags')], new Vec(['x', 'y']))]);   // ((tags . #("x" "y")))
toJSON(read('((tags . #("x" "y")))'));                 // { tags: ['x','y'] }
```

## Safety

A recursive-descent parser, never a host reader: no `eval`, a depth
limit of 64, a token cap of 65536 code points, and every refusal is a
`SexprError` carrying a `position` — that holds for every refusal
*about the input*. A caller mistake (a non-string argument, an option
this module does not have) raises a `TypeError` or `RangeError`
instead, deliberately: those are bugs in the calling code rather than
data from a peer.

**What `position` counts is local, and the three implementations do not
all count the same thing.** The wire never carries a position — it is
diagnostic metadata about the string the caller is holding — so each
side indexes that string the way its own runtime does:

| implementation | `position` is an offset in |
|---|---|
| `(igropyr sexpr)` (Chez) | code points |
| `rt/sexpr.mjs` | code points (the input is walked as `Array.from(text)`, so a UTF-16 pair does not drift it) |
| `(web sexpr)` | UTF-8 bytes — that runtime's strings *are* byte strings, and the number points into the string the caller actually has |

(so "code points" is the authority's unit and this module's, not
"Scheme's": one of the two Scheme implementations counts bytes.)

They therefore agree on every all-ASCII input and diverge after a
non-ASCII character: `"😀" x` fails at 3 in the first two and at 6 in
the third. **The verdict is the same in all three** — the same inputs
are refused — and only the number differs.

The *messages* match too, with one deliberate exception: `(web sexpr)`
splits one of the authority's. `#vu8"AB"` is refused by both, as `bad
base64 in bytevector` there and `non-canonical base64 tail in
bytevector` here, because one message covering two guards meant a test
pinning it could not tell which had fired — and a rejection moving from
one guard to the other went unnoticed. (This paragraph used to claim the
messages were identical, and stayed there for a round after the split
made it false. Changing behaviour and leaving the prose is the failure
mode these documents exist to avoid.)
Making the third count code points would mean a UTF-8 decode on the
parser's hot path to sharpen a diagnostic, which is a stronger promise
than anything here needs. The golden suite pins the verdict everywhere
and the position everywhere it is comparable, naming each case where it
lets the number go.

The parser's accept/reject boundary is not a matter of taste; it is
whatever the authority does, recorded in the fixture. Two places where
a plausible implementation guesses wrong:

- **base64.** `=` is ignored wherever it appears and the bits left over
  after the last whole byte must be zero. So `#vu8"A"` is an empty
  bytevector, `#vu8"===="` is too, `#vu8"A=A="` is one zero byte — and
  `#vu8"AB"` is an *error*. `atob` disagrees on several of these.
- **`#f8` length.** Checked in decoded BYTES, not in base64 characters:
  a padded payload can be twelve characters and decode to seven.

**One host conversion, three faces, all fatal.** Text machinery repairs
rather than refuses, and each runtime does it in its own place:

- *outbound, JavaScript* — an unpaired surrogate has no UTF-8 encoding
  and becomes U+FFFD when the string is encoded for the wire, so `write`
  refuses such a string;
- *inbound, JavaScript* — a malformed reply byte becomes U+FFFD in
  `Response.text()`, so `rpc` decodes with a fatal `TextDecoder` and
  raises instead;
- *outbound, Goeteia* — that runtime's strings **are** UTF-8 bytes and
  nothing stops one from being malformed, so `(web sexpr)`'s writer
  checks well-formedness (shortest form and surrogate halves included)
  before a string goes between the quotes.

Three sites, one defect: a value accepted at one end that is not the
value that arrives at the other, with nothing to say so. If any one of
them ever needs revisiting, so do the other two.

Where the two ends differ, the writer is the narrower one, on purpose:
it refuses some things the reader would accept (an enormous flat list,
for instance) so that what leaves is always readable. A reader may also
be given a *smaller* depth limit than the default; that narrows what it
accepts, never what it emits.

## Symbols that cannot cross

This grammar has no `|escaped|` symbol form, so a name that reads back
as something else cannot be written at all. `write` refuses three
classes:

1. names a Scheme reader calls numbers — `12`, `+1`, `.5`, `1e3`,
   `1/2`, `+inf.0`;
2. names that merely *start* numeric without being a number here —
   `0x10`, `12abc`, `1/-2` — which this grammar's reader refuses
   outright;
3. names longer than the token cap, which come back as "token too
   long" at the far end.

The same cap applies to a printed numeral: an exact integer or ratio
whose decimal text runs past 65536 characters does not go out either,
and a ratio is measured whole — `num/den` is one token to the reader.
Carry a value that large as a bytevector.

All three classes match `(igropyr sexpr)` name for name. The fixture's
`write_reject` group is a systematic matrix — sign × magnitude ×
imaginary suffix, plus compound and polar forms and a character-class
corpus — rather than a list somebody thought of, and the case variants
of every alphabetic part are *generated* rather than sampled.

That structure is not decoration. A hand-picked list of 61 names all
agreed with the authority while an entire family disagreed (`+i`,
`+2i`, `+inf.0i`, `+1@2`). Making it a matrix caught that, and then the
matrix itself missed a dimension five more times — signed denominators,
the `s`/`f`/`d`/`l` exponent markers, the uppercase `I` suffix,
cross-family composition (`+1e3+2i`, `+1/2@3/4`), and a signed right
operand in polar form (`+1@-2`).

Six gaps, and **not one of them was found by reading the grammar more
carefully** — every one came back as a disagreement from the authority.
Assume it is still incomplete. The membership and count assertions
exist so that the next gap arrives as a failing test rather than as a
surprise in production.

The generator also measures the other direction: every name the
authority *writes* is fed back to its own reader and compared. That set
is empty today, and the suites assert it stays empty — it was not
always. Five names (`0x10`, `12abc`, `1/-2`, `1//2`, `1/0`) used to go
out and come back as errors, because the writer asked the host reader
what a number was while the parser asked this grammar.

## What a round trip cannot ask

Most of the suite parses the authority's bytes with our reader and
writes them back with our writer. That is a **fixed point**, and a fixed
point is blind to a *matching pair* of mistakes: decode a flonum
big-endian and encode it big-endian and every byte still agrees while
every value in between is wrong. The same blindness covers a swapped
escape table, an exchanged pair of control characters, a sign dropped
from a zero on both sides.

So the fixture carries a third group, `anchors`, where the value never
comes from this codec. Each entry is a **spec** — a prefix token program
whose payloads are all decimal integers and whose text is UTF-8 bytes,
so reading one involves no string escaping, which is the layer under
test — beside the wire the authority produces for it. A consumer builds
the value from the spec with its own code and asserts both directions
against those bytes. `direction` says which: `both` when the authority
also emits exactly that wire, `read` when the wire is a spelling it
accepts but does not itself produce (the escaped form of a control
character). The generator *measures* that rather than declaring it.

The dimensions are type, spelling branch, and **position** — an atom at
top level, as a list element, as a vector element, as a dotted tail, and
one level deeper again. Position was added after the first two: a
bytevector deliberately written wrong *only when nested* left every
other suite in this repo green, because no anchor had ever put a
bytevector, a ratio, a bignum, a negative zero or a control character
anywhere but at top level, and the writer takes a depth argument. UTF-8
sequence length was the same story in miniature — the matrix had lengths
1, 3 and 4 and not 2.

Then the same shape appeared *inside* the new dimension: every nested
bytevector was one byte long, so `position × base64 padding class` was
itself a product filled along one edge, and a paired mutation that
reversed **two-byte** bytevectors only when nested survived again.
Padding class is a property of the atom, so the atom list carries all
three classes and the product covers them at every position.

None of these was found by thinking of a case. Each was found by listing
a dimension's values and looking for one filled in some cells and not
others — the question a product lets you ask and a list does not. And
the sweep has to be as many-dimensional as the hole: scanning one
dimension at a time found the missing UTF-8 length (a gap *within* a
dimension) and could not have found the padding class (two dimensions
that never varied *together*). Assume there is another.

**Which sub-dimensions get crossed with position is not "all of them."**
A sub-dimension belongs in the product exactly when it is a real
*branch* in the codec — something a mutation conditioned on depth could
target. The negative examples are what make that rule usable, so they
are recorded rather than left to be rediscovered:

- padding class **is** a branch, in `base64-encode`, and the paired
  mutation above lived through every suite until all three classes
  appeared nested;
- the **first** element of a list and a later one are two branches —
  two separate `emit` call sites — and a mutation in the first-element
  site alone stayed green until `head-of-list` became a position. A
  vector deliberately gets no such pair: all its elements go through one
  call, with only the separating space conditional, so there is no
  branch for a mutation to sit in and the cell could not fail;
- the **compound types themselves** — `()`, a vector, a proper list, a
  dotted pair — are four more arms of the writer, and none of them had
  ever been nested. A mutation writing `()` as `#f` in the
  later-element call site alone survived everything. They were missing
  for a reason worth naming: the product-fullness check builds its rows
  from the cells that exist, so a type with *no* cells at all is
  invisible to it. **Absence cannot be found by a check that enumerates
  what is present** — only by comparing against the writer's arms;
- padded versus unpadded base64 **spelling** is not: `=` is skipped and
  never counted, so `#vu8"AQI"` and `#vu8"AQI="` traverse identical
  code and no mutation separates them. An anchor for it would be a
  check that cannot fail;
- a flonum's *class* (infinity, NaN, zero) is not: every double takes
  one path out of the writer.

The way that was settled is worth keeping too. A mutation intended to
isolate the unpadded spelling turned three suites red — which proves
not that the spelling is covered, but that **the mutation failed to
isolate the quantity being asked about**. Blast radius is how you tell
a check that cannot fail from one you have not yet aimed properly.

**Every** anchor records what its value is, and a nesting cell also
records where it puts it — as data, with the name *derived from the
value* rather than typed beside it. Recording it only for the nesting
cells left a top-level branch checked against nothing finer than its
type: swapping the values and wires of `boolean/true` and
`boolean/false` left both names false with everything green. Both consumers pin the
`(branch, atom)` **pair**, because checking the atom against the value
but not against the branch carrying it left the whole contents of two
anchors swappable — `boolean/true` and `boolean/false` traded values,
wires and atoms with both names left false and everything green. What
this still does not discriminate is a pair of branches that *share* a
label: `flonum/half` and `flonum/repeating` are both `flonum`,
`integer/positive` and `integer/negative` are both `small-integer`, so
those names remain conventions rather than checked claims.
Without that the branch name is the only thing claiming a bytevector is
involved, and a name is not a check: replacing the bytevector atom with
the integer `255` left every branch called `bytevector-*` holding an
integer, with nothing red anywhere. A merely-broad check is not enough
either — with the atom verified only as "an integer", the same swap
still passed, and giving `bytevector-pad1` a four-byte value moved it
into the `==` class and silently undid a whole round's padding
coverage. So each consumer re-derives the *discriminating* predicate
from the branch name — `bignum` means past the fixnum limit, `pad1`
means length ≡ 2 (mod 3), `negative-zero` means the sign bit is set —
and asserts the name, the columns and the decoded value all agree.

The branch names are pinned on both consumer sides, in both directions:
a branch that stops being generated fails by name, and a branch the
fixture carries that nobody pins fails too. It did not start as a
product at all — it was a list that grew by one entry each time a review
named a paired mutation that had survived, which is the same shape the
symbol matrix had before it was closed, and it has the same failure
mode: what is still uncovered stays a question about someone's
imagination. Making it a product moves that question to the dimensions.

Some cells of the product are not data this format has, and those are
**recorded rather than skipped**. A tail that is itself a pair or the
empty list merges into the enclosing list — `(a . (b …))` *is* `(a b …)`
— so the empty list, a proper list and a dotted pair cannot occupy a
tail position distinguishably. The generator drops those three cells and
writes them into the fixture as `nesting_holes`, each with its reason;
both consumers require the product to be full *except exactly those*,
and require each reason to **say the identity it rests on** — `(a . (b
…))` *is* `(a b …)`. Requiring merely a non-empty reason was the whole
test for a while, which let any plausible-sounding sentence excuse a
missing cell. An absent cell is then either a stated
fact about the format or a failure, never a silence.

Getting that criterion right took two tries, and the second is the
interesting one. The first version asked whether the wire contained a
dot — which catches the empty and proper lists and *misses* the dotted
pair, because `(a . (b . c))` writes as `(a b . c)`, dot and all, while
being the same datum as a two-element improper list. Scheme's
representation hides that; the JavaScript model, where a dotted list is
items-plus-tail, surfaced it as a failing assertion immediately. The
criterion is now structural rather than textual. **Two implementations
with different internal shapes are worth more than two with the same
one** — this is the second time the disagreement between them was what
found the bug.

Three things a product alone would not establish, so each is asserted
separately:

- **Pairs whose evidence is that they differ.** Carrying both a lower-
  and an upper-case symbol proves nothing if something upcases on the
  way through — each anchor would still decode to the value its own spec
  describes. The pairs that must not collapse (the two zeros, the two
  infinities, quiet NaN against a NaN with a payload, the case pair, two
  control characters, the empty list against the empty vector, and the
  two spellings of one control character) are asserted to be different
  *wires*.
- **The `type` column is true.** It is checked against the value the
  codec returned, so it is a claim the fixture has to earn rather than a
  comment that happens to live in a data file.
- **No cell is another cell under a second name.** A product can have
  degenerate cells — consing the empty list as a tail gives back a
  proper list, which is an anchor that already exists — and such a row
  looks like coverage while adding none. Duplicates are judged by the
  **value each spec denotes**, not by the spec text: `Q 710 226` and
  `Q 355 113` are one datum spelled two ways, and comparing text let a
  semantic duplicate through. The generator refuses to emit one, and
  both consumers check again, because a fixture can also be edited.
- **`direction` is not taken on trust.** It is the generator's
  measurement, and a fixture that downgraded a measured `both` to `read`
  would buy itself a *skipped* writer check. So `read` is asserted too,
  as the writer **not** producing that wire — our writer must agree with
  the authority, and the authority does not emit it.

The spec language has **three** readers — the generator's, and one in
each suite — and they must refuse exactly the same programs, or a spec
denotes different values in different places. That was not true until
it was checked: every reader folded any character as a digit, so `N Z`
denoted 42 (`'Z' − '0'`) in the two consumers while the generator's
`string->number` answered something else again. `S 1 255` was worse: a
lone `0xff` became U+FFFD in Chez, a byte string in Goeteia and a
refusal in JavaScript — one program, three values.

The first repair was a shared list written out in all three places, and
it lasted exactly one round: the next revision extended two copies and
left the third at its old contents, while the report said "one shared
list, all three". So the list is no longer copied. The generator holds
it, runs it against its own reader before writing anything, and **emits
it into the fixture**; both consumers read it from there. Three copies
cannot be kept in step by discipline, and the fixture was already the
one thing all three sides share.

It comes in two halves, and the second is not decoration: a reader that
refused *everything* would satisfy the malformed half perfectly. Each
consumer pins the corpus size, names the malformed programs that were
real defects, and refuses a corpus with a duplicate in *either* half —
a truncated list passes every line of a loop over it, and a duplicate
lets one program be swapped out while the size still matches.

The well-formed half carries a **`why`**, and the `why` is what is
pinned rather than the program. Each entry exists to reach one reader
path — the sign arriving on a *denominator* is not the same code as the
sign arriving on a numerator — and pinning only the size and the
programs left that substitutable: replacing `Q 1 -2` with `N -0` and its
authority wire kept the count, the uniqueness and every value/wire
comparison green while the denominator-sign path stopped being exercised
at all. Both consumers pin the `(program, why)` **pair** — pinning the reason
alone was not enough, because program uniqueness, the program/wire
comparison and `why` membership are three independent checks, so
swapping the program while keeping its reason satisfied all of them and
the claim outlived its own subject. Same shape as the holes: **the
reason is data** — and a reason has to be attached to something.

The well-formed half carries **the authority's bytes for the value each
program denotes**, not just the program. It used to check only that a
reader did not raise, and that is a weaker thing than it looks: a reader
taking a ratio as *n*/|*d*| makes `Q 1 -2` denote +1/2 and stays on the
list, accepted and wrong. Now each reader must read the program, write
the value, and match bytes the authority produced.

One more shape is worth naming because it is invisible from inside a
single reader. **A tag that can produce a datum outside the kind it
names has stopped naming that kind.** `P` means *improper list*, and
nothing stopped `P 1 N 1 NIL` from denoting the proper list `(1)`, which
`L 1 N 1` already spells; left open, a `value->spec` that encoded every
proper list as `P n … NIL` passed the generator's own inverse check,
both consumers and every downstream suite while `P` quietly stopped
meaning what its documentation says. `Q` had the same defect one tag
over: `Q 4 2` is 2 and `Q 0 7` is 0. Both now refuse — `P`'s tail must
be an atom, `Q` must reduce to a ratio.

Twice the rule was fixed one level too shallow: `P` first refused only
`()`, and a nested `P 1 N 1 P 1 N 2 N 3` walked straight through. **A
spelling-uniqueness rule has to be stated over the whole family at
once**, which is why it is now the same sentence the degeneracy check
uses — a tail that is a list merges into the enclosing list.

Not every alias is a defect, and the distinction is worth stating so the
rule does not over-apply. `NIL` and `L 0` both denote `()`; that is
harmless, because neither tag claims anything the other contradicts.
The well-formed corpus is *deliberately* full of aliases — `Q 1 -2` and
`Q -1 2` denote one value and record one wire — because each spelling
reaches the reader's normalisation by a different route, and a reader
handling the sign on the numerator but not the denominator is exactly
what that half exists to catch.

A malformed spec must never read as a shorter valid value. The first
spec reader returned a sentinel and dropped the rest of the program, and
the sentinel was only looked for at top level — so `L 1 Z` read as the
perfectly good datum `(spec-unknown-tag)`, and an anchor pairing that
spec with that wire **passed**. Failure now propagates, every arm checks
that its tokens are there, and both readers refuse the same list of
malformed programs.

`test/sexpr-limits.ss` keeps a smaller, closed set of the same
value-level checks whose expected bytes are **literals in its own
source**. Everything the matrix knows it learns from the fixture, so a
fixture regenerated against a broken authority takes the matrix with it;
that leg stays standing. Two mechanisms reaching one answer by different
routes is the point. New value coverage goes in the generator's matrix,
not there.

There is deliberately no non-ASCII **symbol** branch: the authority
refuses to write one, so there is no wire to anchor it to. Which names
it refuses is the `write_reject` matrix's question.

## Regenerating the fixture

Running the suite needs neither Chez nor igropyr; the fixture is
committed. Regenerating it needs both:

```sh
cd ../01-igropyr
scheme -q --libdirs . --script ../03-goeteia/test/gen-sexpr-vectors.sc \
    ../03-goeteia/test/sexpr-vectors.json
```

The generator refuses to produce anything unless seven things hold. Each
was added after someone asked what the previous set actually proved:

1. **The source is what answers.** A compiled `sexpr.so` shadows
   `sexpr.sc` under the default library extensions, and a stale one
   answers for a version nobody is looking at. That is not
   hypothetical: the first fixture was generated that way, against an
   artifact weeks older than the commit recorded beside it.
2. **The commits are read in-process, one per measured file.** Two
   files are measured — `sexpr.sc` and `crypto.sc`, which supplies
   base64 and so decides half the accept/reject boundary — and they
   move independently, so a single id names only half of what ran.
3. **Each file matches the blob of the commit being recorded**, byte
   for byte. `git status` is not asked: a file marked
   `assume-unchanged` or `skip-worktree` carries modified bytes while
   status stays silent, and a status command that fails to run prints
   nothing at all, which reads as "clean".
4. **The path the import resolves through is the path that was
   checked.** The library name resolves via an `igropyr/` directory —
   a symlink in this checkout — while the guards read `./sexpr.sc`;
   repoint it and every other check still passes, so the bytes reached
   through both paths are compared.
5. **The bytes are captured before the import** and re-checked after
   the last measurement, and the fixture is written to a temporary file
   that only takes its place once that check passes. (The first version
   of that check ran after the real file had already been written: it
   aborted saying "nothing written" while the fixture sat there. A
   guard that fires is not yet a guard that is right.)
6. **The library search path is the current directory and nothing
   else.** The checks above compare bytes at two *paths*, which says
   nothing about which directory Chez searched first: `--libdirs
   /elsewhere:.` loads a substitute while every byte, commit and
   cleanliness check still reads the normal checkout, and the sentinels
   only cover the two behaviours they name. This one was added on a
   demonstrated bypass, which is the standard the list is extended on.
7. **Two sentinels.** base64 must put `#vu8"A"` at empty and refuse
   `#vu8"AB"` — the non-canonical-tail rule half the read verdicts turn
   on — and the writer must refuse the symbol `0x10`, behaviour the
   authority only gained in `08cc3f8`, which is what makes it
   discriminating. They establish that the behaviour is *present*, not
   why it is absent: an older artifact, a substituted one and a newer
   one that regressed all fail identically, and the messages say so
   rather than guessing a cause.

**This list is closed.** Each guard was added because someone asked what
the previous set actually proved, and that question has an unbounded
number of answers — but a guard is code, and every layer is one more
surface that can be wrong in its own right, as the fifth one was. The
threat model here is bounded: the generator is run by hand, on one
machine, and its product is checked afterwards by three independent
implementations, by membership and count assertions, by the sentinels,
and again when igropyr re-vendors the fixture. A bad golden cannot
reach production quietly; it turns something red on the way. Further
hardening would be plating the measuring instrument. Extend this list
when a real incident shows a gap, not in anticipation of one.

### What this evidence does not cover

Stated because the alternative is an implied clean bill. Five residuals,
each confirmed by the independent review rather than only by us:

1. **Conformance, not correctness.** Everything here pins agreement with
   `(igropyr sexpr)`. If the authority itself is wrong about the wire,
   three implementations agreeing with it is exactly what this tree
   would show. Closing that needs a second, independently written
   specification to check the authority against — not another consumer.
2. **Depth 1 and 2, out of a limit of 64.** The semantic anchors put an
   atom one and two levels down. The boundary is exercised, but by
   round-tripping vectors rather than by value, so a writer wrong only
   at depth 30 would pass. The cost of closing it is a depth dimension
   in the product; the reason it is open is that no branch in the codec
   distinguishes depth 3 from depth 30.

   Worth knowing while reading those probes: **what sits innermost
   moves the boundary.** 65 nested lists ending in `()` is accepted;
   65 ending in `1` is refused, because the empty list is recognised
   where an atom costs one more descent. The probes are named
   `-empty` and `-atom` for that reason — two inputs with the same
   parenthesis count and opposite verdicts should not have
   near-identical names.
3. **No provenance between generation and commit.** The generator is run
   by hand and its output is trusted once written. The fixture records
   the *path* of the generator, not its hash, so generator-only drift,
   or a change to metadata no consumer reads, can survive. Semantic
   corruption usually fails a suite — usually is not always.
4. **A transient swap during the import.** The byte captures rule out a
   change that persists across the run; they do not rule out replacing
   the library file after the capture, letting Chez import it, and
   restoring the original before the checks. The only thing that closes
   it is fingerprinting what was actually instantiated — asking the
   runtime rather than the filesystem. Holding the file open does not
   (a descriptor pins an inode while the import resolves a path), and
   neither does a lock (it would have to be honoured by whoever replaces
   the file, which is the one party we cannot constrain). The threat
   model here is one person on one machine, so it is recorded rather
   than defended.
5. **NaN payloads are measured, not guaranteed.** The wire carries the
   bits; whether a host double preserves a payload is the engine's
   business, and no language contract promises it. Three NaN bit
   patterns are anchored, so an engine that started canonicalising would
   arrive as a failing anchor rather than as silently altered data.

Entries too large to carry literally (a 65-kilobyte token, a
70-kilobyte bytevector) are stored as the rule that builds them, and
the generator checks that rule against the authority's actual output
before writing it — no byte of the fixture is hand-written or
unverified.
