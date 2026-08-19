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
             (rd (if u32?
                     (lambda (k)
                       (+ (%mem-u8-ref (+ pib (* 4 k)))
                          (* 256 (%mem-u8-ref (+ pib (* 4 k) 1)))
                          (* 65536 (%mem-u8-ref (+ pib (* 4 k) 2)))))
                     (lambda (k)
                       (+ (%mem-u8-ref (+ pib (* 2 k)))
                          (* 256 (%mem-u8-ref (+ pib (* 2 k) 1))))))))
        (check (string-append name " index values")
               (let probe ((ks (list 0 1 2
                                     (- icount 3) (- icount 2)
                                     (- icount 1)))
                           (ok #t))
                 (if (null? ks) ok
                     (probe (cdr ks)
                            (and ok
                                 (= (rd (car ks))
                                    (remainder (car ks) nv)))))))))))

;; the sizes around the once-failing boundary, and both index widths
(round-trip "small" 1000 1000 #f)
(round-trip "boundary" 8381 16416 #f)
(round-trip "wide" 16589 32832 #f)
(round-trip "u32" 70000 16416 #t)

(= fails 0)
