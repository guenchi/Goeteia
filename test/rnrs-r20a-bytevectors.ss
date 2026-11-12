;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20a):
;; the bytevector copies and lists, and the integer accessors of every width, signed
;; and unsigned, with an endianness and native.
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
        (list (bytevector->u8-list (make-bytevector 4 7)) (bytevector->u8-list (make-bytevector 0 0)) (bytevector->u8-list (u8-list->bytevector '(1 2 255 0))) (bytevector-length (u8-list->bytevector '()))))
      '((7 7 7 7) () (1 2 255 0) 0))
(want 2
      (guard (c (#t 'raised))
        (let* ((a (u8-list->bytevector '(1 2 3))) (b (bytevector-copy a))) (bytevector-u8-set! b 0 9) (list (bytevector->u8-list a) (bytevector->u8-list b) (bytevector-length (bytevector-copy (make-bytevector 0 0))))))
      '((1 2 3) (9 2 3) 0))
(want 3
      (guard (c (#t 'raised))
        (let ((s (u8-list->bytevector '(1 2 3 4 5))) (t (make-bytevector 6 0))) (bytevector-copy! s 1 t 2 3) (bytevector->u8-list t)))
      '(0 0 2 3 4 0))
(want 4
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(1 2 3 4 5)))) (bytevector-copy! b 0 b 1 4) (bytevector->u8-list b)))
      '(1 1 2 3 4))
(want 5
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(1 2 3 4 5)))) (bytevector-copy! b 1 b 0 4) (bytevector->u8-list b)))
      '(2 3 4 5 5))
(want 6
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(1 2 3)))) (bytevector-copy! b 0 b 0 0) (bytevector-copy! b 3 b 3 0) (bytevector->u8-list b)))
      '(1 2 3))
(want 7
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 3 1))) (bytevector-fill! b 200) (bytevector->u8-list b)))
      '(200 200 200))
(want 8
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(255 127 128 0)))) (list (bytevector-s8-ref b 0) (bytevector-s8-ref b 1) (bytevector-s8-ref b 2) (bytevector-s8-ref b 3))))
      '(-1 127 -128 0))
(want 9
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 3 0))) (bytevector-s8-set! b 0 -1) (bytevector-s8-set! b 1 -128) (bytevector-s8-set! b 2 127) (bytevector->u8-list b)))
      '(255 128 127))
(want 10
      (guard (c (#t 'raised))
        (list (endianness big) (endianness little) (symbol? (native-endianness)) (native-endianness)))
      '(big little #t little))
(want 11
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(171 205 255 254)))) (list (bytevector-u16-ref b 0 (endianness big)) (bytevector-u16-ref b 0 (endianness little)) (bytevector-s16-ref b 2 (endianness big)) (bytevector-s16-ref b 2 (endianness little)) (bytevector-u16-ref b 1 (endianness big)) (bytevector-s16-ref b 0 (endianness big)))))
      '(43981 52651 -2 -257 52735 -21555))
(want 12
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 4 0))) (bytevector-u16-set! b 0 43981 (endianness big)) (bytevector-u16-set! b 2 43981 (endianness little)) (bytevector->u8-list b)))
      '(171 205 205 171))
(want 13
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 4 0))) (bytevector-s16-set! b 0 -2 (endianness big)) (bytevector-s16-set! b 2 -32768 (endianness little)) (bytevector->u8-list b)))
      '(255 254 0 128))
(want 14
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(222 173 190 239 255 255 255 254)))) (list (bytevector-u32-ref b 0 (endianness big)) (bytevector-u32-ref b 0 (endianness little)) (bytevector-s32-ref b 4 (endianness big)) (bytevector-s32-ref b 0 (endianness big)) (bytevector-u32-ref b 3 (endianness big)))))
      '(3735928559 4022250974 -2 -559038737 4026531839))
(want 15
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 8 0))) (bytevector-u32-set! b 0 3735928559 (endianness big)) (bytevector-s32-set! b 4 -2 (endianness little)) (bytevector->u8-list b)))
      '(222 173 190 239 254 255 255 255))
