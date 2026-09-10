# Game scaffolding

The `(gam …)` libraries hold the bookkeeping a game repeats and none of
the numbers a game chooses. The manual documents what each name does;
this file is why each of them is shaped that way, because most of these
decisions look like preferences until the failure they prevent is
written down beside them.

Thirteen libraries: `stats`, `inventory`, `quest`, `effects`,
`abilities`, `save`, `modifiers`, `recovery`, `fields`, `timeline`,
`window`, `party`, `state`. None of them knows any other exists. Ten
import nothing but `(rnrs)`; the three that import anything reach
outside this family rather than into it — `save` writes through `(web
js)`, `party` is over the handles from `(sim entity)`, and `state` is a
mutable owner for `(lng machine)`. That is not modularity for its own
sake — §14 is about what tying two of them together would have cost.

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

## `(gam modifiers)` — whose contribution is whose

**A source holds at most one claim on an attribute, so applying it again
replaces its own claim and leaves every other source alone.** That one
rule is what the library is for. Without it, the natural way to write
"refresh this" is remove-then-add, every caller writes it slightly
differently, and the two ways of getting it wrong fail in opposite
directions: forget the remove and the thing stacks with itself, remove
too much and somebody else's claim disappears. Here it is one call that
cannot do either.

**Claims with no group add. Claims sharing a group are mutually
exclusive, and the largest *magnitude* wins.** Largest by absolute
value, so the strongest penalty wins among penalties exactly as the
strongest bonus wins among bonuses — a rule stated once that does not
need a second clause for negative numbers. Groups are judged
independently of each other and then added, so what comes out is "the
best of these three, plus the best of those two, plus everything
ungrouped".

**A dispel removes claims by dispellability, not by group.** If the
claim that was winning a group is dispelled, the group is not emptied —
the next largest magnitude in it takes over, and the total moves to that
instead of to zero. This is worth knowing before writing a dispel
effect: stripping the strongest curse can leave the second strongest
applying, which is usually what a design wants and never what a reader
assumes without being told.

**The multiplicative part is the caller's table.** Some designs want an
attribute whose total is scaled by a second attribute, itself
modifiable. Which one scales which is a question about a particular
design, so `make-modifiers` takes a procedure that answers it, and there
is no built-in mapping at all. A fixed list here would be the worst
option available: an attribute nobody thought to add to it gets no
scaling, nothing says so, and **the failure is a number that is quietly
too small forever**. With no procedure, nothing is scaled — which is a
rule a reader can state, unlike the contents of a list.

The scaling applies one level deep. The scaling attribute's own total
obeys the same stacking rules but is not itself scaled, even if the
procedure names a scale for it, so a mapping that answers an attribute
with itself is arithmetic rather than a loop.

**Why this is not part of `(gam stats)`.** A pool has a value and a
maximum; an attribute here has no value of its own at all, being only
ever the sum of what is claimed about it right now. And modifiers
expire, which puts them on the other side of the line §2 draws: `(gam
stats)` deliberately holds no timer, and a timed state living there
would make `stats-damage!` depend on a clock that library does not own.
Here the clock is in plain sight in `modifier-tick!`.

**Why it is not `(gam effects)` either.** That answers "is this state
on, and for how much longer". This answers "what does everything come
to, and whose is it". A caller can want both about the same spell, and
neither is derivable from the other: effects has no magnitude to add up,
and nothing here says whether a state is on.

## `(gam recovery)` — one claim, and the two ways to lose it

A recovery holds one number and whether the claim on it is still open.
Recording a loss opens a claim; claiming answers a fraction of it and
closes the claim for good.

**It does not take the amount from anything and it does not give it
back.** Both are the caller's. Handing it the thing the amount lives in
would tie two independent parts together permanently — the claim could
then only ever be against that one kind of store, in that one currency —
and worse, it would put the arithmetic of somebody else's store in here,
where the rules that store enforces, a floor, a cap, what happens at
zero, are neither known nor checkable.

**So the caller clamps, not this: record what was *actually* taken.** A
store that held 30 when 50 were demanded lost 30, and if 50 is recorded
here the claim is for points that never existed and the caller hands
back more than it took. This cannot detect it; the only place both
numbers are known is the call site.

