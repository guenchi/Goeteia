;; expect: #t
;; An arithmetic shift answers the exact result, or refuses when that
;; result is not a fixnum; it never answers a wrapped number.
;;
;; THE DEFECTS, measured 2026-10-22 on the wasm and JS targets alike:
;;   bitwise-arithmetic-shift-left wrapped its result to the fixnum
;;   width instead of refusing it: (shl 1 29) answered -536870912,
;;   (shl 3 29) the same, and the shift count was taken modulo 32, so
;;   (shl 1 32) answered 1 and (shl 1 40) answered 256.  A negative
;;   count answered 0.
;;   bitwise-arithmetic-shift-right took its count modulo 32 as well:
;;   (shr 1024 40) answered 4 and (shr -1024 40) answered -4, where the
;;   exact answers are 0 and -1, and (shr 1024 32) answered 1024.
;; docs/limits.md said a bitwise operand of 2^29 or more traps; a small
;; operand whose shifted RESULT does not fit was never covered by that,
;; and wrapped silently.
;;
;; THE RULE.  The bitwise operations here work on fixnums, which run
;; from -2^29 to 2^29 - 1 (the i31 representation; (fixnum? 2^29) is
;; #f, measured).  A left shift whose exact result is outside that range
;; is refused, catchably, naming bitwise-arithmetic-shift-left; it is not
;; promoted to a bignum, because no other bitwise operation here takes a
;; bignum.  A right shift by 31 or more answers 0 or -1 by the sign,
;; which is its exact result.  A negative count is refused by either.
;; Refusal happens when the shift is evaluated, not at compile time: a
;; constant shift that would overflow may sit in a branch never taken.
;;
;; MEASURED BEFORE THE CHANGE: compiled to JS with a check on every left
;; shift, the 368 .ss cells of this tree performed no overflowing shift
;; (91 cells compile one in; the decoders run tens of thousands of them,
;; the widest result 21 bits, and the GLB cells' string hashes 29 bits).
;; So refusing changes no existing cell's result.
;;
;; ROUTES, each with rows: operands from a mutable cell (no constant
;; folding); literal operands, including one in a branch never taken;
;; the shift as a procedure value, called directly, through apply and
;; through a computed operator; and the shift consumed as a raw 32-bit
;; value by the wasm back end's other consumers -- bitwise and/ior/xor,
;; a comparison, a let-bound integer, a quotient, a conditional arm --
;; where the fixnum bound must be the same as in the boxed path.
;;
;; WHAT THE CENSUS CANNOT SEE, and why one row is here: it covered the
;; test fixtures.  A crafted or malformed asset can drive a decoder's
;; shift past the fixnum range -- meshopt's varint reader allows a
;; shift of 28, so a fifth byte of 2 gives 2 << 28 -- and there the old
;; behaviour decoded a wrapped value silently.  Under the rule it
;; refuses.  That is a change, and a wanted one: a malformed asset is an
;; error, not a different mesh.  The KTX VLC accumulator and zstd's
;; ($shl 1 ofc) have the same shape and are not exercised here.
;;
;; DELIBERATELY ABSENT: operands or counts that are not fixnums (a
;; flonum count, a bignum operand).  Their error contract is not part
;; of this change.
(import (rnrs) (gfx meshopt))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define cell (make-vector 1 #f))
(define (id x) (vector-set! cell 0 x) (vector-ref cell 0))
(define (try thunk)
  (guard (e (#t (list 'refused (condition-who e))))
    (thunk)))
(define shl bitwise-arithmetic-shift-left)
(define shr bitwise-arithmetic-shift-right)

;; ---- left shift, operands from a cell ----
(want "CONTROL 1 << 5" (try (lambda () (shl (id 1) (id 5)))) 32)
(want "CONTROL 1 << 28, the largest power of two that fits" (try (lambda () (shl (id 1) (id 28)))) 268435456)
(want "CONTROL -1 << 29, the least fixnum" (try (lambda () (shl (id -1) (id 29)))) -536870912)
(want "CONTROL 3 << 26" (try (lambda () (shl (id 3) (id 26)))) 201326592)
(want "CONTROL 0 << 100 is 0" (try (lambda () (shl (id 0) (id 100)))) 0)
(want "1 << 29 does not fit and is refused" (try (lambda () (shl (id 1) (id 29)))) '(refused bitwise-arithmetic-shift-left))
(want "3 << 29 is refused" (try (lambda () (shl (id 3) (id 29)))) '(refused bitwise-arithmetic-shift-left))
(want "-3 << 28 is below the least fixnum and refused" (try (lambda () (shl (id -3) (id 28)))) '(refused bitwise-arithmetic-shift-left))
(want "1 << 32 is refused, not taken modulo 32" (try (lambda () (shl (id 1) (id 32)))) '(refused bitwise-arithmetic-shift-left))
(want "1 << 40 is refused" (try (lambda () (shl (id 1) (id 40)))) '(refused bitwise-arithmetic-shift-left))
(want "a negative left count is refused" (try (lambda () (shl (id 1) (id -1)))) '(refused bitwise-arithmetic-shift-left))

;; ---- left shift, literal operands ----
(want "CONTROL literal 1 << 5" (try (lambda () (shl 1 5))) 32)
(want "literal 1 << 32 is refused when evaluated" (try (lambda () (bitwise-arithmetic-shift-left 1 32))) '(refused bitwise-arithmetic-shift-left))
(want "literal 1 << 29 is refused when evaluated" (try (lambda () (bitwise-arithmetic-shift-left 1 29))) '(refused bitwise-arithmetic-shift-left))

;; ---- zero counts, and a zero operand with a negative count ----
(want "CONTROL 5 << 0" (try (lambda () (shl (id 5) (id 0)))) 5)
(want "CONTROL 5 >> 0" (try (lambda () (shr (id 5) (id 0)))) 5)
(want "0 << -1 is refused: a zero operand does not excuse the count" (try (lambda () (shl (id 0) (id -1)))) '(refused bitwise-arithmetic-shift-left))
(want "0 >> -1 is refused" (try (lambda () (shr (id 0) (id -1)))) '(refused bitwise-arithmetic-shift-right))

;; ---- literal overflow in a branch never taken ----
(want "CONTROL a literal overflowing shift in an untaken branch compiles and is not evaluated"
      (try (lambda () (if (id #f) (bitwise-arithmetic-shift-left 1 40) 'fine))) 'fine)

;; ---- the shift as a procedure value ----
(want "through apply, 1 << 29 is refused" (try (lambda () (apply bitwise-arithmetic-shift-left (list (id 1) (id 29))))) '(refused bitwise-arithmetic-shift-left))
(want "CONTROL through apply, 1 << 5" (try (lambda () (apply bitwise-arithmetic-shift-left (list (id 1) (id 5))))) 32)
(want "through a computed operator, 1 << 29 is refused"
      (try (lambda () ((if (id #t) bitwise-arithmetic-shift-left bitwise-arithmetic-shift-right) (id 1) (id 29)))) '(refused bitwise-arithmetic-shift-left))
(want "CONTROL each operand is evaluated once"
      (let ((n 0)) (define (op x) (set! n (+ n 1)) x) (shl (op 1) (op 5)) n) 2)

;; ---- left shift inside a chain of bitwise operations ----
(want "CONTROL a fitting shift inside a chain" (try (lambda () (bitwise-and (bitwise-arithmetic-shift-left (id 3) (id 4)) (id 255)))) 48)
(want "an overflowing shift inside a chain is refused, not masked"
      (try (lambda () (bitwise-and (bitwise-arithmetic-shift-left (id 1) (id 32)) (id 255)))) '(refused bitwise-arithmetic-shift-left))
(want "an overflowing shift under ior is refused"
      (try (lambda () (bitwise-ior (bitwise-arithmetic-shift-left (id 5) (id 28)) (id 1)))) '(refused bitwise-arithmetic-shift-left))

(want "1 << 29 under and is refused: the raw path keeps the fixnum bound"
      (try (lambda () (bitwise-and (bitwise-arithmetic-shift-left (id 1) (id 29)) (id 255)))) '(refused bitwise-arithmetic-shift-left))
(want "-3 << 28 under and is refused"
      (try (lambda () (bitwise-and (bitwise-arithmetic-shift-left (id -3) (id 28)) (id 255)))) '(refused bitwise-arithmetic-shift-left))
(want "an overflowing shift under xor is refused"
      (try (lambda () (bitwise-xor (bitwise-arithmetic-shift-left (id 1) (id 29)) (id 1)))) '(refused bitwise-arithmetic-shift-left))
(want "a negative count under and is refused"
      (try (lambda () (bitwise-and (bitwise-arithmetic-shift-left (id 1) (id -1)) (id 255)))) '(refused bitwise-arithmetic-shift-left))
(want "a negative right count under and is refused"
      (try (lambda () (bitwise-and (bitwise-arithmetic-shift-right (id 1024) (id -1)) (id 255)))) '(refused bitwise-arithmetic-shift-right))
(want "an overflowing shift compared is refused"
      (try (lambda () (< (bitwise-arithmetic-shift-left (id 1) (id 29)) (id 5)))) '(refused bitwise-arithmetic-shift-left))
(want "an overflowing shift bound by let is refused"
      (try (lambda () (let ((v (bitwise-arithmetic-shift-left (id 1) (id 29)))) (+ v 1)))) '(refused bitwise-arithmetic-shift-left))
(want "an overflowing shift as a quotient operand is refused"
      (try (lambda () (quotient (bitwise-arithmetic-shift-left (id 1) (id 29)) (id 2)))) '(refused bitwise-arithmetic-shift-left))
(want "an overflowing shift in a conditional arm under and is refused"
      (try (lambda () (bitwise-and (if (id #t) (bitwise-arithmetic-shift-left (id 1) (id 29)) (id 0)) (id 255)))) '(refused bitwise-arithmetic-shift-left))

;; ---- right shift ----
(want "CONTROL 1024 >> 3" (try (lambda () (shr (id 1024) (id 3)))) 128)
(want "CONTROL -1024 >> 3" (try (lambda () (shr (id -1024) (id 3)))) -128)
(want "1024 >> 31 is 0" (try (lambda () (shr (id 1024) (id 31)))) 0)
(want "1024 >> 32 is 0, not taken modulo 32" (try (lambda () (shr (id 1024) (id 32)))) 0)
(want "1024 >> 40 is 0" (try (lambda () (shr (id 1024) (id 40)))) 0)
(want "-1024 >> 40 is -1" (try (lambda () (shr (id -1024) (id 40)))) -1)
(want "-1 >> 100 is -1" (try (lambda () (shr (id -1) (id 100)))) -1)
(want "literal 1024 >> 40 is 0" (try (lambda () (bitwise-arithmetic-shift-right 1024 40))) 0)
(want "a large right shift inside a chain is exact"
      (try (lambda () (bitwise-and (bitwise-arithmetic-shift-right (id -1024) (id 40)) (id 255)))) 255)
(want "a negative right count is refused" (try (lambda () (shr (id 1024) (id -1)))) '(refused bitwise-arithmetic-shift-right))

;; ---- a decoder given a crafted varint ----
;; meshopt's index-sequence reader: header byte, then 80 80 80 80 02 --
;; four continuation bytes and a fifth payload of 2 at shift 28.
(let ((src 8192) (dst 16384))
  (let put ((bs '(#xd1 #x80 #x80 #x80 #x80 #x02)) (i 0))
    (when (pair? bs) (%mem-u8-set! (+ src i) (car bs)) (put (cdr bs) (+ i 1))))
  (want "a crafted meshopt varint that shifts past a fixnum is refused, not decoded wrapped"
        (guard (e (#t 'refused)) (meshopt-index-sequence! src 6 dst 1 4) 'decoded)
        'refused))

;; ---- CONTROL: prelude code that shifts is unchanged ----
;; The run-time reader turns a \x...; escape into UTF-8 bytes with right
;; shifts of 6, 12 and 18 (%push-utf8).  Strings here are bytes
;; (docs/limits.md), so the escape is read from a port rather than
;; built with integer->char, which stores one byte.
(want "CONTROL the reader's UTF-8 for e-acute, euro and a four-byte character"
      (let ((bv (string->utf8 (read (open-input-string "\"\\xE9;\\x20AC;\\x1F600;\"")))))
        (let loop ((i (- (bytevector-length bv) 1)) (out '()))
          (if (< i 0) out (loop (- i 1) (cons (bytevector-u8-ref bv i) out)))))
      '(195 169 226 130 172 240 159 152 128))
(want "CONTROL string-hash of abc, as before the change" (string-hash "abc") 304891)
(want "CONTROL string-hash of a longer string, as before" (string-hash "the quick brown fox") 184620477)

(display (if (null? fails) #t (reverse fails)))
