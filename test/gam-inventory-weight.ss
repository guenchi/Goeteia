;; expect: #t
;; What a bag weighs, given what its items weigh.
;;
;; THE WEIGHT TABLE IS THE CALLER'S.  This library knows counts and keys
;; and has never known what an item is; a weight per item is exactly the
;; kind of thing it must not start knowing.  So the caller passes a
;; procedure and the library folds it over the rows -- which also means
;; the same bag answers different totals under different rules (carried
;; versus stored, a strength modifier, a bag of holding) without this
;; library having a word for any of them.
;;
;; A MISSING WEIGHT IS AN ERROR, NOT A ZERO.  A key the table does not
;; know is a bag and a table that have drifted apart, and answering
;; anyway would report a total that is quietly too small -- the failure
;; would show up as a carrying limit that is never reached.  The error
;; names the key, because that is the one thing the caller needs.
;;
;; THE EMPTY BAG WEIGHS EXACT ZERO.  The library has no weights of its
;; own and so has no exactness of its own; the total's exactness comes
;; from the caller's numbers, and starting the fold at 0.0 would put an
;; inexactness into an answer where every input was exact.
(import (rnrs) (gam inventory))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (refused? who thunk)
  (guard (e (#t (eq? (condition-who e) who))) (thunk) #f))
(define (weights key)
  (case key ((stone) 5) ((feather) 1/4) ((anvil) 100.0) (else (error 'weights "unknown" key))))

(let ((b (make-inventory)))
  (want "an empty bag weighs zero" (inventory-weight b weights) 0)
  (want "and that zero is exact" (exact? (inventory-weight b weights)) #t)
  (inventory-add! b 'stone 3)
  (want "weight is the count times the weight" (inventory-weight b weights) 15)
  (inventory-add! b 'feather 8)
  (want "and sums across items" (inventory-weight b weights) 17)
  (want "an exact total stays exact" (exact? (inventory-weight b weights)) #t)
  ;; THE COUNT MUST BE IN IT.  Every row above would also be satisfied by
  ;; a fold that added the weights and ignored how many there are, except
  ;; that 3 stones weigh 15 and not 5 -- so this pins it again from the
  ;; other side, by changing only the count.
  (inventory-add! b 'stone 1)
  (want "adding one more stone adds one more stone's weight" (inventory-weight b weights) 22)
  (inventory-take! b 'stone 4)
  (want "and taking them out takes the weight with them" (inventory-weight b weights) 2)
  ;; An inexact weight makes the total inexact, which is the caller's
  ;; arithmetic showing through rather than this library's.
  (inventory-add! b 'anvil 1)
  (want "an inexact weight carries into the total" (exact? (inventory-weight b weights)) #f)
  (want "and the total is right" (< (abs (- (inventory-weight b weights) 102.0)) 0.00001) #t))

;; Refusals.
(let ((b (make-inventory)))
  (inventory-add! b 'mystery 1)
  (want "a key the table does not know is an error"
        (refused? 'inventory-weight (lambda () (inventory-weight b (lambda (k) (if (eq? k 'mystery) #f 1))))) #t)
  (want "a negative weight is an error"
        (refused? 'inventory-weight (lambda () (inventory-weight b (lambda (k) -1)))) #t)
  (want "a non-real weight is an error"
        (refused? 'inventory-weight (lambda () (inventory-weight b (lambda (k) 'heavy)))) #t)
  ;; NaN is neither negative nor non-real, and it names no key when it
  ;; reaches the total: it just makes the total NaN.
  (want "a NaN weight is an error"
        (refused? 'inventory-weight (lambda () (inventory-weight b (lambda (k) +nan.0)))) #t))
;; A bag emptied by take! is as empty as one never filled.  Rows kept at
;; count zero must not reach the weight table, or an inexact or infinite
;; weight for an item no longer held would show in the total.
(let ((b (make-inventory)))
  (inventory-add! b 'anvil 2)
  (inventory-take! b 'anvil 2)
  (want "an emptied bag weighs exact zero" (inventory-weight b (lambda (k) 100.0)) 0)
  (want "even under an infinite weight" (inventory-weight b (lambda (k) +inf.0)) 0))
(want "weighing a non-inventory is refused"
      (refused? 'inventory-weight (lambda () (inventory-weight (vector 1 2) weights))) #t)
(want "a weight table that is not a procedure is refused"
      (refused? 'inventory-weight (lambda () (inventory-weight (make-inventory) '((stone . 5))))) #t)

;; The table is asked about KEYS, not handed the library's rows.  A
;; caller that received a pair could set-cdr! a count past every check
;; inventory-add! makes -- the same reason inventory-items copies.
(let ((b (make-inventory)) (seen '()))
  (inventory-add! b 'stone 2)
  (inventory-weight b (lambda (k) (set! seen (cons k seen)) 1))
  (want "the weight table sees the key itself" seen '(stone)))

(if (null? fails) #t fails)
