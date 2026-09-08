;; expect: #t
;; Drive exact and fractional frame times through the public fixed-step loop.
(import (rnrs) (web js) (gfx fx))
(js-eval "globalThis.requestAnimationFrame = cb => { globalThis.__tick = cb; };
globalThis.__canvas = { width:64, height:64, getContext() { return { viewport(){} } } }")
(fx-init! (js-get (js-global) "__canvas"))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display name) (newline)))
(define (pump! ms)
  (js-call (js-get (js-global) "__tick") (js-undefined) ms))
(define sims 0)
(define alpha -1.0)
(define frames 0)
(fx-loop-fixed! 0.125
  (lambda (step)
    (check "simulation receives the configured step" (fl=? step 0.125))
    (set! sims (+ sims 1)))
  (lambda (a t dt) (set! alpha a) (set! frames (+ frames 1))))
(pump! 0)
(check "first frame has no accumulated time" (and (= sims 0) (fl=? alpha 0.0)))
(pump! 125)
(check "exactly one step runs immediately" (and (= sims 1) (fl=? alpha 0.0)))
(pump! 125)
(check "zero delta adds no step" (and (= sims 1) (fl=? alpha 0.0)))
(pump! 187.5)
(check "fractional step remains for interpolation" (and (= sims 1) (fl=? alpha 0.5)))
(pump! 250)
(check "two halves complete one step" (and (= sims 2) (fl=? alpha 0.0)))
(pump! 2250)
(check "stall consumes the full four-step cap" (and (= sims 6) (fl=? alpha 0.0)))
(check "render runs once per frame" (= frames 6))
(pump! 2374.999)
(check "a frame below the boundary must not simulate early"
       (and (= sims 6) (fl<? alpha 1.0) (fl<? 0.0 alpha)))

;; Repeated subtraction of decimal steps can stop at 0.009999999999999997.
(set! sims 0)
(fx-loop-fixed! 0.01
  (lambda (step) (set! sims (+ sims 1)))
  (lambda (a t dt) (set! alpha a)))
(pump! 0)
(pump! 10000)
(check "decimal step consumes all four capped ticks" (and (= sims 4) (fl=? alpha 0.0)))

(set! sims 0)
(fx-loop-fixed! 1
  (lambda (step)
    (check "integer steps are converted to seconds" (fl=? step 1.0))
    (set! sims (+ sims 1)))
  (lambda (a t dt) (set! alpha a)))
(pump! 0)
(pump! 1000)
(check "integer step boundary is inclusive" (and (= sims 1) (fl=? alpha 0.0)))
;; ---- a remainder carried between frames drifts, and the drift is silent ----
;; Two frames of 250 ms at a 100 ms step is five steps and nothing left
;; over.  An implementation that keeps the leftover time and adds the
;; next frame to it answers four, because 0.25 - 2*0.1 is
;; 0.04999999999999999 and the error comes back every frame.  Counting
;; whole ticks does not fix this on its own; not keeping a remainder
;; does.  This ran green while fx-loop-fixed! had the defect, because
;; nothing above ever fed it two fractional frames in a row.
(set! sims 0)
(set! alpha -1.0)
(fx-loop-fixed! 0.1
  (lambda (step) (set! sims (+ sims 1)))
  (lambda (a t dt) (set! alpha a)))
(pump! 0)
(pump! 250)
(pump! 500)
(check "a remainder is not carried between frames" (and (= sims 5) (fl<? alpha 0.000001)))

(= failed 0)
