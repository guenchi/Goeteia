;; expect: #t
;; (gam quest): objectives that only count once, listed in the order the
;; quest defines rather than the order the player happened to hit them.
;;
;; The order matters for the same reason it does in the bag: two players
;; who did the same things in a different sequence must produce the same
;; output, or a saved quest is not comparable with itself.
(import (rnrs) (gam quest))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (q) (make-quest '(bell book candle)))

(check "nothing is recorded to start with" (= (quest-count (q)) 0))
(check "a fresh quest is not complete" (not (quest-complete? (q))))
(check "recording an objective advances it"
       (let ((x (q))) (and (quest-record! x 'bell) (= (quest-count x) 1))))
(check "recording the same objective twice does not advance it, and says so"
       (let ((x (q)))
         (quest-record! x 'bell)
         (and (not (quest-record! x 'bell)) (= (quest-count x) 1))))
(check "an objective the quest does not have is refused as a no"
       (let ((x (q))) (and (not (quest-record! x 'sword)) (= (quest-count x) 0))))
(check "all three completes it"
       (let ((x (q)))
         (quest-record! x 'bell) (quest-record! x 'book) (quest-record! x 'candle)
         (quest-complete? x)))

;; ---- order comes from the definition ----
;; recorded bell-then-candle, so the reverse of the arrival order is
;; (candle bell) -- if this cell used the other pair, reverse-arrival
;; would coincide with the definition order and the cell would pass for
;; the wrong reason.  It did, until a mutation to record order left it
;; green.
(check "keys come back in the quest's order, not the order they arrived"
       (let ((x (q)))
         (quest-record! x 'bell) (quest-record! x 'candle)
         (equal? (quest-keys x) '(bell candle))))
(check "two different orders of the same events give the same keys"
       (let ((a (q)) (b (q)))
         (quest-record! a 'candle) (quest-record! a 'book)
         (quest-record! b 'book) (quest-record! b 'candle)
         (equal? (quest-keys a) (quest-keys b))))

;; ---- restore ----
(check "restore replaces what was there"
       (let ((x (q)))
         (quest-record! x 'bell)
         (quest-restore! x '(book candle))
         (equal? (quest-keys x) '(book candle))))
(check "restore ignores keys the quest does not have"
       (let ((x (q))) (quest-restore! x '(book sword)) (equal? (quest-keys x) '(book))))
(check "restore ignores repeats"
       (let ((x (q))) (quest-restore! x '(book book)) (= (quest-count x) 1)))

;; ---- a quest that cannot be finished honestly is refused ----
(check "a repeated objective in the definition is refused"
       (refuses? (lambda () (make-quest '(bell bell)))))
(display (= failed 0))
