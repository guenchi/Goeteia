;; expect: #t
;; eqv? tells the two zeros apart, as R6RS (11.5) and Chez do (ledger R59):
;; (eqv? 0.0 -0.0) is #f, and every procedure built on eqv? follows --
;; equal?, memv, assv, case, eqv and equal hashtables.  A NaN is eqv? to a
;; NaN, as on Chez (R6RS leaves it open).
;;
;; Every answer is the one Chez 10 gives.
;;
;; ON THE TREE BEFORE THE CHANGE the zeros were one value to eqv?: rows
;; zeros, equal, memv, assv, case and the two hashtable rows were red, and
;; nan was red where the two NaNs were different objects.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

(want 'zeros
      (guard (c (#t 'raised))
        (list (eqv? 0.0 -0.0) (eqv? -0.0 -0.0) (eqv? 0.0 0.0) (eqv? -0.0 (* -1.0 0.0)) (eqv? 0.0 (- 0.0 0.0))))
      '(#f #t #t #t #t))
(want 'nan
      (guard (c (#t 'raised))
        (let ((n (- +inf.0 +inf.0))) (list (eqv? n n) (eqv? +nan.0 n) (eqv? n 0.0) (eqv? 1.0 n))))
      '(#t #t #f #f))
(want 'ordinary
      (guard (c (#t 'raised))
        (list (eqv? 1.5 1.5) (eqv? 1.5 1.25) (eqv? 2.0 2) (eqv? +inf.0 +inf.0) (eqv? +inf.0 -inf.0) (eqv? (/ 1.0 3.0) (/ 1.0 3.0))))
      '(#t #f #f #t #f #t))
(want 'equal
      (guard (c (#t 'raised))
        (list (equal? '(0.0) '(-0.0)) (equal? '#(-0.0) '#(-0.0)) (equal? (list 1 -0.0) (list 1 0.0)) (equal? 0.0 -0.0)))
      '(#f #t #f #f))
(want 'memv
      (guard (c (#t 'raised))
        (list (memv -0.0 '(0.0 -0.0 1.0)) (memv 0.0 '(-0.0 0.0)) (memv -0.0 '(0.0)) (member -0.0 '((a) 0.0 -0.0))))
      '((-0.0 1.0) (0.0) #f (-0.0)))
(want 'assv
      (guard (c (#t 'raised))
        (list (assv 0.0 '((-0.0 . neg) (0.0 . pos))) (assv -0.0 '((0.0 . pos) (-0.0 . neg))) (assoc -0.0 '((0.0 . pos)))))
      '((0.0 . pos) (-0.0 . neg) #f))
(want 'case
      (guard (c (#t 'raised))
        (list (case -0.0 ((0.0) 'pos) ((-0.0) 'neg) (else 'none)) (case 0.0 ((-0.0) 'neg) ((0.0) 'pos) (else 'none)) (case 1.5 ((1.5) 'yes) (else 'no))))
      '(neg pos yes))
(want 'hashtable
      (guard (c (#t 'raised))
        (let ((h (make-eqv-hashtable))) (hashtable-set! h 0.0 'pos) (hashtable-set! h -0.0 'neg) (list (hashtable-size h) (hashtable-ref h 0.0 #f) (hashtable-ref h -0.0 #f) (hashtable-ref h (* -1.0 0.0) #f))))
      '(2 pos neg neg))
(want 'equal-hashtable
      (guard (c (#t 'raised))
        (let ((h (make-hashtable equal-hash equal?))) (hashtable-set! h '(0.0) 'pos) (hashtable-set! h '(-0.0) 'neg) (list (hashtable-size h) (hashtable-ref h (list -0.0) #f))))
      '(2 neg))
(want 'sign-kept
      (guard (c (#t 'raised))
        (let ((z (* -1.0 0.0))) (list (eqv? z -0.0) (fl<? (fl/ 1.0 z) 0.0))))
      '(#t #t))

(display (if (null? fails) #t (reverse fails)))