**A SECOND LOSS REPLACES THE FIRST.** There is one claim, not a queue of
them, so recording a loss while a claim is still open abandons it — the
earlier amount is gone and unrecoverable. This is the rule in this
library that silently destroys value, and it is worth reading twice. A
caller that wants the earlier claim kept must read `recovery-open?` and
decide *before* recording. A caller that wants several claims at once
wants several recoveries, one per thing being claimed.

**CLAIMING CONSUMES THE CLAIM EVEN FOR NOTHING.** A claim of a zero
fraction answers zero and closes the claim, because the operation is
"settle this claim now, at these terms" and not "collect what is
available". A caller deciding whether it can afford to settle asks
`recovery-pending` first, which changes nothing.

`recovery-open?` is not the same question as `recovery-pending` being
zero, and the difference is the reason both exist: a claim for zero is
open and will be consumed, while no claim at all cannot be. A caller
that tests the number instead of the flag treats those as the same, and
is right until the first loss that took nothing.

It does not round. Rounding would be a statement about what the number
counts — whole points round, a distance does not — and that is the
question this library already declined to answer when it declined to
know what the amount is.

## `(gam fields)` — the last partial period is paid

A field is a shape on the ground plane, a lifetime, and a rate. Step it
with elapsed time and every so often it hands the caller an amount: the
time accumulated since it last did so, multiplied by the rate.

**A field that expires part way through a period settles what it
accumulated rather than dropping it.** That is the whole reason an
accumulator exists here instead of a countdown. A region that lasts 1.1
periods should be worth 1.1 periods and not 1, and the alternative pays
out less the shorter the region is — **which is hardest to notice
exactly where it is worst**, at the short-lived regions where the
missing fraction is the largest share of the total.

The elapsed time is clamped to the life remaining, so a step longer than
the rest of the life pays for the part that was alive and not for the
whole step. Between them, those two rules mean the total paid over a
field's life is its lifetime times its rate, whatever sizes the caller's
steps happened to be.

**It does not know what an amount is.** The rate is a number the field
carries and multiplies by time; what the product means, and to whom, is
the caller's. A field that knew would have to know who is standing in
it, which is a question about a world it cannot see.

**It does not keep a list of what is inside it.** `field-contains?` asks
about one point and the caller loops over whatever it has. Holding a
list here would mean holding references to things that can go away
without telling this library, and every such list has to be pruned by
someone who knows when its entries died — see §12, where that problem
is solved for the one case that can be solved.

The containment test is two-dimensional, on x and z with a yaw, and
`(gfx collide)` has capsule tests in three. They are not two
implementations of one thing, and unifying them would make a library
that keeps time depend on the graphics stack to answer a question about
two coordinates. A radius with a zero half-length is a circle, which is
why there is no separate circle.

## `(gam timeline)` — a deadline is not a cadence

Scheduling puts a payload at now-plus-a-delay; ticking moves the clock
and answers everything that has come due, earliest first.

**Equal deadlines come back in the order they were scheduled.** Not in
whichever order a sort happened to leave them. This is the property a
caller depends on without noticing: a run reproducible from the same
inputs stops being reproducible the moment a tie is broken arbitrarily,
and the resulting difference appears somewhere far from the tie.

**A deadline counts as reached when it is within a small tolerance of
the clock, and `(sim step)` deliberately has no such tolerance.** The
two look like the same question and are not. Scheduling something 0.1
ahead and then ticking 0.1 three times leaves a deadline of 0.3 a
fraction of a bit past a clock that has summed to slightly under it, so
without the tolerance the payload waits for a whole further tick —
firing late, and firing at a moment that depends on how the caller
chopped up its elapsed time rather than on when it asked. A deadline
fires once: held back by a last-bit shortfall it is late permanently,
and there is no later tick at which it becomes on time.

A fixed step is the opposite case. Its steps are a repeating cadence, so
a step held back by the same shortfall is due again on the very next
advance and nothing is lost, while rounding a step *into* existence
would simulate more time than has passed — once per second, forever.
Same arithmetic, opposite right answer. **Neither file should be changed
to match the other**, and a reader who knows one of them should not
assume the other behaves the same way.

