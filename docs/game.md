# Game scaffolding

The `(gam …)` libraries hold the bookkeeping a game repeats and none of
the numbers a game chooses. The manual documents what each name does;
this file is why each of them is shaped that way, because most of these
decisions look like preferences until the failure they prevent is
written down beside them.

Six libraries, each importing nothing but `(rnrs)`: `stats`,
`inventory`, `quest`, `effects`, `abilities`, `save`. None of them knows
the others exist. That is not modularity for its own sake — §7 is about
what tying two of them together would have cost.

## `(gam stats)` — pools that are named, and a level system that is not here

**Pools are named because indices fail silently.** The obvious
representation is a fixed vector: slot 0 is health, slot 2 is mana, and
every call site agrees to that without anything writing it down. Getting
one index wrong there does not raise — it reads and writes the wrong
pool and keeps going. A name that is not a pool raises, by name, at the
call that used it. Nothing answers zero or `#f` for an unknown pool
either: a typo that reads as an empty pool is a bug found in a playtest
rather than at the call, which is a difference of days.

**The level curve and the level reward belong to the caller.** The code
this grew out of had `80 * level` to advance and `+20` health, `+10`
mana per level compiled into it. Numbers like that are a game's design,
and a library holding them can be used only by the game it was cut from.
So the curve is a procedure the caller supplies, the reward is a hook
the caller supplies, and with neither of them experience simply
accumulates and no level is ever gained — deliberately not an error,
because a game that tracks experience without levels is a game.

A curve that answers a cost of zero or less is refused rather than
believed. The loop would raise a level for free and never terminate, and
**a hang is a far worse diagnosis than a named error**: it says nothing
about which level's cost was wrong, and it looks like the program is
working.

**There is no invulnerability timer, and that absence is the decision.**
The library this grew out of had one, as a field on the stats value, and
`stats-damage!` consulted it. That makes the meaning of "damage" depend
on a clock that appears nowhere in its arguments: the same call
subtracts or does not, and **a reader of `stats-damage!` has no reason
to know there is a timer to look for**. A temporary state belongs with
the other temporary states, in `(gam effects)`, and a caller decides
immunity *before* it calls — in its own code, where the decision is
visible. That is one line more at the call site and one fewer invisible
dependency in the library.

**Spending is all or nothing.** A partial spend is the worst of the
three possible answers: the caller's action proceeds having paid less
than it asked to, and the pool is left at a value neither side chose.
`stats-damage!` and `stats-heal!` answer what *actually* happened rather
than what was asked for, because a caller that reports damage, or feeds
a counter with it, needs the number that happened.

## `(gam inventory)` and `(gam quest)` — order that does not come from history

These two are together because they answer one question differently and
the difference is the point.

**Why order is maintained rather than computed.** Byte-for-byte
agreement between the two compiler targets is a tested property of this
system (`docs/determinism.md`). A listing whose order came out of a hash
table would break it invisibly: a saved game, a rendered list, a
checksum over the bag would each differ for no reason a reader could
see. And **this tree has no `sort`** — so an order cannot be recovered
after the fact by sorting. It can only be *maintained*, from the moment
the first key goes in. That constraint decided the representation before
anything else did: an association list with the insertion order intact,
not a table.

Keys are compared with `eq?`, so they must be values `eq?` is dependable
on — symbols, characters, booleans, fixnums. A string or a large integer
is refused rather than accepted and then silently never matched. On
large integers that is not a theoretical worry: `eq?` on two separately
computed equal ones answers `#f` on wasm and `#t` on JavaScript
(`docs/determinism.md`, D2a), so the same bag would behave differently
on the two targets.

**Taking an item down to zero keeps its row and its place.** Dropping
the row would send the key to the end when it is added again, and the
listing would become a record of what the player *did* rather than of
what the bag holds. Two players with the same items would get different
listings.

