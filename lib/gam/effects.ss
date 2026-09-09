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
    (unless (and (real? duration) (< 0 duration))
      (error 'effect-set! "a duration is a positive real" name duration))
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
    (unless (and (real? dt) (not (< dt 0)))
      (error 'effects-tick! "elapsed time is a non-negative real" dt))
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
