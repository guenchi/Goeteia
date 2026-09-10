;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; The fixed-step accumulator, with nothing attached to it.
;;
;; A simulation advances in equal steps whatever the frame took, and the
;; caller decides WHEN: paused, a region still loading, a menu open, a
;; frame the host delivered while the tab was hidden.  This is that rule
;; and only that rule -- no frame callback, no draw commands, no clock.
;; `(gfx fx)' calls it; it calls nothing.
;;
;; TWO THINGS THAT LOOK LIKE DETAILS AND ARE NOT:
;;
;;   - DO NOT SUBTRACT AT ALL.  Keeping a remainder means every frame
;;     re-adds the error of the last subtraction: two frames of 0.25 at
;;     a step of 0.1 come out as four steps instead of five, because
;;     the remainder after the first frame is 0.04999999999999999 and
;;     0.29999999999999993 contains only two whole steps.  What is kept
;;     here instead is the TOTAL time seen and the COUNT of steps run;
;;     how many are due now is `floor(total/step) - taken', computed
;;     fresh each time, so an error never compounds.  (Subtracting one
;;     step at a time in a loop is worse again: it turns 0.04 at a step
;;     of 0.01 into three steps with a nearly full remainder.)
;;   - An EXACT boundary simulates now.  Comparing with a strict `<'
;;     defers it to the next frame, and the interpolation factor
;;     reaches 1.0 in the meantime -- which is a frame drawn past the
;;     last state the caller was given.
;;
;; Both were real defects in the loop this replaces, and a consumer had
;; written the rule a third time with a one-nanosecond tolerance to work
;; around the second one.  A tolerance is the wrong shape, and it is
;; also not needed: keeping the total instead of a remainder makes the
;; boundary land where the arithmetic already says it does.
;;
;; A stall is capped at `max-steps' and the excess is DROPPED, not owed.
;; Owing it means the simulation runs faster than real time trying to
;; catch up, which is how a long stall becomes a second long stall.
(library (sim step)
  (export make-fixed-step fixed-step-advance! fixed-step-alpha
          fixed-step-time fixed-step-reset!)
  (import (rnrs))

  ;; `total' is every second handed in that was not dropped by a cap;
  ;; `taken' is how many steps have run.  Everything else is derived,
  ;; which is what keeps the arithmetic from drifting.
  (define-record-type ($step $make-step fixed-step?)
    (fields (immutable step $step-size)
            (immutable cap $step-cap)
            (mutable total $step-total $step-total!)
            (mutable taken $step-taken $step-taken!)))

  (define ($fail who what irritants)
    (apply error who what irritants))

  (define ($fl x) (if (flonum? x) x (exact->inexact x)))

  ;; finite means: not a NaN, and not an infinity
  (define ($finite? x)
    (and (fl=? x x) (fl<? x 1e300) (fl<? -1e300 x)))

  (define (make-fixed-step step max-steps)
    (unless (and (number? step) ($finite? ($fl step)) (fl<? 0.0 ($fl step)))
      ($fail 'make-fixed-step "the step is a positive finite number of seconds"
             (list step)))
    (unless (and (integer? max-steps) (> max-steps 0))
      ($fail 'make-fixed-step "max-steps is a positive integer" (list max-steps)))
    ($make-step ($fl step) (fl* ($fl step) ($fl max-steps)) 0.0 0))

  (define (fixed-step-advance! c elapsed proc)
    (unless (fixed-step? c)
      ($fail 'fixed-step-advance! "not a fixed step" (list 'accumulator)))
    (unless (procedure? proc)
      ($fail 'fixed-step-advance! "the body is a procedure of one argument"
             (list 'body)))
    (unless (and (number? elapsed) ($finite? ($fl elapsed))
                 (not (fl<? ($fl elapsed) 0.0)))
      ($fail 'fixed-step-advance! "elapsed is a finite number of seconds, at least zero"
             (list elapsed)))
    (let* ((step ($step-size c))
           (taken ($step-taken c))
           (base (fl* step ($fl taken)))
           (total (fl+ ($step-total c) ($fl elapsed)))
           ;; the excess is dropped here, before anything is counted:
           ;; a simulation that owes time runs fast to repay it, and a
           ;; long stall then produces a second one
           (total (if (fl<? ($step-cap c) (fl- total base))
                      (fl+ base ($step-cap c))
                      total))
           ;; how many steps are due IN TOTAL by now, minus the ones
           ;; already run.  Derived from the total every time, so the
           ;; error of one frame is never carried into the next.
           ;;
           ;; NO TOLERANCE IS ADDED HERE, and (gam timeline) adds one to
           ;; the same-looking question -- deliberately, both of them.
           ;; Ten advances of 0.1 sum to a shade under 1.0 in binary
           ;; floating point, so the tenth step is not due yet and runs
           ;; on the next advance instead; the step after that is due on
           ;; time again, because the count comes from the total rather
           ;; than from a remainder.  Rounding a step INTO existence
           ;; here would simulate more time than has passed, and it
           ;; would do it once per second forever.  A timeline is the
           ;; other case: its deadlines are one-shot, so a payload held
           ;; back by a last-bit shortfall is late permanently and never
           ;; gets a next tick to be on time for.  Same arithmetic,
           ;; opposite right answer -- which is why neither file should
           ;; be made to match the other.
           (due (exact (floor (fl/ total step))))
           (n (- due taken)))
      ($step-total! c total)
      ($step-taken! c due)
      (let pump ((left n))
        (when (> left 0)
          (proc step)
          (pump (- left 1))))
      n))

  ;; where the caller is between the last state and the next one
  (define (fixed-step-alpha c)
    (unless (fixed-step? c)
      ($fail 'fixed-step-alpha "not a fixed step" (list 'accumulator)))
    ;; clamped: the division can land a hair outside [0,1), and an
    ;; alpha of 1.0 would draw a frame past the last state the caller
    ;; was given -- the same defect the exact-boundary rule is about
    (let ((a (fl- (fl/ ($step-total c) ($step-size c)) ($fl ($step-taken c)))))
      (cond
       ((fl<? a 0.0) 0.0)
       ((fl<? 0.999999999 a) 0.999999999)
       (else a))))

  ;; Simulated time: the steps taken times the step.  Not the sum of the
  ;; frame times -- those differ by whatever a stall dropped, and this
  ;; is the clock the simulation actually ran on.
  (define (fixed-step-time c)
    (unless (fixed-step? c)
      ($fail 'fixed-step-time "not a fixed step" (list 'accumulator)))
    (fl* ($step-size c) ($fl ($step-taken c))))

  ;; Throw the remainder away: after a pause, the time that passed
  ;; while nothing was simulated is not time the simulation owes.
  (define (fixed-step-reset! c)
    (unless (fixed-step? c)
      ($fail 'fixed-step-reset! "not a fixed step" (list 'accumulator)))
    ($step-total! c (fl* ($step-size c) ($fl ($step-taken c))))))
