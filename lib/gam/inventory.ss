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

;; Counted things, in an order that does not depend on the run.
;;
;; Two properties carry this library, and both are about what a caller
;; can rely on rather than about what it can store.
;;
;; THE ORDER IS MAINTAINED, NOT COMPUTED.  inventory-items answers rows
;; in the order their keys were first added, always, on both compiler
;; targets.  That matters because byte-for-byte agreement between the
;; targets is a tested property of this system, and a listing whose
;; order came from a hash table would break it silently -- a saved game,
;; a rendered list, a checksum over the bag would each differ for no
;; reason a reader could see.  A row is therefore never dropped and
;; never moved: a key taken down to zero keeps its place, so putting it
;; back does not move it to the end and make the order a record of what
;; the player happened to do.
;;
;; TAKING IS ALL OR NOTHING.  A take that cannot be satisfied removes
;; nothing and answers #f.  The alternative -- remove what is there and
;; report how much -- reads the same at the call site and leaves the
;; caller having half-paid for something it did not get.
;;
;; Keys are compared with eq?, so they must be values eq? is dependable
;; on: symbols, characters, booleans and fixnums.  A string or a large
;; integer is refused rather than accepted and silently never matched --
;; and on large integers this is not a theoretical worry, since eq? on
;; two separately computed equal ones answers differently on the two
;; targets, which would make the same bag behave differently in wasm and
;; in JavaScript.
(library (gam inventory)
  (export make-inventory inventory-count inventory-add! inventory-take!
          inventory-items)
  (import (rnrs))

  ;; #(gam-inventory rows); rows is newest-first, and inventory-items
  ;; reverses it.  Prepending keeps a first add cheap; the reversal is
  ;; paid only by the caller that actually wants the listing.
  (define ($inv? b)
    (and (vector? b) (= (vector-length b) 2)
         (eq? (vector-ref b 0) 'gam-inventory)))
  (define ($rows b) (vector-ref b 1))
  (define ($rows! b v) (vector-set! b 1 v))

  (define ($need-inv who b)
    (unless ($inv? b) (error who "not an inventory" b)))

  ;; The values eq? is dependable on across both targets.
  (define ($eq-key? k)
    (or (symbol? k) (char? k) (boolean? k) (fixnum? k)))

  (define ($need-key who k)
    (unless ($eq-key? k)
      (error who "an item key is a symbol, character, boolean or fixnum" k)))

  ;; Zero is refused as well as a negative count.  Adding nothing and
  ;; taking nothing are calls that mean something went wrong in the
  ;; arithmetic that produced the count, and answering them quietly
  ;; hides where.
  (define ($need-count who key n)
    (unless (and (integer? n) (exact? n) (< 0 n))
      (error who "an item count is a positive exact integer" key n)))

  (define (make-inventory) (vector 'gam-inventory '()))

  (define ($row who b key)
    ($need-inv who b)
    ($need-key who key)
    (assq key ($rows b)))

  (define (inventory-count b key)
    (let ((r ($row 'inventory-count b key)))
      (if r (cdr r) 0)))

  (define (inventory-add! b key n)
    (let ((r ($row 'inventory-add! b key)))
      ($need-count 'inventory-add! key n)
      (if r
          (begin (set-cdr! r (+ (cdr r) n)) (cdr r))
          (begin ($rows! b (cons (cons key n) ($rows b))) n))))

  (define (inventory-take! b key n)
    (let ((r ($row 'inventory-take! b key)))
      ($need-count 'inventory-take! key n)
      (and r
           (not (< (cdr r) n))
           (begin (set-cdr! r (- (cdr r) n)) #t))))

  ;; Fresh pairs, not the rows themselves: the bag's contents are the
  ;; library's, and a caller that was handed the internal pairs could
  ;; set-cdr! a count past every check above.
  (define (inventory-items b)
    ($need-inv 'inventory-items b)
    (let loop ((rs ($rows b)) (out '()))
      (if (null? rs)
          out
          (loop (cdr rs) (cons (cons (car (car rs)) (cdr (car rs))) out))))))
