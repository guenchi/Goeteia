;; expect: #t
;; quotient and remainder by zero raise an &assertion that a handler can
;; catch, on every path the compiler has for them: the generic one, the
;; inline fixnum one, the one for operands it can prove are fixnums, and
;; inside unboxed integer arithmetic; with fixnum, bignum and flonum
;; operands (ledger R83).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; Each `site' row answers (kind error? violation? i/o-read? message?
;; irritants?) for what the expression raises.
;;
;; ON THE TREE BEFORE THE CHANGE the program stops on the first fixnum
;; division by zero, uncaught, or does not compile (vector-map takes one
;; vector).
(import (rnrs))

;; what a raise inside the thunk is: (kind who), or the value when none
(define (caught thunk)
  (guard (c (#t (list (cond ((assertion-violation? c) 'assertion)
                            ((error? c) 'error)
                            ((condition? c) 'condition)
                            (else 'not-a-condition))
                      (and (who-condition? c) (condition-who c)))))
    (thunk)))
(define zero 0)
(define seven 7)
(define (q a b) (quotient a b))
(define (r a b) (remainder a b))
;; operands the compiler can prove are fixnums
(define (qf a b) (quotient (bitwise-and a 255) (bitwise-and b 255)))
(define (rf a b) (remainder (bitwise-and a 255) (bitwise-and b 255)))
;; the same inside unboxed integer arithmetic
(define (qi a b) (bitwise-and (quotient (bitwise-and a 255) (bitwise-and b 255)) 255))
(define (ri a b) (bitwise-and (remainder (bitwise-and a 255) (bitwise-and b 255)) 255))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'quotient-literal-zero
      (guard (c (#t 'raised))
        (caught (lambda () (quotient 7 0))))
      '(assertion quotient))
(want 'remainder-literal-zero
      (guard (c (#t 'raised))
        (caught (lambda () (remainder 7 0))))
      '(assertion remainder))
(want 'quotient-variable-zero
      (guard (c (#t 'raised))
        (caught (lambda () (quotient seven zero))))
      '(assertion quotient))
(want 'remainder-variable-zero
      (guard (c (#t 'raised))
        (caught (lambda () (remainder seven zero))))
      '(assertion remainder))
(want 'through-a-procedure
      (guard (c (#t 'raised))
        (list (caught (lambda () (q 7 0))) (caught (lambda () (r 7 0)))))
      '((assertion quotient) (assertion remainder)))
(want 'provably-fixnum-operands
      (guard (c (#t 'raised))
        (list (caught (lambda () (qf 7 0))) (caught (lambda () (rf 7 0)))))
      '((assertion quotient) (assertion remainder)))
(want 'inside-unboxed-arithmetic
      (guard (c (#t 'raised))
        (list (caught (lambda () (qi 7 0))) (caught (lambda () (ri 7 0)))))
      '((assertion quotient) (assertion remainder)))
(want 'bignum-dividend
      (guard (c (#t 'raised))
        (list (caught (lambda () (quotient 100000000000000000000 0))) (caught (lambda () (remainder 100000000000000000000 zero)))))
      '((assertion quotient) (assertion remainder)))
(want 'flonum-operands
      (guard (c (#t 'raised))
        (list (caught (lambda () (quotient 7.0 0))) (caught (lambda () (quotient 7 0.0))) (caught (lambda () (remainder 7.0 0))) (caught (lambda () (remainder 7.0 0.0)))))
      '((assertion quotient) (assertion quotient) (assertion remainder) (assertion remainder)))
(want 'in-a-loop-the-program-goes-on
      (guard (c (#t 'raised))
        (let loop ((i 0) (acc '())) (if (= i 4) (reverse acc) (loop (+ i 1) (cons (caught (lambda () (quotient 12 (- 2 i)))) acc)))))
      '(6 12 (assertion quotient) -12))
(want 'non-zero-answers-unchanged
      (guard (c (#t 'raised))
        (list (quotient 7 2) (quotient -7 2) (remainder -7 2) (remainder 7 -2) (q 100 7) (qf 200 7) (ri 200 7) (quotient 100000000000000000000 3) (quotient 7.0 2) (remainder -7.0 2)))
      '(3 -3 -1 1 14 28 4 33333333333333333333 3.0 -1.0))
(want 'the-most-negative-fixnum-over-minus-one
      (guard (c (#t 'raised))
        (let ((m -536870912)) (list (quotient m -1) (remainder m -1))))
      '(536870912 0))

(display (if (null? fails) #t (reverse fails)))
