# Simulation

The half of an application that is not drawing: who exists, what runs
each tick, who hears what, and how time and chance are made repeatable.

These libraries know nothing about a renderer.  `(gfx fx)` uses
`(sim step)`; nothing in `(sim ...)` uses anything in `(gfx ...)`, and
that direction is deliberate — a headless test, a server, or a tool
should be able to run the simulation half with no canvas anywhere.

They were written from a consumer's own versions.  The pieces that were
general are here; the pieces that were that game's — hit points, an
experience curve, an instance layout, a storage policy — stayed there.
Deciding which was which was most of the work, and the rule used was:
if a name in it only means something inside one game, it is not a
library.

## `(sim entity)` — who exists

A fixed-capacity store of entities, addressed by handles rather than
indices.

```scheme
(define w (make-entities 4096))
(define player (entity-spawn! w))
(entity-set! w player 'hp 100)
(entity-ref w player 'hp 0)            ; => 100
(entity-each w (lambda (h) ...))
(entity-destroy! w player)
```

A handle is a slot together with the generation that slot was on.
Destroying an entity advances the generation of its slot, so every copy
of the old handle — the one in a scheduler, the one in an event payload,
the one someone saved — stops matching permanently.

An index cannot do this. An index into a live array is always "valid",
so on the day its slot is reused, every stale copy starts addressing a
stranger, with no error and no way to notice. That is the entire reason
this library exists; the rest is bookkeeping.

- **Capacity is fixed.** Running out is an error rather than a silent
  reallocation, because the moment a simulation stops being bounded is
  worth knowing about.
- **Writing through a dead handle is an error**, and reading through one
  answers the default. Writing to something that no longer exists is a
  mistake in the caller; asking whether something is still there is not.
- **`entity-each` walks a snapshot.** Entities destroyed during the walk
  are skipped; entities spawned during it are visited on the next walk,
  not this one. Without that, spawning from inside a walk could extend
  it forever.
- Components are a small association per entity. That is right for
  hundreds of entities and wrong for hundreds of thousands. When someone
  measures a need for an index, adding one does not change this
  interface.

## `(sim schedule)` — what runs each tick

```scheme
(define s (make-schedule))
(schedule-add! s 'input 0 (lambda (ctx dt) ...))
(schedule-add! s 'physics 10 (lambda (ctx dt) ...))
(define token (schedule-add! s 'debug 99 (lambda (ctx dt) ...)))
(schedule-run! s world 0.016)
(schedule-remove! token)
```

Order comes from the priority number, and equal priorities keep the
order they were added in — including across removals, because the tie is
broken by a stored sequence number rather than by position in a list. An
order that comes from load order is invisible in the source and changes
when someone renames a file; this one is readable from the registration.

- **One id, one system.** Registering a second live system under an id
  already in use is an error rather than a silent second registration.
- **Removal takes effect immediately**, even from inside a tick that is
  already walking the list.
- **`schedule-run!` is not reentrant**: a system that runs the schedule
  is an error by name, and the flag is restored if a system raises, so
  one bad tick does not wedge the schedule forever.
- **A system that raises stops the tick**, and the condition reaches the
  caller. This is the opposite of what `(lng effect)` does for cleanups,
  and the difference is the point: a cleanup that is skipped leaks a
  resource, so every cleanup must get its turn; a tick is one transition
  of the whole world, and continuing past a failed system leaves a
  half-updated state that looks complete.

## `(sim events)` — who hears what

```scheme
(define bus (make-bus))
(define token (bus-on! bus 'damage (lambda (payload) ...)))
(bus-emit! bus 'damage (list 'from player 'amount 7))
(bus-off! token)
```

Dispatch walks a snapshot, so the set of listeners that hears one emit
is fixed before the first of them runs.

- A listener that **subscribes from inside a handler** hears the next
  event, not the one that created it.
- A listener **removed during an emit does not run**, even though the
  snapshot still holds it — which matters, because during an emit is
  exactly when a caller unsubscribes.
- **Emitting from inside a listener** is allowed and runs to completion
  before the outer emit resumes. It is bounded: past
  `bus-depth-limit` it is an error naming the topic, because the natural
  mistake is a listener that emits the topic it listens to, and a stack
  overflow does not say which two topics were feeding each other.

## `(sim step)` — fixed steps, advanced by the caller

```scheme
(define clock (make-fixed-step 0.016 4))
(fixed-step-advance! clock dt (lambda (step) (world-tick! world step)))
(render (fixed-step-alpha clock))
(fixed-step-time clock)                ; simulated seconds so far
(fixed-step-reset! clock)              ; after a pause
```

A simulation advances in equal steps whatever the frame took, and the
caller decides when: paused, a region still loading, a menu open, a
frame the host delivered while the tab was hidden. This is that rule
and nothing else — no frame callback, no drawing, no clock of its own.

**No remainder is kept.** What is stored is the total time handed in
and the count of steps run; how many are due now is
`floor(total/step) - taken`, computed fresh every time. Keeping a
remainder instead means each frame re-adds the error of the last
subtraction: at a step of `0.1`, two frames of `0.25` come out as four
steps rather than five, because the remainder after the first is
`0.04999999999999999` and `0.29999999999999993` contains only two
whole steps. The answer to a floating-point boundary is not to fuzz
the comparison — a tolerance of a nanosecond is a symptom, and one was
written by a consumer working around exactly this — but to change the
representation so the error never accumulates.

- **An exact boundary steps now**, not on the next frame. Comparing
  with a strict `<` defers it, and the interpolation factor reaches
  `1.0` in the meantime, which draws a frame past the last state the
  caller was given.
- **A stall is capped at `max-steps` and the excess is dropped, not
  owed.** A simulation that owes time runs faster than real time to
  repay it, which is how one long stall becomes a second one.
- **`fixed-step-alpha` is always below one.** It says where the caller
  is between the state it has and the state after the next step, which
  is what an interpolating renderer needs; at exactly one it would be
  describing a state that has not been computed.
- **`fixed-step-time` counts steps, not frames.** It is the clock the
  simulation actually ran on, and it differs from the sum of the frame
  times by whatever a cap dropped — which is the honest number, since
  that time was never simulated.
- **Whole steps only.** The body always receives the configured step,
  so a system can treat its argument as a constant.

`fx-loop-fixed!` in `(gfx fx)` is a caller of this library: it builds
one of these, advances it per frame, and passes `fixed-step-alpha` to
the renderer. The stepping rule used to be written out inside that
loop, and a consumer who wanted the rule without the frame callback
wrote it a third time. Three copies of one rule agree until someone
fixes one of them.

## `(sim random)` — repeatable chance

*Written by the session that implemented it; see the source until this
section lands.*
