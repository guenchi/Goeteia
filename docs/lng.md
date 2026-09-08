# `(lng …)` — dispatch and the relations behind it

Four libraries so far: `(lng pred)` holds named classifications and
the relations between them, `(lng generic)` dispatches on more than one
argument, `(lng machine)` keeps a state machine as data, and
`(lng effect)` folds what several sources do to one quantity. They are
for game and simulation logic — rules that grow a case at a time — and
are deliberately absent from any per-frame path.

There are no classes here, no inheritance, no method combination, no
`call-next-method` and no meta-object protocol. A handler either wins
or it does not run.

## The problem these solve

A rule that reads "fire damage against a mage" and another that reads
"fire damage against anyone" both apply to a fire spell aimed at a
mage. Something has to decide, and the two usual answers are both bad:
*first registered wins* makes the behaviour depend on load order, and
*last registered wins* makes it depend on it in the other direction.
Either way, moving a `define` changes what the program does.

The answer here is that the relation between rules is **declared**, and
a conflict with no declared answer is an **error the program reports**
rather than a coin flip.

## `(lng pred)`

A **classifier** is a procedure from a value to a symbol out of a
declared finite set:

```scheme
(define job (define-classifier 'job cdr '(warrior paladin mage healer)))
(declare-subtag! job 'paladin 'warrior)
(declare-subtag! job 'paladin 'healer)     ; a diamond is allowed

(classify job '(bob . paladin))            ; -> paladin
(subtag? job 'paladin 'warrior)            ; -> #t   (declared)
(subtag? job 'paladin 'paladin)            ; -> #t   (reflexive)
(descendants job 'warrior)                 ; -> (warrior paladin)
```

The relation is stored as a reflexive, transitive closure.
`declare-subtag!` refuses a declaration that would close a cycle, and
refuses a tag outside the classifier's domain; `classify` refuses when
the classifier answers outside it. Each refusal is named after the
procedure that refused, so `condition-who` says which rule you broke.

**Finiteness is the point.** Because the tag set is declared and
finite, every tuple two handler signatures could both match can be
enumerated — which is what turns "these two rules are ambiguous" from a
runtime surprise into a fact the program states when the rules are
installed.

`declare-subset!` / `subset?` are the same relation over ordinary
predicates, for the predicate mode below.

## `(lng generic)`

```scheme
(define damage (make-generic 'damage 2 (classifiers skill-kind job)))
(add-handlers! damage
  (list (cons '(fire mage) (lambda (s t) 'fire-on-mage))
        (cons '(fire _)    (lambda (s t) 'fire-on-anyone))
        (cons '(_ _)       (lambda (s t) 'plain))))

(damage '(fire . 3) '(al . mage))          ; -> fire-on-mage
```

`make-generic` answers an ordinary procedure of that arity, so a
generic can be passed anywhere a procedure is wanted. Arity is 1 to 4:
dispatch is written out per arity because this runtime has no `apply`,
and a fifth is refused at construction rather than silently ignored.

A **signature** has one entry per argument: a tag, or `_` for "any".
The most specific applicable handler wins, where "more specific" means
*at every position* — a handler that is more specific in one argument
and less in another does not win, it conflicts.

### Conflicts are found when the rules are installed

Every change is a **transaction**. `add-handler!`, `add-handlers!`,
`remove-handler!` and a `declare-subtag!` that touches a classifier a
generic uses each validate the whole proposed configuration before
committing it, and leave the previous one exactly as it was when they
refuse:

```scheme
(add-handlers! g (list (cons '(fire _) f1) (cons '(_ mage) f2)))
;; refused: (fire mage) matches both and neither is more specific.
;; The irritants name that tuple.

(add-handlers! g (list (cons '(fire _) f1) (cons '(_ mage) f2)
                       (cons '(fire mage) f3)))
;; accepted: the third decides the overlap, and all three land together
```

That is the whole rule about order: **signatures that resolve an
overlap must be committed with it**. Splitting them across two commits
is refused at the first one, and no order of members within a batch
changes the outcome.

Removing a handler is a transaction too, so removing the one that
resolved an overlap is refused and removes nothing. So is a lattice
change: `(declare-subtag! job 'paladin 'healer)` that would make two
existing handlers ambiguous is refused, and the relation does not take
effect.

### At the call

The arguments are classified, the tuple is looked up in a per-generic
table, and the winner runs. The table is filled the first time a tuple
is seen and emptied by every commit, so a settled generic dispatches by
one hash lookup.

