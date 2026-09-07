# `(lng …)` — dispatch and the relations behind it

Two libraries so far: `(lng pred)` holds named classifications and the
relations between them, `(lng generic)` dispatches on more than one
argument. They are for game and simulation logic — rules that grow a
case at a time — and are deliberately absent from any per-frame path.

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

## Predicate mode, and why it is not the recommended form

`(make-generic 'name arity 'predicates)` takes signatures of ordinary
predicates instead of tags. Nothing about open-ended procedures is
enumerable, so a conflict can only be reported at the call, and the
declared relation is `declare-subset!` over procedure objects.

A predicate's identity is the **procedure object**. Two lambdas with
identical bodies are two different predicates, and a relation declared
about one says nothing about the other.

> **Limitation, 2026-09-07.** On the wasm target a top-level
> `(define (f x) …)` yields a *fresh closure at every reference*, so
> even two mentions of one name are not `eq?`. Predicate identity
> therefore does not hold there, and predicate mode is usable only on
> the JS target and under Chez. Tag mode is unaffected — tags are
> symbols. The wasm backend fix is a batch of its own; until it lands,
> write tag mode.

## Not done

Method combination, `call-next-method`, classes, inheritance and a
meta-object protocol are all deliberately absent: this library answers
"which one procedure runs", and nothing else. Per-frame work — skinning,
rasterizing, morph blending — keeps its own primitives; dispatch here is
for event and turn granularity.
