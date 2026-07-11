;; expect: #t
;; The linear staging memory: %mem-* primitives read and write a plain
;; wasm memory (exported as "memory"), and the host sees the same bytes
;; zero-copy through a typed-array view.
(import (web js))

(define (near? v x) (and (< (- x 0.0001) v) (< v (+ x 0.0001))))

;; bytes
(%mem-u8-set! 0 255)
(%mem-u8-set! 1 7)
(define u8-ok
  (and (= (%mem-u8-ref 0) 255)
       (= (%mem-u8-ref 1) 7)))

;; i32 slots (fixnum range)
(%mem-i32-set! 4 123456789)
(%mem-i32-set! 8 -42)
(define i32-ok
  (and (= (%mem-i32-ref 4) 123456789)
       (= (%mem-i32-ref 8) -42)))

;; f64: exact round-trip
(%mem-f64-set! 16 3.141592653589793)
(%mem-f64-set! 24 -0.5)
(define f64-ok
  (and (fl=? (%mem-f64-ref 16) 3.141592653589793)
       (fl=? (%mem-f64-ref 24) -0.5)))

;; f32: representable values round-trip exactly; others approximately
(%mem-f32-set! 32 0.5)
(%mem-f32-set! 36 1.5)
(%mem-f32-set! 40 0.1)
(define f32-ok
  (and (fl=? (%mem-f32-ref 32) 0.5)
       (fl=? (%mem-f32-ref 36) 1.5)
       (near? (%mem-f32-ref 40) 0.1)))

;; size and grow: starts at 1 page (64 KiB), grow returns the old size
(define size-ok-1 (= (%mem-size) 1))
(define grow-ret (%mem-grow 1))
(define size-ok-2 (and (= grow-ret 1) (= (%mem-size) 2)))
;; the grown page is addressable
(%mem-u8-set! 65536 9)
(define grown-ok (= (%mem-u8-ref 65536) 9))

;; zero-copy: write floats in Scheme, read the SAME buffer as a JS
;; Float32Array view -- no copies, no per-element bridge calls
(%mem-f32-set! 100 1.0)
(%mem-f32-set! 104 2.5)
(%mem-f32-set! 108 -3.25)
(define mem (js-get (js-global) "__goeteia_mem"))
(define view (js-new (js-get (js-global) "Float32Array")
                     (js-get mem "buffer") 100 3))
(define (v i) (js->number (js-index view i)))
(define zero-copy-ok
  (and (= (v 0) 1)
       (near? (v 1) 2.5)
       (near? (v 2) -3.25)))

;; and the other direction: JS writes, Scheme reads
(js-eval "new Float64Array(globalThis.__goeteia_mem.buffer, 200, 1)[0] = 6.25")
(define js->scheme-ok (fl=? (%mem-f64-ref 200) 6.25))

(and u8-ok i32-ok f64-ok f32-ok size-ok-1 size-ok-2 grown-ok
     zero-copy-ok js->scheme-ok)