- Nothing applies: the default runs, or — with no default — the generic
  refuses under **its own name**, with the arguments as irritants.
- A classifier answers outside its domain: the generic refuses, **even
  when a default exists**. The domain is what every conflict check was
  computed over, so a value outside it was never reasoned about, and
  handing it to a default would be answering a question nobody checked.
- `(dispatch-trace g args)` answers `(tags candidates winner)` without
  calling a **handler** — the classifiers do run, since the tags are
  what it reports. The tuple, every candidate signature in registration
  order, and the winning signature or `#f`.

## Predicate mode, and why tag mode is the default

`(make-generic 'name arity 'predicates)` takes signatures of ordinary
predicates instead of tags. Nothing about open-ended procedures is
enumerable, so a conflict can only be reported at the call, and the
declared relation is `declare-subset!` over procedure objects.

A predicate's identity is the **procedure object**. Two lambdas with
identical bodies are two different predicates, and a relation declared
about one says nothing about the other.

## `(lng machine)`

A state machine here is a **datum**. The states, the initial state and
the transitions are lists of symbols; the guards and actions are
**names**, and the procedures behind the guard names are supplied when
the machine is made:

```scheme
(define door-spec
  '((states (closed open locked))
    (initial closed)
    (transitions
     ((closed push open) (open push closed)
      (closed lock locked has-key)
      (closed lock closed no-key ring-alarm)
      (locked unlock closed has-key)))))

(define m (make-machine door-spec
                        (list (cons 'has-key (lambda (ctx) (memq 'key ctx)))
                              (cons 'no-key (lambda (ctx) (not (memq 'key ctx)))))
                        '(key)))
```

A transition is `(from event to)`, optionally followed by a guard name
and then an action name. Only the **guard** names need bindings: a
guard is a question the library asks, so a name it cannot ask through
is refused at construction. An action name is handed back to the
caller and never called here, so nothing has to be bound to it — the
library does not know how your actions are performed, which is the
point.

Because the spec holds no procedures, it can be written to a file,
read back, diffed and drawn; `machine->datum` and `datum->machine` do
the round trip, and the bindings are supplied again on the way back in
— a saved game carries the machine, not the code.

A machine value is immutable. `machine-step` answers two values, the
new machine and the **names** of the actions the transition asks for:

```scheme
(let-values (((m2 actions) (machine-step m 'lock '())))
  (machine-state m2)      ; => closed  (the no-key transition)
  actions)                ; => (ring-alarm)
```

It performs none of them. Who runs an action, in what order, and what
happens if it fails stay in the caller's code, where they can be read.

**Nothing is ordered.** Several transitions may share a
`(state, event)` key only when every one of them carries a guard. All
of those guards are evaluated on each step, and exactly one may hold.
Two holding at once is an error naming the state, the event and the
transitions — never "the first one in the file wins". The same rule
covers the two other places a first-occurrence rule could hide: a
clause given twice (two `initial`, two `strict`) and a name bound
twice in the bindings alist are both refused, rather than resolved by
position.

That guarantee assumes guards are **pure**. A guard that writes the
context, or any state its neighbours read, can make their answers
depend on which one ran first; the library evaluates every guard that
returns normally, but it cannot see a guard that changes the world it
is being asked about. Keep guards to reading.

**What is checked when.** `make-machine` refuses, by name: a
transition from or to a state that is not declared, an initial state
that is not declared, two transitions on one key where any of them is
unguarded, a guard name with no binding, a context that is not a
datum, and — unless told otherwise — a state that cannot be reached
from the initial state:

```scheme
(make-machine '((states (a b c)) (initial a) (transitions ((a go b))))
              '() #f '((strict #f)))   ; c is unreachable, and that is fine here
```

An option is exactly `(name value)`, and `strict` takes `#t` or `#f`:
an unknown name, a missing value, an extra element and a non-boolean
`strict` are each refused by name rather than read as some weaker
request.

Reachability is structural: an edge counts even if its guard could
never hold. Deciding whether a guard is satisfiable is not something
this library pretends to do.

Everything that goes in is checked for being a **datum** — the spec,
the options and the context alike, not just the one the writer
happens to think of. The bindings alist cannot be one (it holds
procedures) and is checked for shape and for cycles on its own.