**An objective that runs out is not the same fact.** In `(gam effects)`,
a name whose duration reaches zero is *removed*, and setting it again
puts it at the end. That is deliberately unlike the inventory, and the
reason is that the two zeros mean different things: **a count of zero
means the thing is still there and there are none of it; a duration of
zero means the state is gone.** Two different facts should not have one
representation.

**`quest-keys` answers in the order the quest declared, never in the
order the events arrived.** Reporting arrival order looks equivalent and
is not: it turns every listing into a record of the route taken, so two
players with the same objectives met get different answers, and the same
save file reloads differently depending on what the player did first.
The quest that ends up compared against another quest's listing is the
one that ships broken.

**Recording is idempotent** because the event behind an objective is
usually a collision, a trigger volume or a message bus, and none of
those promise to fire once. `quest-record!` answers whether *this call*
advanced the quest, so a sound or a line plays exactly once. An
objective the quest does not require answers `#f` rather than raising: a
shared bus carries everything to everyone, and a quest that raised on
someone else's objective could not be attached to one at all.

**A repeated objective in the required list is refused** because
`quest-complete?` compares a count of distinct objectives against the
length of that list. A duplicate makes the denominator larger than the
numerator can ever reach — a quest that can never be completed, and a
failure that shows up only when a player gets all the way to the end.

## `(gam effects)` — replacing a duration, not maximising it

**Setting a name that is already running replaces its duration.** It
does not take the larger of the two and it does not add them. Those are
three different rules — refresh, extend, let the longer one win — a game
can want, and a player can feel the difference between them. A library
that picked one would be making that choice for every game that used it.
A caller who wants the longer of the two reads `effect-ref` first and
sets the maximum itself, in its own code, where the rule is visible to
whoever reads that code next.

**Subtract first, then drop what has run out** — in that order, so an
effect with exactly `dt` left is gone after the tick that consumed it
rather than one tick later. Reaching zero *is* running out: an effect
with no time left cannot be observed for any span, and keeping it would
make `effect-active?` true for a state that gates nothing.

`effect-ref` answers `#f` rather than `0` for a name that is not
running, because zero is a duration this library never stores — a
duration of zero is refused at `effect-set!` too. Answering `0` would
put a real value and an absence into the same answer, which is the
`(gam save)` mistake (§6) one library over.

## `(gam abilities)` — a cooldown, and nothing else

**`ability-use!` does not spend the cost.** It moves the cooldown and
answers whether it moved; it does not touch a pool and does not know
that pools exist. The cost is a number the ability *carries*, for the
caller to subtract wherever its resources live:

```scheme
(when (and (ability-ready? fireball)
           (stats-spend! player 'mana (ability-cost fireball)))
  (ability-use! fireball)
  ...)
```

The version this grew out of took a stats value and spent from it. That
ties two independent parts together permanently: the ability can then
only ever be paid for out of that one kind of thing, in that one
currency, and an ability that costs two resources, or none, or shares a
cooldown with another ability, stops fitting. Keeping them apart costs
the caller one line and buys every combination. It is also why
`(gam abilities)` imports nothing but `(rnrs)`: the dependency that
would have existed is exactly the one that would have narrowed it.

**Damage and range are gone.** They were fields on the ability. They are
a game's numbers, not a cooldown's; an ability that heals or opens a
door has neither, and a library storing them tells every caller that an
ability is a way of hitting something. The general rule this and the
missing invulnerability timer both come from: **a part maintains the
state of its own one thing, and nothing else.**

**`ability-cooldown` is configuration; `ability-remaining` is state.**
The names are worth keeping distinct in a reader's mind because code
that confuses them reads as though it works. (The version this grew out
of had `ability-cooldown` returning the *remaining* time and
`ability-duration` returning the length.)

A cooldown of zero is refused: an ability that is instantly ready again
has no cooldown, and expressing it with this type only hides that every
`use!` and `tick!` around it is doing nothing.

## `(gam save)` — four disappointments, and one that is not one

The whole design is one distinction:

