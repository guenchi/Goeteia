;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20b):
;; the fixnum arithmetic, comparisons, predicates, the fx div family, the
;; carries and the fixnum bit operations.  A fixnum here is 30 bits: a result outside
;; -2^29 .. 2^29-1 raises, and the rows at that edge are goeteia's own.
;;
;; Each row is an expression and the answer Chez 10 gives for it in (rnrs),
;; compared as a value.  A row that raises here answers `raised'.  A row
;; with a comment above it pins goeteia's own answer where its domain is
;; narrower than R6RS's.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 1
      (guard (c (#t 'raised))
        (list (fx+ 1 2) (fx+ -5 5) (fx- 1 2) (fx- 5) (fx- -7) (fx* 3 4) (fx* -3 4) (fx* 0 9)))
      '(3 0 -1 -5 7 12 -12 0))
(want 2
      (guard (c (#t 'raised))
        (list (fx+ 536870910 1) (fx- -536870911 1) (fx* 23170 23170) (fx* -23170 23170) (fx- 536870911)))
      '(536870911 -536870912 536848900 -536848900 -536870911))
(want 3
      (guard (c (#t 'raised))
        (list (fx=? 1 1) (fx=? 1 2) (fx=? 1 1 1) (fx=? 1 1 2) (fx<? 1 2) (fx<? 2 1) (fx<? 1 2 3) (fx<? 1 3 2)))
      '(#t #f #t #f #t #f #t #f))
(want 4
      (guard (c (#t 'raised))
        (list (fx>? 2 1) (fx>? 1 2) (fx>? 3 2 1) (fx>? 3 1 2) (fx<=? 1 1 2) (fx<=? 2 1) (fx>=? 2 2 1) (fx>=? 1 2)))
      '(#t #f #t #f #t #f #t #f))
(want 5
      (guard (c (#t 'raised))
        (list (fxzero? 0) (fxzero? 1) (fxpositive? 1) (fxpositive? 0) (fxpositive? -1) (fxnegative? -1) (fxnegative? 0) (fxodd? 3) (fxodd? 4) (fxodd? -3) (fxeven? 4) (fxeven? 3) (fxeven? 0)))
      '(#t #f #t #f #f #t #f #t #f #t #t #f #t))
(want 6
      (guard (c (#t 'raised))
        (list (fxmax 1 3 2) (fxmin 1 3 2) (fxmax 5) (fxmin 5) (fxmax -1 -2) (fxmin -1 -2)))
      '(3 1 5 5 -1 -2))
(want 7
      (guard (c (#t 'raised))
        (list (fxdiv 7 2) (fxmod 7 2) (fxdiv -7 2) (fxmod -7 2) (fxdiv 7 -2) (fxmod 7 -2) (fxdiv -7 -2) (fxmod -7 -2)))
      '(3 1 -4 1 -3 1 4 1))
(want 8
      (guard (c (#t 'raised))
        (list (fxdiv0 7 2) (fxmod0 7 2) (fxdiv0 -7 2) (fxmod0 -7 2) (fxdiv0 5 10) (fxmod0 5 10) (fxdiv0 -5 10) (fxmod0 -5 10)))
      '(4 -1 -3 -1 1 -5 0 -5))
(want 9
      (guard (c (#t 'raised))
        (list (call-with-values (lambda () (fxdiv-and-mod 7 2)) list) (call-with-values (lambda () (fxdiv-and-mod -7 2)) list) (call-with-values (lambda () (fxdiv0-and-mod0 7 2)) list) (call-with-values (lambda () (fxdiv0-and-mod0 -7 2)) list)))
      '((3 1) (-4 1) (4 -1) (-3 -1)))
(want 10
      (guard (c (#t 'raised))
        (list (call-with-values (lambda () (fx+/carry 1 2 3)) list) (call-with-values (lambda () (fx-/carry 10 2 3)) list) (call-with-values (lambda () (fx*/carry 4 5 6)) list) (call-with-values (lambda () (fx+/carry -1 -2 -3)) list)))
      '((6 0) (5 0) (26 0) (-6 0)))
;; row 11 is goeteia's answer, not Chez's: carries past goeteia's 30-bit
;; fixnums (Chez's are 61 bits): 2^29, -2^29-1, 2^30-2 and -2^30 as a sum, a
;; difference and two products
(want 11
      (guard (c (#t 'raised))
        (list (call-with-values (lambda () (fx+/carry 536870911 1 0)) list) (call-with-values (lambda () (fx-/carry -536870912 1 0)) list) (call-with-values (lambda () (fx*/carry 536870911 2 0)) list) (call-with-values (lambda () (fx*/carry -536870912 2 0)) list)))
      '((-536870912 1) (536870911 -1) (-2 1) (0 -1)))
(want 12
      (guard (c (#t 'raised))
        (list (fxnot 0) (fxnot 5) (fxnot -1) (fxand 12 10) (fxior 12 10) (fxxor 12 10) (fxand) (fxior) (fxxor) (fxand 7) (fxand 15 7 5) (fxior 1 2 4) (fxxor 1 3 7) (fxand -1 5) (fxior -8 5) (fxxor -1 5)))
      '(-1 -6 0 8 14 6 -1 0 0 7 5 7 5 5 -3 -6))
(want 13
      (guard (c (#t 'raised))
        (list (fxif 12 10 5) (fxif 0 10 5) (fxif -1 10 5)))
      '(9 5 10))
(want 14
      (guard (c (#t 'raised))
        (list (fxbit-count 7) (fxbit-count 0) (fxbit-count 255) (fxbit-count -1) (fxbit-count -8)))
      '(3 0 8 -1 -4))
(want 15
      (guard (c (#t 'raised))
        (list (fxlength 0) (fxlength 1) (fxlength 255) (fxlength 256) (fxlength -1) (fxlength -256) (fxlength -257)))
      '(0 1 8 9 0 8 9))
(want 16
      (guard (c (#t 'raised))
        (list (fxfirst-bit-set 0) (fxfirst-bit-set 1) (fxfirst-bit-set 12) (fxfirst-bit-set -4) (fxfirst-bit-set 268435456)))
      '(-1 0 2 2 28))
(want 17
      (guard (c (#t 'raised))
        (list (fxbit-set? 5 0) (fxbit-set? 5 1) (fxbit-set? 5 2) (fxbit-set? -1 20) (fxbit-set? 0 3)))
      '(#t #f #t #t #f))
(want 18
      (guard (c (#t 'raised))
        (list (fxcopy-bit 0 2 1) (fxcopy-bit 15 0 0) (fxcopy-bit 15 2 1) (fxcopy-bit -1 3 0)))
      '(4 14 15 -9))
(want 19
      (guard (c (#t 'raised))
        (list (fxbit-field 214 2 5) (fxbit-field 214 0 8) (fxbit-field 214 3 3) (fxbit-field -1 4 8)))
      '(5 214 0 15))
(want 20
      (guard (c (#t 'raised))
        (list (fxcopy-bit-field 0 2 5 7) (fxcopy-bit-field 255 2 5 0) (fxcopy-bit-field 214 0 4 9)))
      '(28 227 217))
(want 21
      (guard (c (#t 'raised))
        (list (fxarithmetic-shift 1 4) (fxarithmetic-shift 16 -2) (fxarithmetic-shift -16 -2) (fxarithmetic-shift 5 0) (fxarithmetic-shift-left 3 5) (fxarithmetic-shift-right 96 5) (fxarithmetic-shift-right -1 10) (fxarithmetic-shift-left 1 28)))
      '(16 4 -4 5 96 3 -1 268435456))
(want 22
      (guard (c (#t 'raised))
        (list (fxrotate-bit-field 214 1 5 1) (fxrotate-bit-field 214 0 8 3) (fxrotate-bit-field 214 2 2 0) (fxreverse-bit-field 214 1 5) (fxreverse-bit-field 214 0 8) (fxreverse-bit-field 1 0 4)))
      '(206 182 214 218 107 8))
;; row 23 is goeteia's answer, not Chez's: results outside goeteia's 30-bit
;; fixnums raise; Chez's fixnums are 61 bits and it answers them
(want 23
      (guard (c (#t 'raised))
        (list (guard (c (#t 'raised)) (fx+ 536870911 1)) (guard (c (#t 'raised)) (fx- -536870912 1)) (guard (c (#t 'raised)) (fx* 65536 65536)) (guard (c (#t 'raised)) (fx- -536870912)) (guard (c (#t 'raised)) (fxarithmetic-shift-left 1 30)) (guard (c (#t 'raised)) (fxarithmetic-shift 3 29))))
      '(raised raised raised raised raised raised))

(display (if (null? fails) #t (reverse fails)))
