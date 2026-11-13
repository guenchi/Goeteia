;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20b):
;; the bitwise operations on exact integers of any size.
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
        (list (bitwise-not 0) (bitwise-not 5) (bitwise-not -1) (bitwise-not (* 65536 65536 65536)) (bitwise-not (- (* 65536 65536 65536)))))
      '(-1 -6 0 -281474976710657 281474976710655))
(want 2
      (guard (c (#t 'raised))
        (list (bitwise-arithmetic-shift 1 40) (bitwise-arithmetic-shift (* 65536 65536 65536) -38) (bitwise-arithmetic-shift -8 -1) (bitwise-arithmetic-shift 5 0) (bitwise-arithmetic-shift -1 40) (bitwise-arithmetic-shift (- (* 65536 65536 65536)) -40)))
      '(1099511627776 1024 -4 5 -1099511627776 -256))
(want 3
      (guard (c (#t 'raised))
        (list (bitwise-bit-count 7) (bitwise-bit-count 0) (bitwise-bit-count (* 65536 65536 65536)) (bitwise-bit-count (- (* 65536 65536 65536) 1)) (bitwise-bit-count -1) (bitwise-bit-count (- (* 65536 65536 65536)))))
      '(3 0 1 48 -1 -49))
(want 4
      (guard (c (#t 'raised))
        (list (bitwise-length 0) (bitwise-length 255) (bitwise-length 256) (bitwise-length (* 65536 65536 65536)) (bitwise-length -1) (bitwise-length (- (* 65536 65536 65536))) (bitwise-length (- -1 (* 65536 65536 65536)))))
      '(0 8 9 49 0 48 49))
(want 5
      (guard (c (#t 'raised))
        (list (bitwise-first-bit-set 0) (bitwise-first-bit-set 1) (bitwise-first-bit-set 12) (bitwise-first-bit-set (* 65536 65536 65536)) (bitwise-first-bit-set (- (* 65536 65536 65536)))))
      '(-1 0 2 48 48))
(want 6
      (guard (c (#t 'raised))
        (list (bitwise-bit-set? 5 0) (bitwise-bit-set? 5 1) (bitwise-bit-set? (* 65536 65536 65536) 48) (bitwise-bit-set? (* 65536 65536 65536) 47) (bitwise-bit-set? -1 100) (bitwise-bit-set? 5 100)))
      '(#t #f #t #f #t #f))
(want 7
      (guard (c (#t 'raised))
        (list (bitwise-if 12 10 5) (bitwise-if 0 10 5) (bitwise-if -1 10 5) (bitwise-if (* 65536 65536 65536) -1 0)))
      '(9 5 10 281474976710656))
(want 8
      (guard (c (#t 'raised))
        (list (bitwise-copy-bit 0 40 1) (bitwise-copy-bit 15 0 0) (bitwise-copy-bit (* 65536 65536 65536) 48 0) (bitwise-copy-bit -1 40 0)))
      '(1099511627776 14 0 -1099511627777))
(want 9
      (guard (c (#t 'raised))
        (list (bitwise-bit-field 214 2 5) (bitwise-bit-field (+ 5 (* 65536 65536 65536)) 40 49) (bitwise-bit-field -1 40 48) (bitwise-bit-field 214 3 3)))
      '(5 256 255 0))
(want 10
      (guard (c (#t 'raised))
        (list (bitwise-copy-bit-field 0 2 5 7) (bitwise-copy-bit-field 0 40 44 9) (bitwise-copy-bit-field (* 65536 65536 65536) 44 49 0) (bitwise-copy-bit-field 255 2 5 0)))
      '(28 9895604649984 0 227))
(want 11
      (guard (c (#t 'raised))
        (list (bitwise-rotate-bit-field 214 1 5 1) (bitwise-rotate-bit-field 214 0 8 3) (bitwise-rotate-bit-field (* 65536 65536 65536) 40 50 3) (bitwise-rotate-bit-field 214 2 2 0)))
      '(206 182 2199023255552 214))
(want 12
      (guard (c (#t 'raised))
        (list (bitwise-reverse-bit-field 214 1 5) (bitwise-reverse-bit-field 214 0 8) (bitwise-reverse-bit-field 1 0 40) (bitwise-reverse-bit-field (* 65536 65536 65536) 40 50)))
      '(218 107 549755813888 2199023255552))

(display (if (null? fails) #t (reverse fails)))