The tolerance is absolute rather than proportional, because the quantity
it corrects is absolute: it is the residue of adding ordinary elapsed
times. A caller running a clock in some much smaller unit wants its own.

**It does not read a clock and it does not run the payloads.** Time
advances only in `timeline-tick!`, by the amount passed, so the same
timeline runs at any speed, pauses without draining, and can be tested
an hour out without waiting an hour. Payloads come back as data: a thunk
says nothing about what it will do, cannot be inspected, and cannot be
judged stale — and staleness is the common case rather than a corner,
since whatever scheduled an action may be gone by the time it comes due.

There is no way to cancel one payload. Naming a single entry is a
decision belonging to the caller, which already has names for its own
things; a payload can carry a tag the caller filters on when it comes
due, which costs nothing here and obliges no other caller to a token
type it has no use for.

## `(gam window)` — an interval, and a ledger that keeps its promise

An action lasts some time, and the part of it that *does* anything is a
sub-interval of that, held as fractions of the duration so the shape of
the action survives being sped up or slowed down.

**`window-span` answers the slice of the live window the last step
passed through, not where the action is now.** That is the whole reason
the previous time is kept. A caller sampling only the current instant
would, on a long frame, sample an action that had already crossed its
target and never touched it: it was live between two samples and at
neither of them. A step longer than the entire window still reports the
entire window rather than skipping it. **This is the failure that makes
a game feel as though it drops inputs, and it gets worse exactly as
frames get longer** — which is to say it is worst on the machines least
able to afford it, and invisible on the machine it was written on.

**`window-mark!` is one call that answers whether it was the first.**
The alternative — ask whether it is marked, then mark it — is two calls
every caller has to remember to pair, and the version that forgets the
test still compiles, still runs, and touches the same thing twice on any
frame where the sampling caught it twice. A ledger whose name promises
"each thing once" and whose implementation appends unconditionally is
not a ledger; it is a list with a misleading name, and the promise lives
in whatever the caller remembered to write.

**`window-reset!` clears the ledger along with the clock, and it must.**
A second use that remembered the first one's targets would pass straight
through them without touching anything, which looks exactly like a
missed hit — a bug that presents as bad feel rather than as an error,
and that gets diagnosed as timing or as geometry long before anyone
looks at a ledger.

What counts as the same thing is the caller's: marks are compared with
`equal?`, so a handle from `(sim entity)` — a pair of two numbers —
works. `eq?` would fail silently on exactly those handles, because the
handle a caller kept and the handle it was just issued are equal without
being the same object.

It holds no geometry and no magnitude. The caller tests whatever it
tests, `(gfx collide)` having the shapes, and comes back to ask whether
a thing has been touched already.

## `(gam party)` — a recycled entity does not inherit a membership

Membership is an ordered list of handles from `(sim entity)`, plus at
most one selection which is either a member or nothing.

**It holds handles, not entities, and that is the whole reason it is
worth having rather than a list.** A handle is a slot paired with the
generation that slot is on. It stops matching the moment the entity it
named is destroyed, and it *keeps* not matching when the slot is later
reused by something else. A roster of direct references would quietly
acquire whatever took the dead one's place — the new occupant of the
slot silently inheriting the old one's membership, its selection, and
whatever the caller does to members. A roster of handles cannot, because
the generation the handle was issued for is not the generation the slot
is on any more. Every question here that a stale handle could answer
wrongly is asked of the store instead of assumed.

**It does not notice death by itself.** Nothing tells this library when
an entity is destroyed, so a destroyed member stays on the list until
`party-prune!` is called. That is deliberate, and it is why pruning is a
call rather than a hook: a hook fires in the middle of whatever
destroyed the entity, at a moment the caller did not choose, and the
caller usually wants to know *who left* — which it can see by comparing
the members across a prune, and could not see from inside a callback
that had already removed them. In the meantime the roster is not lying:
it answers handles, and a dead handle answers dead to anyone who asks.

