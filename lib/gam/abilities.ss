;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; One thing: whether an action may be taken again yet.
;;
;; An ability here is an identifier, a cost, a cooldown length, and how
;; much of that cooldown is left.  That is the whole of it, and the
;; boundary is the point of the library.
;;
;; IT DOES NOT SPEND THE COST.  ability-use! moves the cooldown and
;; answers whether it moved; it does not touch a pool, and it does not
;; know that pools exist.  The cost is a number the ability CARRIES, for
;; the caller to read and subtract wherever it keeps its resources.  The
;; alternative -- use! spends from a stats value it was handed -- ties
;; two independent parts together permanently: the ability could then
;; only ever be paid for out of that one kind of thing, in that one
;; currency, and an ability that costs two resources, or none, or a
;; cooldown shared with another ability, stops fitting.  Keeping them
;; apart costs the caller one line and buys every combination.
;;
;; IT CARRIES NO DAMAGE AND NO RANGE.  Those are a game's numbers, not a
;; cooldown's; an ability that heals or opens a door has neither, and a
;; library that stored them would be telling every caller that an
;; ability is a way of hitting something.
;;
;; What it carries instead is a PAYLOAD it never reads.  The difference
;; is the whole point: cost and cooldown are acted on -- ready? compares
;; against zero, tick! and use! move the remaining time -- while damage,
;; range, an animation clip or a status effect are only ever handed
;; back.  Giving those a slot each would make this library name them,
;; and it has no business knowing which of them a game has.  One opaque
;; field says "yours" without saying what.  A caller may still keep a
;; separate table keyed by the identifier; the payload is there so that
;; it does not have to.
;;
;; The names mean what they say: ability-cooldown is the LENGTH of the
;; cooldown, fixed when the ability is made, and ability-remaining is
;; how much of it is left right now.  Those two are worth keeping
;; distinct in the reader's mind, because one is configuration and the
;; other is state, and code that confuses them reads as if it works.
(library (gam abilities)
  (export make-ability ability? ability-id ability-cost ability-cooldown
          ability-remaining ability-payload ability-ready? ability-tick!
          ability-use! ability-lock!)
  (import (rnrs))

  ;; #(gam-ability id cost cooldown remaining zero payload)
  ;;
  ;; `zero' is the cooldown's own zero, exact when the cooldown is exact
  ;; and inexact when it is not, so an ability configured in flonums
  ;; reports a flonum at the one value callers compare against most.
  ;;
  ;; The payload slot is always present.  An ability made without one
  ;; holds #f there rather than being a shorter vector, so there is one
  ;; width to check and one shape to reason about; a type test that
  ;; accepted two lengths would also accept a six-slot vector that this
  ;; library can no longer produce.
  (define ($a? a)
    (and (vector? a) (= (vector-length a) 7)
         (eq? (vector-ref a 0) 'gam-ability)))
  (define ($need-a who a)
    (unless ($a? a) (error who "not an ability" a)))
  (define ($cooldown a) (vector-ref a 3))
  (define ($remaining a) (vector-ref a 4))
  (define ($remaining! a v) (vector-set! a 4 v))
  (define ($zero a) (vector-ref a 5))
  (define ($payload a) (vector-ref a 6))

  (define (ability? a) ($a? a))

  ;; A cooldown of zero is refused: an ability that is instantly ready
  ;; again has no cooldown, and saying so with this type only hides that
  ;; every use! and tick! around it is doing nothing.  A cost of zero is
  ;; fine -- an ability that is free but rate-limited is an ordinary
  ;; thing, and the cost is not what this library acts on anyway.
  ;; The payload is optional and unchecked.  Nothing here can say what a
  ;; well-formed one looks like, so nothing here refuses one; a caller
  ;; that stores #f is indistinguishable from a caller that stored
  ;; nothing, and that is left alone rather than papered over with a
  ;; sentinel this library would then have to keep out of reach.
  (define (make-ability id cost cooldown . rest)
    (unless (or (null? rest) (null? (cdr rest)))
      (error 'make-ability "an ability takes one payload, not several" id rest))
    (unless (and (real? cost) (not (< cost 0)))
      (error 'make-ability "a cost is a non-negative real" id cost))
    (unless (and (real? cooldown) (< 0 cooldown))
      (error 'make-ability "a cooldown is a positive real" id cooldown))
    (let ((zero (if (exact? cooldown) 0 (* 0.0 cooldown)))
          (payload (if (null? rest) #f (car rest))))
      ;; ready when made: nothing has been used yet, so nothing is owed
      (vector 'gam-ability id cost cooldown zero zero payload)))

  (define (ability-id a) ($need-a 'ability-id a) (vector-ref a 1))
  (define (ability-cost a) ($need-a 'ability-cost a) (vector-ref a 2))
  (define (ability-cooldown a) ($need-a 'ability-cooldown a) ($cooldown a))
  (define (ability-remaining a) ($need-a 'ability-remaining a) ($remaining a))

  ;; Handed back as it was given, not copied.  A copy would be this
  ;; library deciding what the caller's value is made of, and a caller
  ;; that mutates what it stored is mutating its own object.
  (define (ability-payload a) ($need-a 'ability-payload a) ($payload a))

  ;; The remaining time is clamped at zero by ability-tick!, so this is
  ;; a test against zero rather than against "zero or less" -- there is
  ;; no state in which it could be less, and a test that allowed for one
  ;; would be describing a value this library cannot produce.
  (define (ability-ready? a)
    ($need-a 'ability-ready? a)
    (not (< ($zero a) ($remaining a))))

  (define (ability-tick! a dt)
    ($need-a 'ability-tick! a)
    (unless (and (real? dt) (not (< dt 0)))
      (error 'ability-tick! "elapsed time is a non-negative real" dt))
    (let ((left (- ($remaining a) dt)))
      ($remaining! a (if (< left ($zero a)) ($zero a) left))))

  ;; Answers whether the use happened, and changes nothing when it did
  ;; not: a caller can branch on it without checking readiness first,
  ;; and a refused use leaves a cooldown that is still counting down
  ;; from where it was rather than being restarted by the attempt.
  (define (ability-use! a)
    ($need-a 'ability-use! a)
    (and (ability-ready? a)
         (begin ($remaining! a ($cooldown a)) #t)))

  ;; Lock for AT LEAST this long: the remaining time only ever grows
  ;; here, and a lock shorter than what is already owed leaves the
  ;; longer wait alone.  The direction is the whole of it.  A global
  ;; cooldown, a silence or an interrupt is a wait imposed from outside
  ;; and is routinely longer than the ability's own cooldown, so this
  ;; may exceed it -- the cooldown is the LENGTH use! restarts, not a
  ;; ceiling on what can be owed.  A "set to" instead of an "extend to
  ;; at least" would let the shorter of two overlapping locks cut the
  ;; longer one short, and the caller would see an ability come back
  ;; early with nothing in its own code to explain it.
  ;;
  ;; Zero is accepted and does nothing.  Unlike a cooldown of zero,
  ;; which is configuration and refused, this argument is a length of
  ;; time like the one ability-tick! takes, and a caller computing one
  ;; from a table of durations may legitimately arrive at none.
  ;;
  ;; Checked before anything is written, so a refused lock leaves the
  ;; ability exactly as it was -- the contract ability-use! keeps, and
  ;; what lets a caller branch on the failure without first testing.
  (define (ability-lock! a seconds)
    ($need-a 'ability-lock! a)
    ;; (<= 0 seconds) rather than (not (< seconds 0)): NaN is a real and
    ;; is not less than zero, so the second form admits it, and a NaN
    ;; lock then compares false against everything and becomes a silent
    ;; no-op -- the caller's arithmetic went wrong somewhere upstream
    ;; and this would be the last place that could have said so.
    (unless (and (real? seconds) (<= 0 seconds))
      (error 'ability-lock! "a lock is a non-negative real" seconds))
    ;; Added to the cooldown's own zero so the stored time keeps the
    ;; cooldown's exactness.  Storing the argument as given would let an
    ;; exact lock on a flonum ability leave an exact remaining, and
    ;; ability-tick! would then land on exact 0 where this library
    ;; promises a flonum -- see the note on `zero' above.
    (let ((owed ($remaining a))
          (want (+ ($zero a) seconds)))
      (if (< owed want)
          (begin ($remaining! a want) want)
          owed))))
