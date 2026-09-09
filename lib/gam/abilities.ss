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
;; ability is a way of hitting something.  A caller with its own table
;; of ability data keys it by the identifier this carries.
;;
;; The names mean what they say: ability-cooldown is the LENGTH of the
;; cooldown, fixed when the ability is made, and ability-remaining is
;; how much of it is left right now.  Those two are worth keeping
;; distinct in the reader's mind, because one is configuration and the
;; other is state, and code that confuses them reads as if it works.
(library (gam abilities)
  (export make-ability ability? ability-id ability-cost ability-cooldown
          ability-remaining ability-ready? ability-tick! ability-use!)
  (import (rnrs))

  ;; #(gam-ability id cost cooldown remaining zero)
  ;;
  ;; `zero' is the cooldown's own zero, exact when the cooldown is exact
  ;; and inexact when it is not, so an ability configured in flonums
  ;; reports a flonum at the one value callers compare against most.
  (define ($a? a)
    (and (vector? a) (= (vector-length a) 6)
         (eq? (vector-ref a 0) 'gam-ability)))
  (define ($need-a who a)
    (unless ($a? a) (error who "not an ability" a)))
  (define ($cooldown a) (vector-ref a 3))
  (define ($remaining a) (vector-ref a 4))
  (define ($remaining! a v) (vector-set! a 4 v))
  (define ($zero a) (vector-ref a 5))

  (define (ability? a) ($a? a))

  ;; A cooldown of zero is refused: an ability that is instantly ready
  ;; again has no cooldown, and saying so with this type only hides that
  ;; every use! and tick! around it is doing nothing.  A cost of zero is
  ;; fine -- an ability that is free but rate-limited is an ordinary
  ;; thing, and the cost is not what this library acts on anyway.
  (define (make-ability id cost cooldown)
    (unless (and (real? cost) (not (< cost 0)))
      (error 'make-ability "a cost is a non-negative real" id cost))
    (unless (and (real? cooldown) (< 0 cooldown))
      (error 'make-ability "a cooldown is a positive real" id cooldown))
    (let ((zero (if (exact? cooldown) 0 (* 0.0 cooldown))))
      ;; ready when made: nothing has been used yet, so nothing is owed
      (vector 'gam-ability id cost cooldown zero zero)))

  (define (ability-id a) ($need-a 'ability-id a) (vector-ref a 1))
  (define (ability-cost a) ($need-a 'ability-cost a) (vector-ref a 2))
  (define (ability-cooldown a) ($need-a 'ability-cooldown a) ($cooldown a))
  (define (ability-remaining a) ($need-a 'ability-remaining a) ($remaining a))

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
         (begin ($remaining! a ($cooldown a)) #t))))
