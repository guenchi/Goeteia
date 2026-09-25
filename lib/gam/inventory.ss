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
          inventory-items inventory-weight)
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

  ;; What the bag weighs, under the caller's idea of what things weigh.
  ;;
  ;; The table is a PROCEDURE rather than a list, and it belongs to the
  ;; caller.  This library has never known what an item is, and a weight
  ;; per item is exactly the kind of thing it must not start knowing:
  ;; passing a procedure also means one bag answers different totals
  ;; under different rules -- carried against stored, a strength
  ;; modifier, a bag of holding -- without this library having a word
  ;; for any of them.
  ;;
  ;; A WEIGHT IT CANNOT USE IS AN ERROR, NOT A ZERO.  A key the table
  ;; does not know means the bag and the table have drifted apart, and
  ;; answering anyway would report a total that is quietly too small.
  ;; That failure surfaces as a carrying limit that is never reached,
  ;; with nothing at the point of the mistake to find.  The error names
  ;; the key, because that is the one thing the caller needs in order to
  ;; look.
  ;;
  ;; THE EMPTY BAG WEIGHS EXACT ZERO.  This library has no weights of
  ;; its own and therefore no exactness of its own; the total takes its
  ;; exactness from the caller's numbers.  Starting the fold at 0.0
  ;; would put an inexactness into an answer whose every input was
  ;; exact, and the caller could not tell where it came from.
  ;;
  ;; The table is asked about the KEY, never handed the library's row --
  ;; the same reason inventory-items copies its pairs.
  (define (inventory-weight b weight-of)
    ($need-inv 'inventory-weight b)
    (unless (procedure? weight-of)
      (error 'inventory-weight "the weight table is a procedure of an item key" weight-of))
    (let loop ((rs ($rows b)) (total 0))
      (if (null? rs)
          total
          (let* ((row (car rs))
                 (key (car row))
                 (n (cdr row)))
            ;; A row taken down to zero keeps its place in the listing
            ;; but is no longer held, so it does not reach the table at
            ;; all.  Asking about it and multiplying by zero would be a
            ;; different thing: 0 * 100.0 is 0.0 and 0 * +inf.0 is NaN,
            ;; so a bag emptied by inventory-take! would stop weighing
            ;; what a bag that was never filled weighs.
            (if (= n 0)
                (loop (cdr rs) total)
                (let ((w (weight-of key)))
                  ;; (<= 0 w) rather than (not (< w 0)): NaN is a real
                  ;; and is not less than zero, so the second form
                  ;; admits it and one unusable weight turns the whole
                  ;; total into NaN, with nothing naming the item that
                  ;; did it.  +inf.0 is let through: the total is then
                  ;; infinite, heavier than any limit finite as a flonum,
                  ;; which is a definite answer -- and the weight is read,
                  ;; not stored.  (> +inf.0 +inf.0) is false, and measured
                  ;; 2026-09-25 so is (> +inf.0 2^1024) here.  Not
                  ;; always: a count is an exact integer of any size, and
                  ;; measured 2026-09-25, a count of 2^1024 weighing 0.0
                  ;; each gave NaN, so with the infinite item the total
                  ;; was NaN rather than +inf.0.
                  (unless (and (real? w) (<= 0 w))
                    (error 'inventory-weight "no usable weight for that item" key w))
                  (loop (cdr rs) (+ total (* n w)))))))))

  ;; Fresh pairs, not the rows themselves: the bag's contents are the
  ;; library's, and a caller that was handed the internal pairs could
  ;; set-cdr! a count past every check above.
  (define (inventory-items b)
    ($need-inv 'inventory-items b)
    (let loop ((rs ($rows b)) (out '()))
      (if (null? rs)
          out
          (loop (cdr rs) (cons (cons (car (car rs)) (cdr (car rs))) out))))))
