;; expect: #t
;; the IEEE 754 accessors of (rnrs bytevectors): single and double
;; precision, big and little endian and native, read and written as the
;; bytes Chez writes, with the index checked and the native ones aligned
;; (ledger R20).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; Each `site' row answers (kind error? violation? i/o-read? message?
;; irritants?) for what the expression raises.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define (caught thunk)
  (guard (c (#t (if (assertion-violation? c) 'assertion 'other))) (thunk)))
;; the bytes a double or a single is written as
(define (d-bytes x e)
  (let ((bv (make-bytevector 8 0))) (bytevector-ieee-double-set! bv 0 x e) (bytevector->u8-list bv)))
(define (s-bytes x e)
  (let ((bv (make-bytevector 4 0))) (bytevector-ieee-single-set! bv 0 x e) (bytevector->u8-list bv)))
(define (d-read bytes e) (bytevector-ieee-double-ref (u8-list->bytevector bytes) 0 e))
(define (s-read bytes e) (bytevector-ieee-single-ref (u8-list->bytevector bytes) 0 e))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'double-big
      (guard (c (#t 'raised))
        (map (lambda (x) (d-bytes x 'big)) '(1.5 -0.0 0.0 +inf.0 -inf.0 1e300 5e-324 0.1)))
      '((63 248 0 0 0 0 0 0) (128 0 0 0 0 0 0 0) (0 0 0 0 0 0 0 0) (127 240 0 0 0 0 0 0) (255 240 0 0 0 0 0 0) (126 55 228 60 136 0 117 156) (0 0 0 0 0 0 0 1) (63 185 153 153 153 153 153 154)))
(want 'double-little
      (guard (c (#t 'raised))
        (map (lambda (x) (d-bytes x 'little)) '(1.5 -2.25 1e-300)))
      '((0 0 0 0 0 0 248 63) (0 0 0 0 0 0 2 192) (89 243 248 194 31 110 165 1)))
(want 'double-round-trip
      (guard (c (#t 'raised))
        (map (lambda (x) (list (d-read (d-bytes x 'big) 'big) (d-read (d-bytes x 'little) 'little))) '(1.5 -0.0 1e300 0.1 -123456.789)))
      '((1.5 1.5) (-0.0 -0.0) (1e300 1e300) (0.1 0.1) (-123456.789 -123456.789)))
(want 'double-denormal-round-trip
      (guard (c (#t 'raised))
        (list (= (d-read (d-bytes 5e-324 'big) 'big) 5e-324) (= (d-read (d-bytes 5e-324 'little) 'little) 5e-324) (> (d-read (d-bytes 5e-324 'big) 'big) 0.0)))
      '(#t #t #t))
(want 'double-read-nan
      (guard (c (#t 'raised))
        (let ((x (d-read '(127 248 0 0 0 0 0 0) 'big))) (list (nan? x) (flonum? x))))
      '(#t #t))
(want 'single-big
      (guard (c (#t 'raised))
        (map (lambda (x) (s-bytes x 'big)) '(1.5 -0.0 +inf.0 0.1 3.4028234663852886e38 1e40 1e-45)))
      '((63 192 0 0) (128 0 0 0) (127 128 0 0) (61 204 204 205) (127 127 255 255) (127 128 0 0) (0 0 0 1)))
(want 'single-little
      (guard (c (#t 'raised))
        (map (lambda (x) (s-bytes x 'little)) '(1.5 -2.25)))
      '((0 0 192 63) (0 0 16 192)))
(want 'single-round-trip
      (guard (c (#t 'raised))
        (map (lambda (x) (s-read (s-bytes x 'big) 'big)) '(1.5 0.1 -0.0 1e40 1e-45 16777217.0)))
      '(1.5 0.10000000149011612 -0.0 +inf.0 1.401298464324817e-45 16777216.0))
(want 'native-is-little
      (guard (c (#t 'raised))
        (list (eq? (native-endianness) 'little) (let ((bv (make-bytevector 8 0))) (bytevector-ieee-double-native-set! bv 0 1.5) (bytevector->u8-list bv)) (let ((bv (make-bytevector 4 0))) (bytevector-ieee-single-native-set! bv 0 1.5) (bytevector->u8-list bv))))
      '(#t (0 0 0 0 0 0 248 63) (0 0 192 63)))
(want 'native-reads
      (guard (c (#t 'raised))
        (let ((bv (u8-list->bytevector '(0 0 0 0 0 0 248 63 0 0 192 63)))) (list (bytevector-ieee-double-native-ref bv 0) (bytevector-ieee-single-native-ref bv 8))))
      '(1.5 1.5))
(want 'at-an-offset
      (guard (c (#t 'raised))
        (let ((bv (make-bytevector 12 0))) (bytevector-ieee-double-set! bv 3 2.5 'big) (bytevector-ieee-single-set! bv 1 -1.0 'little) (list (bytevector->u8-list bv) (bytevector-ieee-double-ref bv 3 'big))))
      '((0 0 0 128 191 0 0 0 0 0 0 0) -4.4145465352782875e-305))
(want 'native-unaligned
      (guard (c (#t 'raised))
        (list (caught (lambda () (bytevector-ieee-double-native-ref (make-bytevector 16 0) 4))) (caught (lambda () (bytevector-ieee-single-native-set! (make-bytevector 8 0) 2 1.0)))))
      '(assertion assertion))
(want 'index-out-of-range
      (guard (c (#t 'raised))
        (list (caught (lambda () (bytevector-ieee-double-ref (make-bytevector 8 0) 1 'big))) (caught (lambda () (bytevector-ieee-single-set! (make-bytevector 4 0) 1 1.0 'little))) (caught (lambda () (bytevector-ieee-double-ref (make-bytevector 8 0) -1 'big)))))
      '(assertion assertion assertion))
(want 'unknown-endianness
      (guard (c (#t 'raised))
        (caught (lambda () (bytevector-ieee-double-ref (make-bytevector 8 0) 0 'middle))))
      'assertion)
(want 'exact-reals-are-converted
      (guard (c (#t 'raised))
        (list (d-bytes 1 'big) (d-bytes 1/2 'little) (s-bytes 3 'big)))
      '((63 240 0 0 0 0 0 0) (0 0 0 0 0 0 224 63) (64 64 0 0)))
(want 'not-a-real
      (guard (c (#t 'raised))
        (list (caught (lambda () (d-bytes 'x 'big))) (caught (lambda () (s-bytes "1.0" 'little)))))
      '(assertion assertion))

(display (if (null? fails) #t (reverse fails)))
