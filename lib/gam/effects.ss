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

;; States that end by themselves: a name and how long it has left.
;;
;; This is where a temporary condition belongs -- being slowed, being
;; hidden, being unable to be hurt for a moment after a hit.  Keeping
;; them here rather than as fields on whatever they affect is what lets
;; the affected thing stay a plain question of its own: a pool is a
;; number and a maximum, and whether something may lower it right now is
;; the caller's question to ask HERE, before it asks the pool to change.
;; A timer living inside the thing it modifies makes that thing's
;; operations depend on a clock that is nowhere in their arguments.
;;
;; This library knows nothing about pools, abilities or anything else it
;; might be used to gate.  It answers "how long is left on this name",
;; and every meaning of that is the caller's.
;;
;; SETTING A NAME AGAIN REPLACES THE DURATION.  It does not take the
;; larger of the two, and it does not add them.  Refreshing, extending
;; and letting the longer one win are three different rules a game can
;; want, and they differ in ways a player can feel; a library that
;; picked one would be making that choice for every game that used it.
;; A caller who wants the longer of the two reads effect-ref first and
;; sets the maximum itself, in its own code, where the rule is visible.
;;
;; The listing order is maintained rather than computed, for the reason
;; every listing in this collection maintains it: byte-for-byte
;; agreement between the two compiler targets is a tested property, and
;; an order that came out of a hash table would break it invisibly.  A
;; name that is set again while it is still running keeps its place --
;; it is the same effect, refreshed.  A name that ran out and is set
;; again is a new one, and goes at the end.
(library (gam effects)
  (export make-effects effect-set! effect-ref effect-active?
          effects-tick! effects-clear! effects-names)
  (import (rnrs))

  ;; #(gam-effects rows); a row is (name . remaining), newest first,
  ;; reversed when the names are asked for.
  ;; A real that is still finite once made inexact, which is what it
  ;; becomes when +, -, * or / combines it with a flonum, or when sin or
  ;; cos takes it; +, -, * and / on exact operands alone stay exact.  An
  ;; exact number of any size is finite as an exact number, yet 2^1024
  ;; becomes +inf.0 and 2^-1100 becomes 0.0 when that happens.  (- y y)
  ;; is 0 for every finite flonum y and NaN for either infinity and for
  ;; NaN; 1.7e308 passes, which a bound such as (< y 1e300) would
  ;; wrongly refuse.  A positive bound is tested on (inexact v) for the
  ;; same reason, since 2^-1100 is positive and becomes 0.0.  A
  ;; non-negative bound is tested on v itself, the stricter of the two
  ;; there, since -2^-1100 becomes -0.0 and (<= 0 -0.0) holds.  Either
  ;; way the value is kept as given.  All of this measured on the three
  ;; back ends.  One private copy per (gam ...) library whose checks use
  ;; it; "Prelude gaps" in docs/limits.md says why, and all eight change
  ;; together when that entry does.
  (define ($finite? x) (let ((y (inexact x))) (= 0 (- y y))))

  (define ($fx? f)
    (and (vector? f) (= (vector-length f) 2)
         (eq? (vector-ref f 0) 'gam-effects)))
  (define ($rows f) (vector-ref f 1))
  (define ($rows! f v) (vector-set! f 1 v))

  (define ($need-fx who f)
    (unless ($fx? f) (error who "not an effects value" f)))

  ;; The values eq? is dependable on across both compiler targets; a
  ;; string or a large integer would be accepted and then never match.
  (define ($eq-name? n)
    (or (symbol? n) (char? n) (boolean? n) (fixnum? n)))

  (define ($need-name who n)
    (unless ($eq-name? n)
      (error who "an effect name is a symbol, character, boolean or fixnum" n)))

  (define (make-effects) (vector 'gam-effects '()))

  ;; A duration of zero is refused rather than treated as "already
  ;; over": an effect that is set and instantly gone is never observable
  ;; between two ticks, so a caller asking for one has computed the
  ;; duration wrongly and would never see why.
  (define (effect-set! f name duration)
    ($need-fx 'effect-set! f)
    ($need-name 'effect-set! name)
    (unless (and (real? duration) ($finite? duration)
                 (< 0 (inexact duration)))
      (error 'effect-set!
             "a duration is a real, positive and finite as a flonum"
             name duration))
    (let ((r (assq name ($rows f))))
      (if r
          (set-cdr! r duration)
          ($rows! f (cons (cons name duration) ($rows f))))))

  ;; #f rather than 0 for a name that is not running: zero is a duration
  ;; this library never stores, so answering it would put a real value
  ;; and an absence into the same answer.
  (define (effect-ref f name)
    ($need-fx 'effect-ref f)
    ($need-name 'effect-ref name)
    (let ((r (assq name ($rows f))))
      (and r (cdr r))))

  (define (effect-active? f name)
    ($need-fx 'effect-active? f)
    ($need-name 'effect-active? name)
    (and (assq name ($rows f)) #t))

  ;; Subtract first, then drop what has run out -- in that order, so an
  ;; effect with exactly dt left is gone after the tick that consumed
  ;; it, not one tick later.  Reaching zero IS running out: an effect
  ;; with no time left cannot be observed for any span, and keeping it
  ;; would make effect-active? true for a state that gates nothing.
  (define (effects-tick! f dt)
    ($need-fx 'effects-tick! f)
    (unless (and (real? dt) ($finite? dt) (<= 0 dt))
      (error 'effects-tick!
             "elapsed time is a non-negative real, finite as a flonum"
             dt))
    (let step ((rs ($rows f)))
      (unless (null? rs)
        (set-cdr! (car rs) (- (cdr (car rs)) dt))
        (step (cdr rs))))
    ($rows! f (let keep ((rs ($rows f)) (out '()))
                (cond ((null? rs) (reverse out))
                      ((< 0 (cdr (car rs))) (keep (cdr rs) (cons (car rs) out)))
                      (else (keep (cdr rs) out))))))

  (define (effects-clear! f)
    ($need-fx 'effects-clear! f)
    ($rows! f '()))

  (define (effects-names f)
    ($need-fx 'effects-names f)
    (let loop ((rs ($rows f)) (out '()))
      (if (null? rs)
          out
          (loop (cdr rs) (cons (car (car rs)) out))))))
