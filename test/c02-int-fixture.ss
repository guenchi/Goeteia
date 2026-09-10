;; expect: (423 19 lo 2)
;; Fixture the integer product cell reads.  mix threads a nested bitwise
;; expression through a raw i32 intermediate; bump uses generic +, which
;; is not on the i32 path, and stays unchanged when the i32 classifier is
;; disabled -- the control that the classifier's effect is local.  gate
;; puts an i32 comparison in test position.  All three recurse so none is
;; inlined away.  second reads a pair's fields directly.
(import (rnrs))
(define (mix x n)
  (if (= n 0)
      x
      (mix (bitwise-xor (bitwise-arithmetic-shift-right x 1) (bitwise-and x 255)) (- n 1))))
(define (bump k n) (if (= n 0) k (bump (bitwise-and (+ k 3) 1023) (- n 1))))
(define (gate x n) (if (= n 0) (if (< (bitwise-and x 7) 3) 'lo 'hi) (gate x (- n 1))))
(define (second p n) (if (= n 0) (car (cdr p)) (second p (- n 1))))
(display (list (mix 12345 5) (bump 7 4) (gate 9 2) (second '(1 2) 2)))
