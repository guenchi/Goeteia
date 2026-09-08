;; expect: #t
;; (sim step): the fixed-step accumulator, with no renderer attached.
;;
;; A simulation wants to advance in equal steps whatever the frame took,
;; and it wants to decide WHEN: paused, a region not loaded yet, a menu
;; open, a frame the host delivered while the tab was hidden.  The one
;; the framework had is welded to a frame callback and to the drawing
;; commands around it, so a caller that wanted the stepping rule without
;; the loop had to write the rule again -- and a consumer did, complete
;; with a one-nanosecond tolerance to work around a boundary defect that
;; has since been fixed upstream.
;;
;; The rule is: count the whole steps the accumulated time contains,
;; then subtract that many at once.  Subtracting one at a time in a loop
;; leaves a remainder that decimal steps cannot represent, which turns
;; four steps into three; comparing with a strict < defers an exact
;; boundary to the next frame and lets the interpolation factor reach 1.
;; Both are pinned here, because both were real.
(import (rnrs) (sim step))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (near? a b) (< (abs (- a b)) 0.0001))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))

(define ticks 0)
(define (count! dt) (set! ticks (+ ticks 1)))

;; ---- an exact boundary simulates now, not next time ----
(define exact-ok
  (let ((c (make-fixed-step 0.125 4)))
    (set! ticks 0)
    (let ((n (fixed-step-advance! c 0.125 count!)))
      (and (= n 1) (= ticks 1) (near? (fixed-step-alpha c) 0.0)))))

;; ---- a partial step waits, and shows as interpolation ----
(define partial-ok
  (let ((c (make-fixed-step 0.125 4)))
    (set! ticks 0)
    (and (= 0 (fixed-step-advance! c 0.0625 count!))
         (= ticks 0)
         (near? (fixed-step-alpha c) 0.5)
         (= 1 (fixed-step-advance! c 0.0625 count!))
         (near? (fixed-step-alpha c) 0.0))))

;; ---- four decimal steps stay four ----
;; Repeated subtraction leaves 0.00999... here and answers three.
(define decimal-ok
  (let ((c (make-fixed-step 0.01 4)))
    (set! ticks 0)
    (let ((n (fixed-step-advance! c 0.04 count!)))
      (and (= n 4) (= ticks 4) (near? (fixed-step-alpha c) 0.0)))))

;; ---- a stall is capped, and the excess is dropped, not owed ----
(define cap-ok
  (let ((c (make-fixed-step 0.1 4)))
    (set! ticks 0)
    (let ((n (fixed-step-advance! c 10.0 count!)))
      (and (= n 4) (= ticks 4)
           (near? (fixed-step-alpha c) 0.0)
           (= 0 (fixed-step-advance! c 0.0 count!))))))   ; nothing was owed

;; ---- the caller decides when to advance ----
(define manual-ok
  (let ((c (make-fixed-step 0.1 4)))
    (set! ticks 0)
    (fixed-step-advance! c 0.25 count!)                   ; two steps, half left
    (let ((paused ticks) (alpha (fixed-step-alpha c)))
      (fixed-step-reset! c)                               ; a pause throws the remainder away
      (and (= paused 2) (near? alpha 0.5)
           (near? (fixed-step-alpha c) 0.0)
           (= 0 (fixed-step-advance! c 0.05 count!))))))

;; ---- simulated time is the sum of the steps taken, not of the frames ----
(define time-ok
  (let ((c (make-fixed-step 0.1 4)))
    (set! ticks 0)
    (fixed-step-advance! c 0.25 count!)
    (fixed-step-advance! c 0.25 count!)
    (and (= ticks 5) (near? (fixed-step-time c) 0.5))))

;; ---- the step the body receives is the configured one, every time ----
(define step-ok
  (let ((c (make-fixed-step 0.02 8)) (seen '()))
    (fixed-step-advance! c 0.1 (lambda (dt) (set! seen (cons dt seen))))
    (and (= (length seen) 5)
         (let scan ((l seen)) (or (null? l) (and (near? (car l) 0.02) (scan (cdr l))))))))

;; ---- an integer step is seconds ----
(define integer-ok
  (let ((c (make-fixed-step 1 2)))
    (set! ticks 0)
    (and (= 1 (fixed-step-advance! c 1.0 count!)) (= ticks 1))))

;; ---- refusals ----
(define refuse-ok
  (and (refused? 'make-fixed-step (lambda () (make-fixed-step 0.0 4)))
       (refused? 'make-fixed-step (lambda () (make-fixed-step -0.1 4)))
       (refused? 'make-fixed-step (lambda () (make-fixed-step 0.1 0)))
       (refused? 'fixed-step-advance!
                 (lambda () (fixed-step-advance! (make-fixed-step 0.1 4) -0.5 count!)))
       (refused? 'fixed-step-advance!
                 (lambda () (fixed-step-advance! (make-fixed-step 0.1 4) (/ 0.0 0.0) count!)))))

(check "an exact boundary simulates immediately" exact-ok)
(check "a partial step waits and shows as alpha" partial-ok)
(check "four decimal steps stay four" decimal-ok)
(check "a stall is capped and the excess dropped" cap-ok)
(check "the caller decides when to advance" manual-ok)
(check "simulated time counts steps, not frames" time-ok)
(check "the body always receives the configured step" step-ok)
(check "an integer step means seconds" integer-ok)
(check "bad configuration and bad elapsed are refused" refuse-ok)

;; ---- alpha never reaches one ----
;; alpha is "how far past the last simulated state we are", so 1.0 means
;; drawing a frame beyond the newest state the caller was given -- the
;; same thing an exact boundary that defers a step produces.  Rounding
;; can push total/step - taken a hair over, so it is clamped.
(check "alpha stays below one however the time arrives"
       (let ((c (make-fixed-step 0.1 8)) (worst 0.0))
         (let loop ((i 0))
           (when (< i 400)
             (fixed-step-advance! c 0.1 (lambda (dt) #f))
             (let ((a (fixed-step-alpha c)))
               (when (> a worst) (set! worst a)))
             (loop (+ i 1))))
         (and (< worst 1.0) (>= worst 0.0))))

(display (= failed 0))
(newline)