| situation | answer | why |
|---|---|---|
| nothing stored | `#f` | about the save: there is nothing usable, start fresh |
| a version this build cannot read | `#f` | same |
| contents the caller's validator rejected | `#f` | same |
| text that is no longer readable | `#f` | same |
| **no local storage, or it refuses to be written** | **a named error** | **about the machine** |

Collapsing the last row into `#f` with the others produces the worst
failure a save system has: **every launch starts a new game, every save
appears to work, and nothing is ever written.** Nothing raises, nothing
logs, and the player's report is "it forgot everything" with no way to
tell it from "I never saved". `save-available?` exists so a caller can
ask that question once at startup rather than by having a load raise.

**`save-write!` is deliberately not symmetric with `save-load`.** A
value the validator refuses is a named error on the way in, and a `#f`
on the way out. On the way in, the caller *assembled* the thing it is
trying to store: that is its own bug, and answering `#f` would let a
game write nothing for an hour and find out at the next launch. On the
way out, a rejected value is a fact about a file that an older build or
a text editor may have produced — not the caller's mistake, and not
worth ending a launch over.

**The version wraps the value; it is not written into it.** The version
this grew out of did `(js-set! value "schema" …)` — that is, the save
procedure *modified the caller's own object*. Wrapping instead means the
caller's value is never touched, and the validator sees only its own
datum rather than a framework field it has to know to ignore.

**The stored text is an s-expression, not JSON.** `(web sexpr)` is
already this system's wire format, and a save file is exactly the kind
of data a decimal round trip quietly damages: exact and inexact numbers
keep their kind, and a flonum crosses as its eight IEEE bytes, so
`-0.0` comes back with its sign. Measured, not assumed — a round trip
of `(hero (x . 1.5) (y . -0.0) (hp . 7))` returns `1.5`, an exact `7`,
and a `-0.0` whose reciprocal is still negative. Anything off the
format's whitelist fails loudly instead of arriving as something else.

### Why there is JavaScript inside this library

A store can throw: a browser in a private window keeps `localStorage` in
place and refuses `setItem`, and a full quota does the same. The design
above needs to turn that refusal into a named error — and it cannot be
done in Scheme here, because of a measured fact:

**A JavaScript exception is not a Scheme condition in this system.**
`guard` does not see it and the program ends.

```scheme
(guard (e (#t 'caught)) (error 'x "boom") 'not-caught)      ; => caught
(guard (e (#t 'caught)) (js-call throwing-js-fn …))          ; prints the JS
                                                             ; message and the
                                                             ; process ends
```

So the try/catch has to exist on the JavaScript side of the call for the
refusal to come back as a value at all. That is what the bridge in
`lib/gam/save.ss` is: three functions installed with `js-eval` that
answer a status instead of throwing — the same shape `(web sexpr)` uses
for its float codec.

**The status is a number, not a boolean.** "The store is unusable" and
"nothing is stored under that key" would *both* be falsy, and collapsing
them is precisely the distinction the whole library exists to keep. `0`
is unusable, `1` is usable-and-empty, `2` is usable-with-a-value.

`save-available?` writes and removes a probe key rather than checking
that `localStorage` exists, because **a store that is present is not the
same as one that accepts a write** — which is the case this library was
written for.

## Why the six do not know about each other

`(gam abilities)` carries a cost it never spends. `(gam effects)` holds
a timer that `(gam stats)` never consults. Each of those is a place
where one library could have called another, and each was left
unconnected on purpose.

The test is what the connection would fix versus what it would fix in
place forever. An `ability-use!` that spent from a stats value would
save the caller one line and permanently decide that abilities are paid
for out of pools. A `stats-damage!` that consulted an effects value
would save a caller one branch and permanently make damage depend on a
clock it does not mention. In both cases the saving is one line at the
call site; the cost is a rule that every future caller inherits and
cannot opt out of.

That is why every one of the six imports `(rnrs)` and nothing else, and
why a project takes the two it wants and leaves the rest.