A spec may carry clauses this library does not know: it is your data,
it round trips, and `(metadata …)` beside `(states …)` is none of the
library's business. An **option** is the opposite — an instruction to
the library — and one it does not recognize has no reading under
which it still applies, so an unknown option name is refused rather
than ignored. A procedure anywhere in a spec is refused where
it enters rather than surviving into what `machine->datum` calls a
datum. A structure that contains a cycle is refused by name; the
error says which value was cyclic and does not carry the value,
because printing it is the same endless walk that made it a problem.
What the accessors hand back is a deep copy, mutable leaves included:
mutating a row from `machine-transitions`, or a string inside the spec
`machine-spec` returned, cannot reach the machine.

Guard ambiguity is the one modelling error reported at the step rather
than at construction, and for the same reason predicate mode reports
late: guard truth is a run-time fact.

**An event with no transition** leaves the machine alone and answers
no actions. A spec that would rather hear about it says so:

```scheme
(append door-spec '((on-unknown error)))
```

**Context.** `make-machine` takes an initial context, `machine-step`
takes one that replaces it for that step, and the context used is
retained in the machine that comes back. It must be a datum, checked
where it enters rather than where it is written out. The machine
neither copies nor changes it: a context mutated behind the machine's
back makes `machine->datum` describe something that no longer exists.

**Looking at a machine without running it.** `machine-events` answers
the events available from the current state — structurally, without
evaluating a guard, which is what a UI disabling buttons wants.
`machine-transitions` answers the whole table, for diagnostics and
diagrams. `machine-state`, `machine-ctx` and `machine-spec` answer the
parts.

## `(lng effect)`

An **effect** is a record saying what a source does to a quantity:

```scheme
(make-effect 'damage 'sword 0 'compute 5)   ; kind source priority phase payload
```

A **policy** per kind says how the payloads combine, and `resolve`
folds them:

```scheme
(let-values (((result provenance)
              (resolve effects '(compute settle) '((damage . sum) (armor . max)))))
  result)        ; => ((damage . 10) (armor . 7))
```

Two values come back: the answer, and where each part of it came from
— `((damage (sword . 5) (ring . 2) (curse . 3)) …)`. The second is not
a log the library keeps; it is built from the same fold that produced
the first, so it cannot drift from it.

**Every ordering the answer depends on is in the data.** The phase
list the caller passes decides which effects fold first; the priority
number orders them inside a phase; and effects that agree on both stay
in the order they were collected, because the sort is stable. Nothing
comes from registration order, from a method chain, or from which
module loaded first — which is what lets three modules that have never
heard of each other contribute to one number and get the same answer
however they were loaded.

**Policies are names, not procedures.** `sum`, `max`, `min`, `last`
and `all` are built in; any other name is bound by the caller, the way
a machine binds its guards:

```scheme
(resolve effects '(p) '((k . how-many))
         (list (cons 'how-many (lambda (payloads) (length payloads)))))
```

So the whole input to `resolve` — effects, phases, policies — is a
datum, which a table of closures could not be: it can be written to a
file and replayed. A built-in name cannot be rebound, because one name
with two readings is the ambiguity this library refuses everywhere
else.

**Dispatch and collection are different jobs.** Picking the one rule
that applies is dispatch, and `(lng generic)` does it. Unioning what
several producers each returned is collection:

```scheme
(collect-effects (list skill-effects gear-effects aura-effects) attacker target)
```

Each producer is called with the same arguments and its effects are
appended, in the order the caller listed them. A producer contributes
because it is named in that list, not because it registered itself
somewhere. There is no implicit method combination here.

**Round trip.** `effect->datum` and `datum->effect` write an effect
out and read it back, so a fight can be replayed. A payload is
whatever the caller's policy understands and is not checked when the
effect is made — mid-fight it is often a live object, and refusing
those would be refusing the ordinary case. `effect->datum` is where it
has to be a datum, and that is where a live payload or a cyclic one is
refused by name.

**What is refused**, all by name: a phase listed twice, a kind with
two policies, a policy name that is neither built in nor bound, a name
bound twice or bound to something that is not a procedure, an effect
in a phase the caller did not ask for, a kind with no policy, and a
cyclic list where a list was expected. Nothing is settled by which
entry came first.

Nothing is copied here. `(lng machine)` holds a spec for as long as
the machine lives and must therefore own it; `resolve` reads the
effects once and returns, so there is no later moment at which a
mutated payload could make something it stored describe a world that
has moved on.

## Not done

Method combination, `call-next-method`, classes, inheritance and a
meta-object protocol are all deliberately absent: this library answers
"which one procedure runs", and nothing else. Per-frame work — skinning,
rasterizing, morph blending — keeps its own primitives; dispatch here is
for event and turn granularity.
