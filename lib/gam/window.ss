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

;; An action that is live for only part of its own duration, and that
;; touches each thing at most once while it is.
;;
;; A swung weapon, a closing door, a jet of flame: the action lasts some
;; time, but the part of it that DOES anything is a sub-interval of
;; that.  The window is that pair of facts, kept as fractions of the
;; duration so the shape of the action survives being sped up or slowed
;; down.
;;
;; IT DOES NOT KNOW WHAT IT TOUCHES.  There is no geometry here and no
;; damage.  The caller tests whatever it tests -- (gfx collide) has the
;; shapes -- and comes back to ask whether this thing has been touched
;; already.  Putting a shape in here would fix the action to one kind of
;; volume forever; putting a magnitude in here would fix it to one kind
;; of consequence.
;;
;; THE STEP REPORTS AN INTERVAL, NOT AN INSTANT.  window-span answers
;; the slice of the live window that the last step passed through, and
;; that is the whole reason the previous time is kept.  A caller that
;; sampled only "where the action is now" would, on a long frame, sample
;; a swing that had already crossed the target and never touched it: the
;; action was live between two samples and at neither of them.  With the
;; interval the caller can sample as finely as it needs to, and a step
;; longer than the entire window still reports the entire window instead
;; of skipping it.  This is the failure that makes a game feel like it
;; drops inputs, and it gets worse exactly when frames get longer.
;;
;; MARKING IS ONE CALL THAT ANSWERS WHETHER IT WAS THE FIRST.  The
;; alternative -- ask whether it is marked, then mark it -- is two calls
;; that every caller has to remember to pair, and the version that
;; forgets the test still compiles, still runs, and touches the same
;; thing twice on a frame where the sampling happened to catch it
;; twice.  A ledger whose name promises "each thing once" and whose
;; implementation appends unconditionally is not a ledger; it is a list
;; with a misleading name, and the promise lives in whatever the caller
;; remembered to write.
;;
;; WHAT COUNTS AS THE SAME THING IS THE CALLER'S.  Marks are compared
;; with equal?, so a handle from (sim entity) -- a pair of two numbers
;; -- works, and so does a symbol or a small list.  eq? would silently
;; fail on exactly the entity handles this is most likely to be given,
;; because the handle a caller kept and the handle it was just issued
;; are equal without being the same object.
(library (gam window)
  (export make-window window? window-duration window-time
          window-from window-to
          window-step! window-live? window-done? window-span
          window-mark! window-marked? window-marks window-reset!)
  (import (rnrs))

  ;; #(gam-window duration from to time previous marks)
  ;;
  ;; `from' and `to' are fractions of the duration, `time' and
  ;; `previous' are seconds.
  (define ($w? w)
    (and (vector? w) (= (vector-length w) 7)
         (eq? (vector-ref w 0) 'gam-window)))
  (define ($need-w who w)
    (unless ($w? w) (error who "not a window" w)))
  (define ($dur w) (vector-ref w 1))
  (define ($from w) (vector-ref w 2))
  (define ($to w) (vector-ref w 3))
  (define ($now w) (vector-ref w 4))
  (define ($now! w v) (vector-set! w 4 v))
  (define ($prev w) (vector-ref w 5))
  (define ($prev! w v) (vector-set! w 5 v))
  (define ($marks w) (vector-ref w 6))
  (define ($marks! w v) (vector-set! w 6 v))

  (define (window? w) ($w? w))

  ;; The live interval is given as fractions rather than seconds so that
  ;; the same description can be played at any duration and keep its
  ;; shape.  from may equal to: an action live at a single instant is a
  ;; thing a caller may want to describe, and window-span will report
  ;; the empty interval at the step that crosses it rather than pretend
  ;; it never happened.
  (define (make-window duration from to)
    (unless (and (real? duration) (< 0 duration))
      (error 'make-window "a duration is a positive real number of seconds" duration))
    (unless (and (real? from) (not (< from 0)) (not (< 1 from)))
      (error 'make-window "the window opens at a fraction from 0 to 1" from))
    (unless (and (real? to) (not (< to from)) (not (< 1 to)))
      (error 'make-window "the window closes at a fraction from `from' to 1" from to))
    (vector 'gam-window duration from to 0.0 0.0 '()))

  (define (window-duration w) ($need-w 'window-duration w) ($dur w))
  (define (window-time w) ($need-w 'window-time w) ($now w))
  (define (window-from w) ($need-w 'window-from w) ($from w))
  (define (window-to w) ($need-w 'window-to w) ($to w))
  (define (window-marks w) ($need-w 'window-marks w) ($marks w))

  ;; Time stops at the duration rather than running past it, so a caller
  ;; that keeps stepping a finished action sees a finished action rather
  ;; than a growing number.
  (define (window-step! w dt)
    ($need-w 'window-step! w)
    (unless (and (real? dt) (not (< dt 0)))
      (error 'window-step! "an elapsed time is a non-negative real" dt))
    ($prev! w ($now w))
    ($now! w (let ((next (+ ($now w) dt)))
               (if (< ($dur w) next) ($dur w) next))))

  (define (window-done? w) ($need-w 'window-done? w) (not (< ($now w) ($dur w))))

  ;; Live at the instant the clock stands at now.  A caller acting on
  ;; this alone is the caller the header warns about; it is here because
  ;; "is it live right now" is a fair question for something that is not
  ;; sampling geometry -- a sound, a light, a trail.
  (define (window-live? w)
    ($need-w 'window-live? w)
    (let ((f (/ ($now w) ($dur w))))
      (and (not (< f ($from w))) (not (< ($to w) f)))))

  ;; The slice of the live window the last step passed through, as a
  ;; pair of fractions, or #f when the step did not touch it at all.
  ;; The step's own interval is [previous, now]; this is that
  ;; intersected with [from, to].
  (define (window-span w)
    ($need-w 'window-span w)
    (let* ((d ($dur w))
           (a (/ ($prev w) d))
           (b (/ ($now w) d))
           (lo (if (< a ($from w)) ($from w) a))
           (hi (if (< ($to w) b) ($to w) b)))
      (and (not (< hi lo)) (cons lo hi))))

  ;; Answers #t the first time and #f afterwards, so the caller writes
  ;; `(when (window-mark! w target) ...)' and cannot get the pairing
  ;; wrong.
  (define (window-mark! w thing)
    ($need-w 'window-mark! w)
    (and (not (window-marked? w thing))
         (begin ($marks! w (cons thing ($marks w))) #t)))

  (define (window-marked? w thing)
    ($need-w 'window-marked? w)
    (let loop ((l ($marks w)))
      (and (pair? l) (or (equal? (car l) thing) (loop (cdr l))))))

  ;; Back to the start, ledger and all.  Resetting is how an action is
  ;; used again, and the marks have to go with it: a second swing that
  ;; remembered the first one's targets would pass straight through
  ;; them, which looks exactly like a missed hit.
  (define (window-reset! w)
    ($need-w 'window-reset! w)
    ($now! w 0.0)
    ($prev! w 0.0)
    ($marks! w '())))
