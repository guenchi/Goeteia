;; Microbenchmarks for the web stack's per-frame hot paths.
;;
;;   ./bin/goeteiac bench/perf.ss /tmp/perf.wasm && node rt/run.mjs /tmp/perf.wasm
;;
;; Each line reports throughput for one operation.  The harness runs a
;; warm-up pass (so the wasm is JIT-tiered) then a timed pass, and
;; sinks every result to a global so the optimiser can't elide the
;; work.  Numbers are single-threaded, wasm-GC, whatever engine
;; rt/run.mjs uses (Node's V8 today).
;;
;; What the numbers say (measured on Node 22):
;;  - The generic +/*/- tower costs ~2x a direct fl+ on flonums (a
;;    type dispatch plus a boxed result).  It is still ~1e8 ops/s --
;;    below the noise of a frame.
;;  - m4-mul over boxed Scheme vectors is within ~10% of the same
;;    multiply over unboxed f64 staging memory: V8's generational GC
;;    makes the per-element box almost free, and the 64 multiply-adds
;;    dominate.  So mat stays in value-semantics vectors -- a linear-
;;    memory rewrite would trade correctness for single-digit percent.
;;  - A bridge property read (js-get) is ~185 ns.  A frame issues a
;;    handful, ~1 us total -- caching canvas width/height would buy
;;    0.007% of a 16.7 ms budget.  Not worth an API.
;;  - typeset prepare/layout of a ~1 KB paragraph is tens of us:
;;    per-message in a feed, never per-frame (see (web scroll)).
;;
;; Where the real ceilings are (and the right fix, none of them here):
;;  - thousands of skinning matrices per frame -> move skinning into
;;    the vertex shader, not a memory-layout change;
;;  - 100k+ sprites -> instanced draws (one new gl opcode);
;;  - megabyte-scale reflow -> incremental, per-paragraph prepare.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(import (rnrs) (web js) (gfx mat) (gfx mesh) (web typeset))

(define (now) (js->number (js-eval "Date.now()")))

;; scratch staging memory for the unboxed / raw-store benchmarks
(%mem-grow 3)

;; a global sink defeats dead-code elimination: storing the result
;; where a later statement could observe it forces the work to run
(define sink #f)

(define (pad-right s n)                  ; left-justify a label
  (if (>= (string-length s) n)
      s
      (pad-right (string-append s " ") n)))

(define (report label iters t0 t1)
  (let ((ms (- t1 t0)))
    (display (pad-right label 22))
    (display ": ")
    (display (quotient (* iters 1000) (if (< ms 1) 1 ms)))
    (display " ops/s  (")
    (display ms)
    (display " ms)")
    (newline)))

;; run thunk once to warm the JIT, then time a second pass; thunk
;; takes the iteration count and returns a checksum we sink
(define (run label iters thunk)
  (set! sink (thunk iters))
  (let ((t0 (now)))
    (set! sink (thunk iters))
    (report label iters t0 (now))))

;; ---- the arithmetic floor: generic tower vs direct flonum ----
(run "generic + on flonums" 1000000
  (lambda (n)
    (let loop ((i 0) (s 0.0))
      (if (= i n) s (loop (+ i 1) (+ s 1.5))))))

(run "direct fl+" 1000000
  (lambda (n)
    (let loop ((i 0) (s 0.0))
      (if (= i n) s (loop (+ i 1) (fl+ s 1.5))))))

;; ---- (gfx mat) ----
(define ma (m4-rotate-y 0.7))
(define mb (m4-translate 1.0 2.0 3.0))

(run "m4-mul (boxed vectors)" 100000
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) (vector-ref (m4-mul ma mb) 0)
          (begin (set! sink (m4-mul ma mb)) (loop (+ i 1)))))))

;; the same multiply over unboxed f64 staging memory, for contrast
(define (m4->mem! at m)
  (let loop ((i 0))
    (when (< i 16)
      (%mem-f64-set! (+ at (* 8 i)) (vector-ref m i))
      (loop (+ i 1)))))
(m4->mem! 1024 ma)
(m4->mem! 1152 mb)
(define (m4-mul-mem! a b c)
  (let col ((cc 0))
    (when (< cc 4)
      (let row ((r 0))
        (when (< r 4)
          (let k ((kk 0) (s 0.0))
            (if (= kk 4)
                (%mem-f64-set! (+ c (* 8 (+ (* cc 4) r))) s)
                (k (+ kk 1)
                   (fl+ s (fl* (%mem-f64-ref (+ a (* 8 (+ (* kk 4) r))))
                               (%mem-f64-ref (+ b (* 8 (+ (* cc 4) kk)))))))))
          (row (+ r 1))))
      (col (+ cc 1)))))

(run "m4-mul (staging f64)" 100000
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) 0.0
          (begin (m4-mul-mem! 1024 1152 1280) (loop (+ i 1)))))))

(run "flsin (polynomial)" 1000000
  (lambda (n)
    (let loop ((i 0) (s 0.0))
      (if (= i n) s (loop (+ i 1) (flsin s))))))

(define vv (v3 3.0 4.0 12.0))
(run "v3-normalize" 500000
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) (v3-x (v3-normalize vv))
          (begin (set! sink (v3-normalize vv)) (loop (+ i 1)))))))

;; ---- (gfx mesh) ----
(run "mesh-sphere (24x16)" 10000
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) sink
          (begin (set! sink (mesh-sphere 2.0)) (loop (+ i 1)))))))

(define sph (mesh-sphere 2.0))
(run "mesh-write! sphere" 10000
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) 0
          (begin (mesh-write! sph 2048 8192) (loop (+ i 1)))))))

;; ---- (web typeset): a ~1 KB mixed-script paragraph ----
(define para
  (let rep ((i 0) (acc ""))
    (if (= i 16)
        acc
        (rep (+ i 1)
             (string-append
              acc "streaming feeds append while you read 多语言消息也断行 ")))))
(define (m8 s) 8.0)                       ; a stand-in measurer
(define prep (prepare para m8))

(run "typeset prepare (~1KB)" 200
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) sink
          (begin (set! sink (prepare para m8)) (loop (+ i 1)))))))

(run "typeset layout (~1KB)" 1000
  (lambda (n)
    (let loop ((i 0))
      (if (= i n) sink
          (begin (set! sink (layout prep 400.0 22)) (loop (+ i 1)))))))

;; ---- the sprite/gl encode floor: 48 f32 stores = one quad ----
(run "quad encode (48 f32)" 100000
  (lambda (n)
    (let loop ((q 0))
      (if (= q n) 0
          (let v ((i 0) (at 2048))
            (if (= i 48)
                (loop (+ q 1))
                (begin (%mem-f32-set! at 1.5) (v (+ i 1) (+ at 4)))))))))

;; ---- the JS bridge: one property read ----
(js-eval "globalThis.__c = { width: 640, height: 480 }")
(define canvas (js-get (js-global) "__c"))
(run "js-get (bridge read)" 200000
  (lambda (n)
    (let loop ((i 0) (s 0))
      (if (= i n) s
          (loop (+ i 1) (+ s (js->number (js-get canvas "width"))))))))

(display "done")
(newline)
