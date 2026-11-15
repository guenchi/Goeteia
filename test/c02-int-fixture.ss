;; expect: (423 19 lo 2 0)
;; Fixture the integer product cell reads.  mix threads a nested bitwise
;; expression through a raw i32 intermediate; bump uses generic +, which
;; is not on the i32 path, and stays unchanged when the i32 classifier is
;; disabled -- the control that the classifier's effect is local.  gate
;; puts an i32 comparison in test position.  All three recurse so none is
;; inlined away.  second reads a pair's fields directly.
;;
;; Since batch M50 (ledger R76, design (III)) a bitwise form is an i32
;; tree only over typed operands.  mix's x and gate's x are parameters,
;; and bump's (+ k 3) is a generic sum, so their bitwise forms take the
;; generic path now.  mixb threads the same nested expression through
;; two byte loads, which are typed: its tree stays i32 and its
;; intermediate raw.
(import (rnrs))
(define (mix x n)
  (if (= n 0)
      x
      (mix (bitwise-xor (bitwise-arithmetic-shift-right x 1) (bitwise-and x 255)) (- n 1))))
(define (bump k n) (if (= n 0) k (bump (bitwise-and (+ k 3) 1023) (- n 1))))
(define (gate x n) (if (= n 0) (if (< (bitwise-and x 7) 3) 'lo 'hi) (gate x (- n 1))))
(define (second p n) (if (= n 0) (car (cdr p)) (second p (- n 1))))
(define (mixb p n acc)
  (if (= n 0)
      acc
      (mixb p (- n 1)
            (bitwise-xor (bitwise-arithmetic-shift-right (%mem-u8-ref p) 1)
                         (bitwise-and (%mem-u8-ref (+ p 1)) 255)))))
(display (list (mix 12345 5) (bump 7 4) (gate 9 2) (second '(1 2) 2) (mixb 0 3 0)))
