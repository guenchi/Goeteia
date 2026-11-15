;; expect: #t
;; bitwise-and, bitwise-ior, bitwise-xor and the two arithmetic shifts take
;; exact integers of any size and answer exactly (R6RS 11.4; ledger R76,
;; batch M50): big operands of both signs, answers that come back into the
;; fixnum range as fixnums, any number of arguments for and / ior / xor,
;; left shifts past the fixnum range answered with the exact integer
;; rather than refused, what raises, the five as values, and the places
;; the compiler keeps integers unboxed -- a loop building a 64-bit value
;; from bytes, a mask of a big operand, a hash past 2^29, a shift within
;; and past the typed bound, a loop variable that grows.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: a direct
;; call of bitwise-and with three arguments is refused; and a big operand
;; traps, which no handler catches.
(import (rnrs))

(define c (string-ref (symbol->string (quote abc)) 0))
(define one (string->number "1"))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'and-big-big
      (guard (c (#t 'raised))
        (bitwise-and 1099511627777 2199023255551))
      '1099511627777)
(want 'and-negbig-mask
      (guard (c (#t 'raised))
        (bitwise-and -1099511627776 255))
      '0)
(want 'and-negbig-negbig
      (guard (c (#t 'raised))
        (bitwise-and -1099511627777 -34359738369))
      '-1133871366145)
(want 'and-big-fix
      (guard (c (#t 'raised))
        (bitwise-and 1152921504606846975 65535))
      '65535)
(want 'ior-big-fix
      (guard (c (#t 'raised))
        (bitwise-ior 1099511627776 1))
      '1099511627777)
(want 'ior-negbig-fix
      (guard (c (#t 'raised))
        (bitwise-ior -1099511627776 255))
      '-1099511627521)
(want 'ior-big-big
      (guard (c (#t 'raised))
        (bitwise-ior 1099511627776 34359738368))
      '1133871366144)
(want 'xor-negbig-minus-one
      (guard (c (#t 'raised))
        (bitwise-xor -1099511627776 -1))
      '1099511627775)
(want 'xor-big-big
      (guard (c (#t 'raised))
        (bitwise-xor 1152921504606846976 1152921504606846975))
      '2305843009213693951)
(want 'xor-big-self
      (guard (c (#t 'raised))
        (bitwise-xor 1099511627777 1099511627777))
      '0)
(want 'and-answer-back-in-range
      (guard (c (#t 'raised))
        (fixnum? (bitwise-and 1099511627777 255)))
      '#t)
(want 'xor-answer-back-in-range
      (guard (c (#t 'raised))
        (fixnum? (bitwise-xor 1099511627776 1099511627777)))
      '#t)
(want 'and-none
      (guard (c (#t 'raised))
        (bitwise-and))
      '-1)
(want 'ior-none
      (guard (c (#t 'raised))
        (bitwise-ior))
      '0)
(want 'xor-none
      (guard (c (#t 'raised))
        (bitwise-xor))
      '0)
(want 'and-one
      (guard (c (#t 'raised))
        (bitwise-and 12))
      '12)
(want 'and-three
      (guard (c (#t 'raised))
        (bitwise-and 12 10 8))
      '8)
(want 'ior-four
      (guard (c (#t 'raised))
        (bitwise-ior 1 2 4 8))
      '15)
(want 'xor-three
      (guard (c (#t 'raised))
        (bitwise-xor 1 3 7))
      '5)
(want 'and-three-big
      (guard (c (#t 'raised))
        (bitwise-and 1099511627775 -1 4294967295))
      '4294967295)
(want 'shl-1-28
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1 28))
      '268435456)
(want 'shl-1-29
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1 29))
      '536870912)
(want 'shl-1-30
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1 30))
      '1073741824)
(want 'shl-1-40
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1 40))
      '1099511627776)
(want 'shl-1-100
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1 100))
      '1267650600228229401496703205376)
(want 'shl-minus-one-29
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left -1 29))
      '-536870912)
(want 'shl-minus-one-30
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left -1 30))
      '-1073741824)
(want 'shl-3-28
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 3 28))
      '805306368)
(want 'shl-big-20
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1099511627776 20))
      '1152921504606846976)
(want 'shl-zero-100
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 0 100))
      '0)
(want 'shr-big-39
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-right 1099511627776 39))
      '2)
(want 'shr-negbig-100
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-right -1099511627776 100))
      '-1)
(want 'shr-negbig-1
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-right -1099511627777 1))
      '-549755813889)
(want 'shr-answer-back-in-range
      (guard (c (#t 'raised))
        (fixnum? (bitwise-arithmetic-shift-right 1099511627776 20)))
      '#t)
(want 'raises-shl-negative-count
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left 1 -1))
      'raised)
(want 'raises-shr-negative-count
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-right 1099511627776 -1))
      'raised)
(want 'raises-and-flonum
      (guard (c (#t 'raised))
        (bitwise-and 1.0 1))
      'raised)
(want 'raises-ior-symbol
      (guard (c (#t 'raised))
        (bitwise-ior 'a 1))
      'raised)
(want 'raises-xor-ratio
      (guard (c (#t 'raised))
        (bitwise-xor 1/2 1))
      'raised)
(want 'apply-and
      (guard (c (#t 'raised))
        (apply bitwise-and '(1099511627775 -1 255)))
      '255)
(want 'map-xor
      (guard (c (#t 'raised))
        (map bitwise-xor '(1 1099511627776) '(3 1)))
      '(2 1099511627777))
(want 'var-ior
      (guard (c (#t 'raised))
        (let ((f bitwise-ior)) (f 1099511627776 1 2)))
      '1099511627779)
(want 'bytes-to-u64
      (guard (c (#t 'raised))
        (let ((v (vector 1 2 3 4 5 6 7 8))) (let loop ((i 0) (acc 0)) (if (= i 8) acc (loop (+ i 1) (bitwise-ior acc (bitwise-arithmetic-shift-left (vector-ref v i) (* 8 i))))))))
      '578437695752307201)
(want 'mask-of-a-big-in-a-let
      (guard (c (#t 'raised))
        (let ((x 1099511627999)) (let ((lo (bitwise-and x 255)) (hi (bitwise-arithmetic-shift-right x 32))) (list lo hi))))
      '(223 256))
(want 'hash-past-2-to-29
      (guard (c (#t 'raised))
        (let loop ((i 0) (h 2166136261)) (if (= i 10) h (loop (+ i 1) (bitwise-and (bitwise-xor (* h 16777619) i) 4294967295)))))
      '3161358700)
(want 'typed-shift-that-fits
      (guard (c (#t 'raised))
        (let ((b 200)) (bitwise-ior (bitwise-arithmetic-shift-left (bitwise-and b 255) 21) (bitwise-and b 15))))
      '419430408)
(want 'shift-past-the-typed-bound
      (guard (c (#t 'raised))
        (let ((b 200)) (bitwise-ior (bitwise-arithmetic-shift-left (bitwise-and b 255) 22) 1)))
      '838860801)
(want 'loop-variable-that-grows
      (guard (c (#t 'raised))
        (let loop ((i 0) (x 1)) (if (= i 40) x (loop (+ i 1) (bitwise-arithmetic-shift-left x 1)))))
      '1099511627776)
(want 'byte-load-shifted-past
      (guard (c (#t 'raised))
        (let ((bv (u8-list->bytevector (list 255 1)))) (bitwise-ior (bitwise-arithmetic-shift-left (bytevector-u8-ref bv 0) 24) (bitwise-arithmetic-shift-left (bytevector-u8-ref bv 1) 32))))
      '8573157376)
(want 'raises-and-char
      (guard (c (#t 'raised))
        (bitwise-and c one))
      'raised)
(want 'raises-ior-char
      (guard (c (#t 'raised))
        (bitwise-ior c 0))
      'raised)
(want 'raises-xor-char
      (guard (c (#t 'raised))
        (bitwise-xor c one))
      'raised)
(want 'raises-shl-char
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-left c 1))
      'raised)
(want 'raises-shr-char
      (guard (c (#t 'raised))
        (bitwise-arithmetic-shift-right c 1))
      'raised)
(want 'raises-and-char-under-a-mask
      (guard (c (#t 'raised))
        (bitwise-and c 255))
      'raised)
(want 'raises-ior-char-from-a-vector
      (guard (c (#t 'raised))
        (let ((v (vector c))) (bitwise-ior (vector-ref v 0) one)))
      'raised)
(want 'raises-and-char-three
      (guard (c (#t 'raised))
        (bitwise-and one c one))
      'raised)

(display (if (null? fails) #t (reverse fails)))
