;; expect: #t
;; (gam inventory): counts by key, in an order that comes from the bag
;; and not from the player.
;;
;; Taking the last of something leaves the row in place with a count of
;; zero.  Dropping it would make the order of inventory-items a record
;; of what was done rather than of what was added, and this compiler's
;; cross-host byte-identity is a tested property: an order that depends
;; on history is an order that differs between two runs of the same
;; save.  There is no sort in this tree either, so the order has to be
;; kept rather than computed.
(import (rnrs) (gam inventory))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (keys bag) (map car (inventory-items bag)))

(check "an empty bag counts nothing" (= (inventory-count (make-inventory) 'rope) 0))
(check "adding answers the new count"
       (let ((b (make-inventory))) (and (= (inventory-add! b 'rope 2) 2)
                                        (= (inventory-add! b 'rope 3) 5))))
;; ---- order comes from the bag ----
(check "items keep the order they were first added in"
       (let ((b (make-inventory)))
         (inventory-add! b 'rope 1) (inventory-add! b 'torch 1) (inventory-add! b 'key 1)
         (equal? (keys b) '(rope torch key))))
(check "taking the last one leaves the row in place, at zero"
       (let ((b (make-inventory)))
         (inventory-add! b 'rope 1) (inventory-add! b 'torch 1)
         (inventory-take! b 'rope 1)
         (and (equal? (keys b) '(rope torch)) (= (inventory-count b 'rope) 0))))
(check "adding it back does not move it to the end"
       (let ((b (make-inventory)))
         (inventory-add! b 'rope 1) (inventory-add! b 'torch 1)
         (inventory-take! b 'rope 1) (inventory-add! b 'rope 4)
         (and (equal? (keys b) '(rope torch)) (= (inventory-count b 'rope) 4))))

;; ---- taking is all or nothing ----
(check "taking more than there is fails and takes NOTHING"
       (let ((b (make-inventory)))
         (inventory-add! b 'rope 2)
         (and (not (inventory-take! b 'rope 3)) (= (inventory-count b 'rope) 2))))
(check "taking exactly what is there succeeds"
       (let ((b (make-inventory)))
         (inventory-add! b 'rope 2) (inventory-take! b 'rope 2)))
(check "taking from a key never seen fails"
       (not (inventory-take! (make-inventory) 'ghost 1)))

;; ---- the answer is a copy ----
(check "mutating what inventory-items returned does not reach the bag"
       (let ((b (make-inventory)))
         (inventory-add! b 'rope 1)
         (set-cdr! (car (inventory-items b)) 999)
         (= (inventory-count b 'rope) 1)))

;; ---- refusals ----
(check "adding zero is refused"     (refuses? (lambda () (inventory-add! (make-inventory) 'rope 0))))
(check "adding a negative is refused"(refuses? (lambda () (inventory-add! (make-inventory) 'rope -1))))
(check "taking zero is refused"     (refuses? (lambda () (inventory-take! (make-inventory) 'rope 0))))
;; eq? on two separately computed equal bignums answers #f on one target
;; and #t on the other, so a key that is not eq?-reliable would make one
;; save behave differently on the two backends
(check "a key that eq? cannot answer for is refused, not silently never matched"
       (refuses? (lambda () (inventory-add! (make-inventory) "rope" 1))))
(display (= failed 0))
