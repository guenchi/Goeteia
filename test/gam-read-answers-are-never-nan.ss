;; expect: #t
;; A (gam ...) library's computed answer is a number: infinite when the
;; inputs add up to that, of either sign, never NaN.
;;
;; inventory-weight and modifier-ref answer values they compute from
;; the caller's numbers rather than values they store, so the finite-
;; as-a-flonum rule for stored sums does not apply: an infinitely heavy
;; item makes an infinitely heavy bag, which is a definite answer, and
;; the library says so in its own comments.  NaN is not an answer.  It
;; compares false with everything, so a carrying limit is never
;; reached and a scaled attribute is neither above nor below any
;; threshold, and nothing names the item or the attribute that did it.
;;
;; ROUTES TO NaN FROM INPUTS THAT EACH PASSED.
;;   inventory: a count is an exact integer of any size, a weight is a
;;   non-negative real; (* 2^1024 0.0) is NaN, measured 2026-09-25.
;;   The refusal names the item, its count and its weight, and it is
;;   the item that did it, wherever it sits among good rows.
;;   modifiers: every row value is finite as a flonum, but an
;;   aggregate is a sum of rows and can reach an infinity, and then
;;   0 times it, from either side, is NaN: a base of 0.0 under an
;;   overflowed scale, or an overflowed base under a scale of -1.0.
;;   The aggregate cannot be caught when a row is set: rows +1e308,
;;   -1e308, +1e308 leave it finite after every set, and removing the
;;   negative row afterwards makes it infinite.  So the check is at
;;   the read, on the product, naming the attribute and both
;;   aggregates.
(import (rnrs) (gam inventory) (gam modifiers))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (two^ n) (let loop ((i 0) (x 1)) (if (= i n) x (loop (+ i 1) (* x 2)))))
(define (nan? x) (and (real? x) (not (= x x))))

(define (try thunk)
  (guard (e (#t (list 'raised (condition-who e) (condition-irritants e))))
    (list 'returned (thunk))))
(define (outcome r) (if (eq? (car r) 'raised) (list 'raised (cadr r)) r))
(define (names? r sym) (and (eq? (car r) 'raised) (pair? (caddr r)) (memq sym (caddr r)) #t))
(define (irritant-present? r v)
  (and (eq? (car r) 'raised)
       (let any ((l (caddr r)))
         (and (pair? l) (or (and (real? (car l)) (= (car l) v)) (any (cdr l)))))))

;; ---- inventory ----
(define (weight-of key)
  (case key ((anvil) +inf.0) ((air) 0.0) ((stone) 1.0) (else #f)))
;; The bad row behind good ones: air is added first, so it is the last
;; row the fold reaches.
(let ((b (make-inventory)))
  (inventory-add! b 'air (two^ 1024))
  (inventory-add! b 'anvil 1)
  (inventory-add! b 'stone 3)
  (let ((r (try (lambda () (inventory-weight b weight-of)))))
    (want "a count times a weight that is not a number is refused" (outcome r) '(raised inventory-weight))
    (want "and the refusal names the item that did it, not the first item" (names? r 'air) #t)
    (want "and does not name the others" (or (names? r 'anvil) (names? r 'stone)) #f)
    (want "and names its count" (irritant-present? r (two^ 1024)) #t)
    (want "and its weight" (irritant-present? r 0.0) #t)))
(let ((b (make-inventory)))
  (inventory-add! b 'air (two^ 1024))
  (want "the same as the only row: still refused, still named"
        (names? (try (lambda () (inventory-weight b weight-of))) 'air) #t))
(let ((b (make-inventory)))
  (inventory-add! b 'anvil 1)
  (inventory-add! b 'stone 3)
  (want "CONTROL an infinitely heavy item makes an infinitely heavy bag, which is an answer"
        (inventory-weight b weight-of) +inf.0))
(let ((b (make-inventory)))
  (inventory-add! b 'stone 3)
  (want "CONTROL three stones weigh 3.0" (inventory-weight b weight-of) 3.0))

;; ---- modifiers ----
(define (scale-of attribute) (if (eq? attribute 'power) 'power-scale #f))
;; 0.0 under an overflowed scale
(let ((m (make-modifiers scale-of)))
  (modifier-set! m 'base 'power 0.0)
  (modifier-set! m 'buff 'power-scale 1e308)
  (modifier-set! m 'debuff 'power-scale -1e308)
  (modifier-set! m 'buff2 'power-scale 1e308)
  (want "with the aggregate finite, 0.0 scaled is 0.0" (modifier-ref m 'power) 0.0)
  (modifier-remove-source! m 'debuff)
  (let ((r (try (lambda () (modifier-ref m 'power)))))
    (want "a product that is not a number is refused at the read" (outcome r) '(raised modifier-ref))
    (want "and the refusal names the attribute" (names? r 'power) #t)
    (want "and the base aggregate" (irritant-present? r 0.0) #t)
    (want "and the scale aggregate" (irritant-present? r +inf.0) #t))
  (modifier-set! m 'base 'power 2.0)
  (want "CONTROL an infinite scale of a positive base is +inf.0, an answer"
        (modifier-ref m 'power) +inf.0)
  (modifier-set! m 'base 'power -2.0)
  (want "CONTROL and of a negative base is -inf.0, also an answer"
        (modifier-ref m 'power) -inf.0))
;; an overflowed base under a scale of -1.0: the zero on the other side
(let ((m (make-modifiers scale-of)))
  (modifier-set! m 'a 'power 1e308)
  (modifier-set! m 'b 'power 1e308)
  (modifier-set! m 'nerf 'power-scale -1.0)
  (let ((r (try (lambda () (modifier-ref m 'power)))))
    (want "an overflowed base times a scale of zero is refused at the read" (outcome r) '(raised modifier-ref))
    (want "naming the attribute" (names? r 'power) #t))
  (modifier-remove-source! m 'nerf)
  (want "CONTROL the overflowed base alone is +inf.0, an answer" (modifier-ref m 'power) +inf.0))
(let ((m (make-modifiers scale-of)))
  (modifier-set! m 'base 'power 2.0)
  (modifier-set! m 'buff 'power-scale 0.5)
  (want "CONTROL 2 scaled by a half more is 3" (modifier-ref m 'power) 3.0))

(display (if (null? fails) #t (reverse fails)))
