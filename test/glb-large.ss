;; expect: #t
;; (gfx glb) -> (gfx gltf) round trip at sizes a real asset reaches.
;; A single primitive of ~8k vertices and ~16k triangles once came
;; back from gltf-parse as an "illegal cast": the writer and the
;; parser disagreed somewhere past the sizes the small tests cover.
;; This test pins the round trip at and around that boundary, plus a
;; u32-indexed primitive past 65536 vertices.
(import (rnrs) (gfx fx) (gfx glb) (gfx gltf))

(define (fill-vertices! base nv)
  ;; position normal uv, stride 32, values that survive f32 exactly
  (let loop ((i 0))
    (when (< i nv)
      (let ((o (+ base (* 32 i))))
        (%mem-f32-set! o (fixnum->flonum (remainder i 17)))
        (%mem-f32-set! (+ o 4) 1.0)
        (%mem-f32-set! (+ o 8) 2.0)
        (%mem-f32-set! (+ o 12) 0.0)
        (%mem-f32-set! (+ o 16) 1.0)
        (%mem-f32-set! (+ o 20) 0.0)
        (%mem-f32-set! (+ o 24) 0.5)
        (%mem-f32-set! (+ o 28) 0.5))
      (loop (+ i 1)))))

(define (fill-indices-u16! base n nv)
  (let loop ((i 0))
    (when (< i n)
      (let ((v (remainder i nv)))
        (%mem-u8-set! (+ base (* 2 i)) (bitwise-and v 255))
        (%mem-u8-set! (+ base (* 2 i) 1)
                      (bitwise-and (bitwise-arithmetic-shift-right v 8)
                                   255)))
      (loop (+ i 1)))))

(define (fill-indices-u32! base n nv)
  (let loop ((i 0))
    (when (< i n)
      (let ((v (remainder i nv))
            (o (+ base (* 4 i))))
        (%mem-u8-set! o (bitwise-and v 255))
        (%mem-u8-set! (+ o 1)
                      (bitwise-and (bitwise-arithmetic-shift-right v 8) 255))
        (%mem-u8-set! (+ o 2)
                      (bitwise-and (bitwise-arithmetic-shift-right v 16) 255))
        (%mem-u8-set! (+ o 3) 0))
      (loop (+ i 1)))))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))

(define (round-trip name nv ntri u32?)
  (let* ((vb (fx-alloc! (* 32 nv)))
         (icount (* 3 ntri))
         (ib (fx-alloc! (* (if u32? 4 2) icount))))
    (fill-vertices! vb nv)
    (if u32?
        (fill-indices-u32! ib icount nv)
        (fill-indices-u16! ib icount nv))
    (let* ((loc (glb-write! (list (list '(position normal uv)
                                        vb nv ib icount
                                        'index-u32? u32?))))
           (g (gltf-parse (car loc) (cdr loc)))
           (p (car (gltf-prims g))))
      (check (string-append name " one primitive")
             (= 1 (length (gltf-prims g))))
      (check (string-append name " vcount")
             (= nv (gprim-vcount p)))
      (check (string-append name " icount")
             (= icount (gprim-icount p)))
      (check (string-append name " index width")
             (eq? u32? (gprim-index-u32? p)))
      ;; the values themselves survive: read the parsed stream back
      ;; bytewise and compare against what the writer was given --
      ;; a byte-order slip in the u16 repack would keep every count
      ;; right while corrupting every triangle
      (let* ((pib (gprim-ibase p))
             ;; ALL FOUR bytes of a u32 index.  Byte 3 was left out, so
             ;; the top eight bits of every index went unread -- and
             ;; since it is always zero here that omission could not
             ;; show.  It is always zero for a reason worth writing
             ;; down: a non-zero byte 3 means an index naming vertex
             ;; 2^24 or beyond, and 2^24 vertices at 32 bytes each is
             ;; half a gigabyte of staging before any index buffer
             ;; exists.  So byte 3 is asserted to BE zero rather than
             ;; exercised as data; what it guards against is a writer
             ;; putting something else there.
             (rd (if u32?
                     (lambda (k)
                       (+ (%mem-u8-ref (+ pib (* 4 k)))
                          (* 256 (%mem-u8-ref (+ pib (* 4 k) 1)))
                          (* 65536 (%mem-u8-ref (+ pib (* 4 k) 2)))
                          (* 16777216 (%mem-u8-ref (+ pib (* 4 k) 3)))))
                     (lambda (k)
                       (+ (%mem-u8-ref (+ pib (* 2 k)))
                          (* 256 (%mem-u8-ref (+ pib (* 2 k) 1)))))))
             (width (if u32? 4 2))
             ;; the probe set: the ends, and -- where the index values
             ;; reach that far -- each side of the boundary a u16 index
             ;; cannot cross.  Named one by one rather than as a range,
             ;; because 65535 and 65536 are the two that matter and a
             ;; sampled range can miss both.
             (ks (append (list 0 1 2 (- icount 3) (- icount 2) (- icount 1))
                         (if (> icount 65537)
                             (list 65534 65535 65536 65537)
                             '()))))
        (check (string-append name " index values")
               (let probe ((ks ks) (ok #t))
                 (if (null? ks) ok
                     (probe (cdr ks)
                            (and ok
                                 (= (rd (car ks))
                                    (remainder (car ks) nv)))))))
        ;; ...and the same probes compared BYTE FOR BYTE against what
        ;; the writer was handed.  Assembling both sides with the same
        ;; arithmetic would agree about a pair of swapped bytes; this
        ;; does not, because it never assembles anything.
        (check (string-append name " index bytes match the input")
               (let probe ((ks ks) (ok #t))
                 (if (null? ks) ok
                     (probe (cdr ks)
                            (and ok
                                 (let byte ((b 0) (ok #t))
                                   (if (= b width)
                                       ok
                                       (byte (+ b 1)
                                             (and ok
                                                  (= (%mem-u8-ref
                                                      (+ pib (* width (car ks)) b))
                                                     (%mem-u8-ref
                                                      (+ ib (* width (car ks)) b)))))))))))) 
        (when u32?
          (check (string-append name " byte 3 is zero at reachable sizes")
                 (let probe ((ks ks) (ok #t))
                   (if (null? ks) ok
                       (probe (cdr ks)
                              (and ok (= 0 (%mem-u8-ref
                                            (+ pib (* 4 (car ks)) 3)))))))))))))

;; the sizes around the once-failing boundary, and both index widths
(round-trip "small" 1000 1000 #f)
(round-trip "boundary" 8381 16416 #f)
(round-trip "wide" 16589 32832 #f)
;; ntri chosen so icount passes 65536: with icount 49248 every index
;; value stayed under 65535 and the u32 path was exercised without a
;; single index needing more than sixteen bits.  22334 triangles is
;; 67002 indices, so the values themselves cross the boundary.
(round-trip "u32" 70000 22334 #t)

(= fails 0)
