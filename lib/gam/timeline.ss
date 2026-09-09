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

;; Payloads that come due later, on a clock the caller advances.
;;
;; A timeline is a time and a queue of (deadline . payload).  Scheduling
;; puts a payload at now-plus-a-delay; ticking moves the time forward and
;; answers everything that has come due, earliest first.
;;
;; IT DOES NOT READ A CLOCK.  Time advances only in timeline-tick!, by
;; the amount the caller passes.  A library that reached for the host's
;; clock instead would be unable to run at any speed but one: no pausing
;; without the queue draining behind the pause, no slow motion, no
;; replay, and no test that schedules an hour out without waiting an
;; hour.  The caller already has a clock, and whichever one it has --
;; wall time, a fixed step, a recording -- is the one this should be on.
;;
;; IT DOES NOT RUN THE PAYLOADS.  tick! answers them as data and the
;; caller decides what they mean.  The alternative -- store thunks and
;; call them here -- looks like less work at the call site and takes
;; away the two things that make a delayed action safe: the caller can
;; no longer look at what is queued (a thunk says nothing about what it
;; will do), and it can no longer decide that a payload has gone stale.
;; That second one is the common case rather than a corner: whatever
;; scheduled an action a moment ago may be gone by the time it comes
;; due, and only the caller knows how to ask.  A payload is a datum, so
;; a queue can also be written out and read back; a thunk cannot.
;;
;; IT DOES NOT CANCEL ONE PAYLOAD.  timeline-clear! drops all of them.
;; Cancelling a single entry needs a name for that entry, and every way
;; of naming one is a decision belonging to the caller that already has
;; names for its own things: the payload can carry a tag the caller
;; filters on when it comes due, which costs nothing here and does not
;; oblige every other caller to a token type it has no use for.
;;
;; EQUAL DEADLINES KEEP INSERTION ORDER.  Two payloads scheduled for the
;; same moment come back in the order they were scheduled, and not in
;; whichever order a sort happened to leave them.  This is the property
;; worth naming, because it is the one a caller depends on without
;; noticing: a run that is reproducible from the same inputs stops being
;; reproducible the moment a tie is broken arbitrarily.
(library (gam timeline)
  (export make-timeline timeline? timeline-time timeline-empty?
          timeline-schedule! timeline-tick! timeline-clear!)
  (import (rnrs))

  ;; #(gam-timeline now queue)
  ;;
  ;; queue is a list of (deadline . payload), earliest deadline first,
  ;; and among equal deadlines in the order they were scheduled.
  (define ($t? t)
    (and (vector? t) (= (vector-length t) 3)
         (eq? (vector-ref t 0) 'gam-timeline)))
  (define ($need-t who t)
    (unless ($t? t) (error who "not a timeline" t)))
  (define ($now t) (vector-ref t 1))
  (define ($now! t v) (vector-set! t 1 v))
  (define ($queue t) (vector-ref t 2))
  (define ($queue! t v) (vector-set! t 2 v))

  ;; A deadline is due when it is not in the future, and "not in the
  ;; future" has to allow for the arithmetic that produced both sides.
  ;; A payload scheduled 0.1 ahead, on a timeline ticked 0.1 three
  ;; times, has a deadline microscopically past the clock in binary
  ;; floating point, and without this would sit in the queue for a whole
  ;; further tick -- firing late, and firing at a moment that depends on
  ;; how the caller chopped up its elapsed time rather than on when it
  ;; asked for. The slack is absolute rather than relative because the
  ;; quantity it corrects is absolute: it is the residue of adding
  ;; ordinary elapsed times, not a proportion of the deadline.  It is
  ;; therefore meaningful at the scale seconds are counted in, and a
  ;; caller running a clock in nanoseconds-as-units wants its own.
  (define $due-slack 1e-8)

  (define (timeline? t) ($t? t))

  ;; The clock starts inexact because it is going to be added to: a
  ;; timeline that began at exact 0 and was ticked with flonums would
  ;; change the exactness of its own clock on the first tick, and every
  ;; deadline made before that moment would have been computed in a
  ;; different arithmetic from the ones after it.
  (define (make-timeline) (vector 'gam-timeline 0.0 '()))

  (define (timeline-time t) ($need-t 'timeline-time t) ($now t))
  (define (timeline-empty? t) ($need-t 'timeline-empty? t) (null? ($queue t)))
  (define (timeline-clear! t) ($need-t 'timeline-clear! t) ($queue! t '()))

  ;; A zero delay is allowed and means the next tick, not this instant:
  ;; nothing here runs between ticks, so the earliest a payload can come
  ;; back is the next time the caller advances the clock.  A negative
  ;; delay is refused rather than clamped, because it asks for something
  ;; this cannot do -- deliver in the past -- and clamping would answer
  ;; a different question silently.
  (define (timeline-schedule! t delay payload)
    ($need-t 'timeline-schedule! t)
    (unless (and (real? delay) (not (< delay 0)))
      (error 'timeline-schedule! "a delay is a non-negative real" delay))
    (let ((entry (cons (+ ($now t) delay) payload)))
      ;; Walk past everything that is due no later than this one, so an
      ;; equal deadline lands after the entries already holding it.
      (let insert ((rest ($queue t)) (seen '()))
        (if (or (null? rest) (< (car entry) (caar rest)))
            ($queue! t (append (reverse seen) (cons entry rest)))
            (insert (cdr rest) (cons (car rest) seen))))))

  ;; Answers the payloads alone, without their deadlines: the deadline
  ;; of something that has already come due describes the past, and a
  ;; caller that acts on it is reading the schedule for a fact about
  ;; now.  Anything a payload needs to know about its own timing it can
  ;; carry.
  ;;
  ;; The queue is written back before the payloads are answered, so a
  ;; caller that schedules more work while handling them adds to a
  ;; timeline that no longer contains what it is handling.
  (define (timeline-tick! t dt)
    ($need-t 'timeline-tick! t)
    (unless (and (real? dt) (not (< dt 0)))
      (error 'timeline-tick! "an elapsed time is a non-negative real" dt))
    ($now! t (+ ($now t) dt))
    (let ((limit (+ ($now t) $due-slack)))
      (let take ((rest ($queue t)) (due '()))
        (if (or (null? rest) (< limit (caar rest)))
            (begin ($queue! t rest) (reverse due))
            (take (cdr rest) (cons (cdar rest) due)))))))