(want 16
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(1 35 69 103 137 171 205 239 255 255 255 255 255 255 255 254)))) (list (bytevector-u64-ref b 0 (endianness big)) (bytevector-u64-ref b 0 (endianness little)) (bytevector-s64-ref b 8 (endianness big)) (bytevector-s64-ref b 8 (endianness little)) (bytevector-u64-ref b 8 (endianness big)))))
      '(81985529216486895 17279655951921914625 -2 -72057594037927937 18446744073709551614))
(want 17
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 16 0))) (bytevector-u64-set! b 0 81985529216486895 (endianness big)) (bytevector-s64-set! b 8 -2 (endianness little)) (bytevector->u8-list b)))
      '(1 35 69 103 137 171 205 239 254 255 255 255 255 255 255 255))
(want 18
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 8 0))) (bytevector-s64-set! b 0 -9223372036854775808 (endianness big)) (list (bytevector->u8-list b) (bytevector-s64-ref b 0 (endianness big)) (bytevector-u64-ref b 0 (endianness big)))))
      '((128 0 0 0 0 0 0 0) -9223372036854775808 9223372036854775808))
(want 19
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 16 0))) (bytevector-u16-native-set! b 0 43981) (bytevector-s16-native-set! b 2 -2) (bytevector-u32-native-set! b 4 3735928559) (bytevector-s32-native-set! b 8 -2) (list (bytevector-u16-native-ref b 0) (bytevector-s16-native-ref b 2) (bytevector-u32-native-ref b 4) (bytevector-s32-native-ref b 8) (bytevector-u16-ref b 0 (native-endianness)) (bytevector-u32-ref b 4 (native-endianness)))))
      '(43981 -2 3735928559 -2 43981 3735928559))
(want 20
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 16 0))) (bytevector-u64-native-set! b 0 81985529216486895) (bytevector-s64-native-set! b 8 -2) (list (bytevector-u64-native-ref b 0) (bytevector-s64-native-ref b 8) (bytevector-u64-ref b 0 (native-endianness)))))
      '(81985529216486895 -2 81985529216486895))
(want 21
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(1 2 3 255 255 254)))) (list (bytevector-uint-ref b 0 (endianness big) 3) (bytevector-uint-ref b 0 (endianness little) 3) (bytevector-sint-ref b 3 (endianness big) 3) (bytevector-sint-ref b 3 (endianness little) 3) (bytevector-uint-ref b 0 (endianness big) 6) (bytevector-uint-ref b 2 (endianness big) 1))))
      '(66051 197121 -2 -65537 1108168671230 3))
(want 22
      (guard (c (#t 'raised))
        (let ((b (make-bytevector 6 0))) (bytevector-uint-set! b 0 66051 (endianness big) 3) (bytevector-sint-set! b 3 -2 (endianness little) 3) (bytevector->u8-list b)))
      '(1 2 3 254 255 255))
(want 23
      (guard (c (#t 'raised))
        (let ((b (u8-list->bytevector '(1 2 3 4 255 254)))) (list (bytevector->uint-list b (endianness big) 2) (bytevector->uint-list b (endianness little) 2) (bytevector->sint-list b (endianness big) 2) (bytevector->uint-list b (endianness big) 3))))
      '((258 772 65534) (513 1027 65279) (258 772 -2) (66051 327678)))
(want 24
      (guard (c (#t 'raised))
        (list (bytevector->u8-list (uint-list->bytevector '(1 2 65535) (endianness big) 2)) (bytevector->u8-list (uint-list->bytevector '(1 2) (endianness little) 3)) (bytevector->u8-list (sint-list->bytevector '(-1 -2 1) (endianness big) 2)) (bytevector->u8-list (uint-list->bytevector '() (endianness big) 2))))
      '((0 1 0 2 255 255) (1 0 0 2 0 0) (255 255 255 254 0 1) ()))

(display (if (null? fails) #t (reverse fails)))
