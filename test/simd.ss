;; expect: #t
;; The wasm SIMD primitives: memory-to-memory f32x4 lanes, with the
;; scalar of scale/axpy arriving through the f64 context.  Written
;; floats come back transformed, four at a time.
(import (rnrs))

(define A 8192) (define B 8224) (define C 8256) (define D 8288)

(define (put4! base a b c d)
  (%mem-f32-set! base a) (%mem-f32-set! (+ base 4) b)
  (%mem-f32-set! (+ base 8) c) (%mem-f32-set! (+ base 12) d))
(define (is4? base a b c d)
  (define (n? at v)
    (let ((g (%mem-f32-ref at)))
      (and (fl<? (fl- g v) 0.0001) (fl<? (fl- v g) 0.0001))))
  (and (n? base a) (n? (+ base 4) b)
       (n? (+ base 8) c) (n? (+ base 12) d)))

(put4! A 1.0 2.0 3.0 4.0)
(put4! B 10.0 20.0 30.0 40.0)

(%f32x4-add! C A B)
(define add-ok (is4? C 11.0 22.0 33.0 44.0))
(%f32x4-sub! C B A)
(define sub-ok (is4? C 9.0 18.0 27.0 36.0))
(%f32x4-mul! C A B)
(define mul-ok (is4? C 10.0 40.0 90.0 160.0))
;; the scalar splats across the lanes...
(%f32x4-scale! C A 2.5)
(define scale-ok (is4? C 2.5 5.0 7.5 10.0))
;; ...and axpy fuses a whole multiply-accumulate column
(%f32x4-axpy! D B A 100.0)
(define axpy-ok (is4? D 110.0 220.0 330.0 440.0))
;; in-place accumulation: dst and a may be the same address
(%f32x4-axpy! D D A 1.0)
(define acc-ok (is4? D 111.0 222.0 333.0 444.0))

(and add-ok sub-ok mul-ok scale-ok axpy-ok acc-ok)
