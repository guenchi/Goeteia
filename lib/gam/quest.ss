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

;; Objectives that count each event once, and report in one order.
;;
;; Two things are being defended here, and neither is the counting.
;;
;; IDEMPOTENCE.  The same objective may be reported many times -- the
;; event that carries it is usually a collision, a trigger volume or a
;; message bus, and none of those promise to fire once.  So recording an
;; objective already recorded answers #f and changes nothing, and the
;; count is the number of DISTINCT objectives met.  Without that the
;; progress bar depends on how many times the player walked over a
;; trigger.
;;
;; ORDER COMES FROM THE DEFINITION, NOT FROM THE HISTORY.  quest-keys
;; answers the objectives that have been met in the order the quest
;; declared them, filtered, and never in the order the events arrived.
;; Two players with the same objectives met get the same answer; one
;; player saving and reloading gets the same answer; a checksum over
;; progress is stable.  Reporting arrival order looks equivalent and is
;; not: it turns every listing into a record of the route taken, which
;; is why the quest that ends up compared against another quest's
;; listing is the one that ships broken.
;;
;; A repeated objective in the required list is refused rather than
;; tolerated.  quest-complete? compares a count of distinct objectives
;; against the length of that list, so a duplicate makes the denominator
;; larger than anything the numerator can reach and the quest can never
;; be completed -- a failure that shows up only when a player gets all
;; the way to the end.
;;
;; Objectives are compared with eq?, so they must be values eq? is
;; dependable on: symbols, characters, booleans and fixnums.  A large
;; integer is refused for a measured reason -- eq? on two separately
;; computed equal ones answers differently on the two compiler targets,
;; so the same save file would read back differently in wasm and in
;; JavaScript.
(library (gam quest)
  (export make-quest quest-count quest-complete? quest-record!
          quest-keys quest-restore!)
  (import (rnrs))

  ;; #(gam-quest required recorded); `recorded' is unordered as far as
  ;; any caller can tell, because nothing hands it out -- quest-keys
  ;; rebuilds its answer from `required' every time.
  (define ($quest? q)
    (and (vector? q) (= (vector-length q) 3)
         (eq? (vector-ref q 0) 'gam-quest)))
  (define ($required q) (vector-ref q 1))
  (define ($recorded q) (vector-ref q 2))
  (define ($recorded! q v) (vector-set! q 2 v))

  (define ($need-quest who q)
    (unless ($quest? q) (error who "not a quest" q)))

  (define ($eq-key? k)
    (or (symbol? k) (char? k) (boolean? k) (fixnum? k)))

  (define ($need-key who k)
    (unless ($eq-key? k)
      (error who "an objective is a symbol, character, boolean or fixnum" k)))

  (define (make-quest required)
    (unless (list? required)
      (error 'make-quest "the objectives are a list" required))
    (let check ((ks required) (seen '()))
      (if (null? ks)
          (vector 'gam-quest required '())
          (begin
            ($need-key 'make-quest (car ks))
            (when (memq (car ks) seen)
              (error 'make-quest "that objective appears twice" (car ks)))
            (check (cdr ks) (cons (car ks) seen))))))

  (define (quest-count q)
    ($need-quest 'quest-count q)
    (length ($recorded q)))

  (define (quest-complete? q)
    ($need-quest 'quest-complete? q)
    (= (length ($recorded q)) (length ($required q))))

  ;; Answers whether this call is what advanced the quest, so a caller
  ;; can play a sound or show a line exactly when something happened,
  ;; rather than every time the trigger fires again.  An objective this
  ;; quest does not require is not an error: an event bus carries
  ;; everything to everyone, and a quest that raised on someone else's
  ;; objective could not be attached to a shared bus at all.
  (define (quest-record! q key)
    ($need-quest 'quest-record! q)
    ($need-key 'quest-record! key)
    (and (memq key ($required q))
         (not (memq key ($recorded q)))
         (begin ($recorded! q (cons key ($recorded q))) #t)))

  ;; Built from `required' each time, so the answer is a function of
  ;; WHAT has been met and never of WHEN.
  (define (quest-keys q)
    ($need-quest 'quest-keys q)
    (let loop ((ks ($required q)) (out '()))
      (cond ((null? ks) (reverse out))
            ((memq (car ks) ($recorded q)) (loop (cdr ks) (cons (car ks) out)))
            (else (loop (cdr ks) out)))))

  ;; Restoring goes through quest-record!, so a save file gets exactly
  ;; the checks a live event gets: an objective this quest does not
  ;; require is dropped, and one written twice is counted once.  A save
  ;; file is input from outside, and it is the input most likely to have
  ;; been edited by hand.
  (define (quest-restore! q keys)
    ($need-quest 'quest-restore! q)
    (unless (list? keys)
      (error 'quest-restore! "the recorded objectives are a list" keys))
    ($recorded! q '())
    (let loop ((ks keys))
      (unless (null? ks)
        (quest-record! q (car ks))
        (loop (cdr ks))))))
