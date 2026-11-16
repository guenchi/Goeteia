;; expect: #t
;; arithmetic and the numeric comparisons raise &assertion for an argument
;; that is not a number (a real where the operation needs one): +, -, *, /,
;; abs, max, min, zero?, the comparisons, the fl and string comparisons
;; (R6RS 11.7; ledger R93 and R102, batch M58).  The valid answers of the
;; same operations on fixnums, bignums, ratios, flonums and complex numbers
;; are pinned too: the type test must not move the dispatch.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE (6bdfbbd) a non-number traps on wasm (an
;; illegal cast, which no handler catches) and on JS answers wrongly or
;; throws a host error, so the program dies before it prints.
(import (rnrs))

(define (kind thunk)
  (guard (e ((assertion-violation? e) 'assertion) (#t 'other)) (thunk) 'no-condition))
(define sym (string->symbol "x"))
(define str (string-copy "s"))
(define big (* 1099511627776 3))
(define rat (/ 1 3))
(define fl 1.5)
(define cx (make-rectangular 1 2))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'raises-plus-sym-second
      (guard (c (#t 'raised))
        (kind (lambda () (+ 1 sym))))
      'assertion)
(want 'raises-plus-sym-first
      (guard (c (#t 'raised))
        (kind (lambda () (+ sym 1))))
      'assertion)
(want 'raises-plus-flonum-sym
      (guard (c (#t 'raised))
        (kind (lambda () (+ fl sym))))
      'assertion)
(want 'raises-plus-bignum-sym
      (guard (c (#t 'raised))
        (kind (lambda () (+ big sym))))
      'assertion)
(want 'raises-plus-ratio-sym
      (guard (c (#t 'raised))
        (kind (lambda () (+ rat sym))))
      'assertion)
(want 'raises-plus-string
      (guard (c (#t 'raised))
        (kind (lambda () (+ str 1))))
      'assertion)
(want 'raises-plus-three
      (guard (c (#t 'raised))
        (kind (lambda () (+ 1 2 sym))))
      'assertion)
(want 'raises-minus
      (guard (c (#t 'raised))
        (kind (lambda () (- 1 sym))))
      'assertion)
(want 'raises-minus-one-arg
      (guard (c (#t 'raised))
        (kind (lambda () (- sym))))
      'assertion)
(want 'raises-times
      (guard (c (#t 'raised))
        (kind (lambda () (* 1 sym))))
      'assertion)
(want 'raises-times-flonum
      (guard (c (#t 'raised))
        (kind (lambda () (* fl sym))))
      'assertion)
(want 'raises-times-three
      (guard (c (#t 'raised))
        (kind (lambda () (* sym 1 2))))
      'assertion)
(want 'raises-divide-second
      (guard (c (#t 'raised))
        (kind (lambda () (/ 1 sym))))
      'assertion)
(want 'raises-divide-first
      (guard (c (#t 'raised))
        (kind (lambda () (/ sym 2))))
      'assertion)
(want 'raises-abs
      (guard (c (#t 'raised))
        (kind (lambda () (abs sym))))
      'assertion)
(want 'raises-max
      (guard (c (#t 'raised))
        (kind (lambda () (max sym 1))))
      'assertion)
(want 'raises-min
      (guard (c (#t 'raised))
        (kind (lambda () (min 1 sym))))
      'assertion)
(want 'raises-zero
      (guard (c (#t 'raised))
        (kind (lambda () (zero? sym))))
      'assertion)
(want 'raises-less
      (guard (c (#t 'raised))
        (kind (lambda () (< 2 sym))))
      'assertion)
(want 'raises-equal
      (guard (c (#t 'raised))
        (kind (lambda () (= 1 sym))))
      'assertion)
(want 'raises-greater
      (guard (c (#t 'raised))
        (kind (lambda () (> 2 sym))))
      'assertion)
(want 'raises-less-equal
      (guard (c (#t 'raised))
        (kind (lambda () (<= 2 sym))))
      'assertion)
(want 'raises-greater-equal
      (guard (c (#t 'raised))
        (kind (lambda () (>= 2 sym))))
      'assertion)
(want 'raises-less-flonum
      (guard (c (#t 'raised))
        (kind (lambda () (< fl sym))))
      'assertion)
(want 'raises-equal-bignum
      (guard (c (#t 'raised))
        (kind (lambda () (= big sym))))
      'assertion)
(want 'raises-fl-less
      (guard (c (#t 'raised))
        (kind (lambda () (fl<? 1.0 sym))))
      'assertion)
(want 'raises-string-less
      (guard (c (#t 'raised))
        (kind (lambda () (string<? "a" 1))))
      'assertion)
(want 'plus-fixnums
      (guard (c (#t 'raised))
        (+ 1 2))
      '3)
(want 'plus-bignum
      (guard (c (#t 'raised))
        (+ big 1))
      '3298534883329)
(want 'plus-ratios
      (guard (c (#t 'raised))
        (+ rat rat))
      '2/3)
(want 'plus-flonum
      (guard (c (#t 'raised))
        (+ fl 1))
      '2.5)
(want 'plus-complex
      (guard (c (#t 'raised))
        (= (+ cx 1) (make-rectangular 2 2)))
      '#t)
(want 'minus-ratio
      (guard (c (#t 'raised))
        (- rat))
      '-1/3)
(want 'times-bignums
      (guard (c (#t 'raised))
        (* big big))
      '10880332376531662572355584)
(want 'divide
      (guard (c (#t 'raised))
        (/ 1 3))
      '1/3)
(want 'less-flonum-bignum
      (guard (c (#t 'raised))
        (< fl big))
      '#t)
(want 'equal-ratios
      (guard (c (#t 'raised))
        (= rat (/ 2 6)))
      '#t)
(want 'abs-negative
      (guard (c (#t 'raised))
        (abs -5))
      '5)
(want 'abs-bignum
      (guard (c (#t 'raised))
        (abs (- big)))
      '3298534883328)
(want 'max-mixed
      (guard (c (#t 'raised))
        (max 1 2.0))
      '2.0)
(want 'min-ratio
      (guard (c (#t 'raised))
        (min rat 1))
      '1/3)
(want 'zero-flonum
      (guard (c (#t 'raised))
        (zero? 0.0))
      '#t)
(want 'fl-less
      (guard (c (#t 'raised))
        (fl<? 1.0 2.0))
      '#t)
(want 'string-less
      (guard (c (#t 'raised))
        (string<? "a" "b"))
      '#t)

(display (if (null? fails) #t (reverse fails)))