**The selection is a member or it is `#f`, with no third state.**
Selecting a non-member raises rather than joining them, because the two
are not the same intent and a `select!` that quietly added would let a
typo grow the roster. Removing the selected member clears the selection
rather than moving it to a neighbour: there is no neighbour this library
could pick that the caller would not have to check anyway, and a
selection that moves on its own is how an input arrives at whoever
happened to be next.

It does not decide how many may join. A limit is a rule about a
particular design, and a caller with one tests the length it already has
before it adds.

## `(gam state)` — a mutable owner, and what a datum cannot carry

`(lng machine)` is the state machine: a spec that is a datum, guards and
actions that are names, and a machine *value* that never changes —
`machine-step` answers a new machine rather than altering the old one.
That is the right shape for something to be written to a file, read
back, diffed and drawn. It is not the shape of a thing in a world, which
has one current state and many observers that do not all know each
other. Threading a new value out to every one of them means every one of
them has to know where the value is kept, which is to say the owner gets
written again at each of them, slightly differently. This library is
that owner, written once.

**The cell is replaced only by a step that returned.** `machine-step`
raises when more than one guard holds, and raises for an event with no
transition if and only if the spec says `(on-unknown error)`. Because
the cell is written only with what that call returned, a raise leaves
the previous machine in place: the thing is still in the state it was
in, and a caller that catches the condition is looking at a machine no
partial step has been applied to. This is the property that makes a
mutable owner safe to have, and it is worth stating because it is
invisible at the call site.

**Without that clause an unknown event is a quiet no-op**, and that is
the default. The machine comes back unchanged and the actions are empty
— which is also what a transition carrying no actions answers, so on
such a spec `state-send!` cannot tell a caller whether anything
happened. That is why `state-transition!` exists beside it: it reports
as a boolean whether the event was available. A caller that would rather
the mistake raise puts `(on-unknown error)` in the spec.

**`state->datum` carries the spec, the current state, the context and
the strictness. It does not carry the bindings, and it cannot.** Those
are procedures; the spec names them, and `datum->state` takes them
again. Reading a datum back with bindings that do not cover the names in
its spec raises rather than producing a machine with holes in it. This
is the part to plan for when a saved machine is loaded on the other side
of a restart: the datum is portable, the behaviour behind the names is
code, and the two are rejoined deliberately rather than by accident.

The context travels only if it is itself a datum. `state->datum` refuses
a context containing a procedure or a cycle rather than writing
something that cannot be read back, so the failure arrives at the write,
naming the context, instead of at the load.

Two transitions sharing a from-event key with no guards are refused by
`make-machine`, so a spec like that never becomes a machine and no
caller of this library can be holding one. Two sharing that key *with*
guards are accepted, because whether both can hold at once is a question
about the guards rather than about the spec; if both then do hold, the
step raises. Nothing here picks a winner either way.

## Why they do not know about each other

`(gam abilities)` carries a cost it never spends. `(gam effects)` holds
a timer that `(gam stats)` never consults. `(gam window)` marks a target
it cannot describe. `(gam recovery)` keeps a claim against a store it
never touches. `(gam fields)` multiplies a rate by a time and hands the
product to somebody else. Each of those is a place where one library
could have called another, and each was left unconnected on purpose.

The test is what the connection would fix versus what it would fix in
place forever. An `ability-use!` that spent from a stats value would
save the caller one line and permanently decide that abilities are paid
for out of pools. A `stats-damage!` that consulted an effects value
would save a caller one branch and permanently make damage depend on a
clock it does not mention. In both cases the saving is one line at the
call site; the cost is a rule that every future caller inherits and
cannot opt out of.

That is why ten of the thirteen import `(rnrs)` and nothing else, and
why a project takes the two it wants and leaves the rest.

The three that do import something are the same test coming out the
other way. `(gam party)` is over `(sim entity)` because the generational
handle *is* the thing it is for — a roster that did not use one would be
a list, and §12 is the failure that follows. `(gam state)` owns a `(lng
machine)` because an immutable machine and a mutable owner are two
different shapes for two different jobs, and this library is only the
second one. `(gam save)` reaches `(web js)` because a store is
somewhere, and there is no version of "write this down" that is pure. In
each case the import is the library's subject rather than a convenience
it reached for, which is the line the other ten stay on the near side
of.
