;; expect: #t
;; docs/limits.md says %mem-i32-ref wraps at 2^29 rather than widening
;; or trapping.  A limit stated only in prose is a limit that stops
;; being true without anyone noticing -- and this one would stop being
;; true in the good direction, the day the read learns to widen, which
;; is exactly when the workaround it prescribes should be retired.
;;
;; SO THIS CELL IS NOT A COMPLAINT.  It pins what the read does today so
;; that a change to it is announced here, next to the document that
;; tells callers to work around it.
;;
;; THE BYTE ROW IS THE OTHER HALF.  Without it this cell would pass on
;; an implementation where BOTH the i32 read and the byte reads were
;; broken in the same direction, which is the shape a shared narrowing
;; bug would have.  The byte reassembly is required to be exact over the
;; same values the i32 read gets wrong.
(import (rnrs))
(define base 4096)
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (put! a)
  (%mem-u8-set! base (mod a 256))
  (%mem-u8-set! (+ base 1) (mod (div a 256) 256))
  (%mem-u8-set! (+ base 2) (mod (div a 65536) 256))
  (%mem-u8-set! (+ base 3) (mod (div a 16777216) 256)))
(define (bytes-back)
  (+ (%mem-u8-ref base)
     (* 256 (%mem-u8-ref (+ base 1)))
     (* 65536 (%mem-u8-ref (+ base 2)))
     (* 16777216 (%mem-u8-ref (+ base 3)))))
;; Below the edge the two agree, which is what makes the rows above it
;; mean something: the read is not simply broken everywhere.
(for-each
 (lambda (a)
   (put! a)
   (want (list 'i32-exact-below a) (%mem-i32-ref base) a)
   (want (list 'bytes-exact-below a) (bytes-back) a))
 '(0 1 255 65536 268435456 536870910 536870911))
;; At and above 2^29 the i32 read wraps into the signed 30-bit range,
;; and the byte reassembly stays exact.
(for-each
 (lambda (row)
   (put! (car row))
   (want (list 'i32-wraps (car row)) (%mem-i32-ref base) (cdr row))
   (want (list 'bytes-still-exact (car row)) (bytes-back) (car row)))
 '((536870912 . -536870912)
   (536870913 . -536870911)
   (1073741823 . -1)
   (1073741824 . 0)
   (2147483647 . -1)
   (4294967295 . -1)))
;; And the wrapped value is a fixnum, not a bignum: the read narrows, it
;; does not widen.
(put! 536870912)
(want 'the-wrapped-value-is-a-fixnum (fixnum? (%mem-i32-ref base)) #t)
(want 'the-byte-value-is-not (fixnum? (bytes-back)) #f)
(if (null? fails) #t fails)
