;; expect: #t
;; The bytes (web sexpr) puts on the wire for a flonum, and the flonum it
;; reads back from them (ledger R87, batch M49).
;;
;; A flonum crosses as #f8"<base64>": the base64 of its eight
;; little-endian IEEE-754 bytes, which igropyr writes and reads with
;; Chez's bytevector-ieee-double-* -- so a byte that moves here is a value
;; that moves on the other side.  test/sexpr-limits.ss pins 1.5, 0.1 and
;; the two zeros; this file pins the values a conversion through
;; JavaScript is most likely to bend: integral ones (the bridge hands an
;; integral double back as a fixnum), the infinities, the least subnormal
;; and the least normal, the greatest finite, 2^53, 1e21, and the quiet
;; NaN 0x7FF8000000000000, written back as itself.
;;
;; Each value is made from its bytes, so nothing here depends on the
;; reader's decimal conversion.  Each expected text is the base64 of the
;; eight bytes listed beside it.
;;
;; ON THE TREE BEFORE THE CHANGE this file is green.  It pins the bytes of
;; today, so that moving the conversion out of JavaScript cannot move one
;; of them.
(import (rnrs) (web sexpr))

(define (from-bytes l)
  (bytevector-ieee-double-ref (u8-list->bytevector l) 0 'little))
(define (to-bytes x)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-ieee-double-set! bv 0 x 'little)
    (bytevector->u8-list bv)))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

;; (row bytes text)
(define rows
  '((one (0 0 0 0 0 0 240 63) "#f8\"AAAAAAAA8D8=\"")
    (minus-one (0 0 0 0 0 0 240 191) "#f8\"AAAAAAAA8L8=\"")
    (two (0 0 0 0 0 0 0 64) "#f8\"AAAAAAAAAEA=\"")
    (plus-infinity (0 0 0 0 0 0 240 127) "#f8\"AAAAAAAA8H8=\"")
    (minus-infinity (0 0 0 0 0 0 240 255) "#f8\"AAAAAAAA8P8=\"")
    (least-subnormal (1 0 0 0 0 0 0 0) "#f8\"AQAAAAAAAAA=\"")
    (least-normal (0 0 0 0 0 0 16 0) "#f8\"AAAAAAAAEAA=\"")
    (greatest-finite (255 255 255 255 255 255 239 127) "#f8\"////////738=\"")
    (two-to-the-53 (0 0 0 0 0 0 64 67) "#f8\"AAAAAAAAQEM=\"")
    (ten-to-the-21 (80 239 226 214 228 26 75 68) "#f8\"UO/i1uQaS0Q=\"")
    (minus-zero (0 0 0 0 0 0 0 128) "#f8\"AAAAAAAAAIA=\"")
    (quiet-nan (0 0 0 0 0 0 248 127) "#f8\"AAAAAAAA+H8=\"")))

(for-each
 (lambda (r)
   (let ((name (car r)) (bytes (cadr r)) (text (caddr r)))
     (want (list name 'write) (sexpr->string (from-bytes bytes)) text)
     (let ((v (guard (e (#t 'raised)) (string->sexpr text))))
       (want (list name 'read-is-a-flonum) (and (flonum? v) #t) #t)
       (want (list name 'read-bytes) (if (flonum? v) (to-bytes v) v) bytes))))
 rows)

;; inside a list, the way rpc sends them
(want 'in-a-list
      (sexpr->string (list (from-bytes '(0 0 0 0 0 0 240 63))
                           (from-bytes '(0 0 0 0 0 0 0 128))))
      "(#f8\"AAAAAAAA8D8=\" #f8\"AAAAAAAAAIA=\")")

(if (null? fails)
    (display "#t")
    (write (reverse fails)))
