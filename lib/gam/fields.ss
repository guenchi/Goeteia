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

;; A region that lasts a while and settles up on a cadence.
;;
;; A field is a shape on the ground plane, a lifetime, and a rate.  It
;; is stepped with elapsed time; every so often it hands the caller an
;; amount -- the time it has accumulated since the last time it did so,
;; multiplied by the rate -- and starts accumulating again.
;;
;; THE LAST PARTIAL PERIOD IS PAID.  A field that expires part way
;; through a period settles what it accumulated rather than dropping it.
;; This is the whole reason the accumulator exists instead of a simple
;; countdown: a region that lasts 1.1 periods should be worth 1.1
;; periods and not 1, and the alternative silently pays out less the
;; shorter the region is, which is hardest to notice exactly where it is
;; worst.  The elapsed time is clamped to the life remaining, so a step
;; longer than the rest of the life pays for the part that was alive and
;; not for the whole step.
;;
;; IT DOES NOT KNOW WHAT AN AMOUNT IS.  The rate is a number the field
;; carries and multiplies by time; what the product means -- and to
;; whom -- is the caller's.  A field that knew would have to know who is
;; standing in it, which is a question about a world this cannot see.
;;
;; IT DOES NOT KEEP A LIST OF WHAT IS INSIDE IT.  field-contains? asks
;; about one point, and the caller loops over whatever it has.  Holding
;; a list here would mean holding references to things that can go away
;; without telling this library, and every such list has to be pruned by
;; someone who knows when its entries died.
;;
;; ON THE CONTAINMENT TEST, which looks like one that exists elsewhere:
;; this is a two-dimensional test on the ground plane -- x and z, with a
;; yaw -- and (gfx collide) has capsule tests in three dimensions.  They
;; are NOT two implementations of one thing, and unifying them would
;; make a library that keeps time depend on the graphics stack to ask a
;; question about two coordinates.  The shape here is an entry
;; condition; the cadence above it is the part worth having.
;;
;; A radius with a zero half-length is a circle, which is why there is
;; no separate circle: the capsule with no length between its ends is
;; already that shape, and a second constructor for it would be a second
;; thing to keep correct.
(library (gam fields)
  (export make-field field? field-kind field-x field-z field-radius
          field-half-length field-yaw field-life field-rate field-period
          field-contains? field-step!)
  (import (rnrs))

  ;; #(gam-field kind x z radius half-length yaw life rate period acc)
  ;;
  ;; `life' is what is LEFT, not what it started with: the duration
  ;; passed to make-field is where it starts and is not kept, because a
  ;; field that reported both would invite a caller to compute progress
  ;; from two numbers this library never promised to keep in step.
  (define ($f? f)
    (and (vector? f) (= (vector-length f) 11)
         (eq? (vector-ref f 0) 'gam-field)))
  (define ($need-f who f)
    (unless ($f? f) (error who "not a field" f)))
  (define ($x f) (vector-ref f 2))
  (define ($z f) (vector-ref f 3))
  (define ($radius f) (vector-ref f 4))
  (define ($half f) (vector-ref f 5))
  (define ($yaw f) (vector-ref f 6))
  (define ($life f) (vector-ref f 7))
  (define ($life! f v) (vector-set! f 7 v))
  (define ($rate f) (vector-ref f 8))
  (define ($period f) (vector-ref f 9))
  (define ($acc f) (vector-ref f 10))
  (define ($acc! f v) (vector-set! f 10 v))

  (define (field? f) ($f? f))

  ;; The default period is a default and nothing more: it is a cadence
  ;; that reads as continuous to a person watching while costing a
  ;; fraction of the work of settling every step, and no caller is
  ;; obliged to it.  A period of zero settles on every step, which is
  ;; the exact answer at the highest cost, and is what a caller that
  ;; wants no cadence at all should pass rather than a very small one.
  (define $default-period 0.25)

  (define (make-field kind x z radius half-length yaw duration rate . rest)
    (let ((period (if (null? rest) $default-period (car rest))))
      (unless (and (real? x) (real? z))
        (error 'make-field "a position is two reals" x z))
      (unless (and (real? radius) (< 0 radius))
        (error 'make-field "a radius is a positive real" radius))
      (unless (and (real? half-length) (not (< half-length 0)))
        (error 'make-field "a half-length is a non-negative real" half-length))
      (unless (real? yaw)
        (error 'make-field "a yaw is a real, in radians" yaw))
      (unless (and (real? duration) (< 0 duration))
        (error 'make-field "a duration is a positive real" duration))
      (unless (real? rate)
        (error 'make-field "a rate is a real, per unit of time" rate))
      (unless (and (real? period) (not (< period 0)))
        (error 'make-field "a settling period is a non-negative real" period))
      ;; kind is not checked: this library never looks at it.  It is
      ;; carried for the caller to key its own table by, on the same
      ;; terms as an ability's identifier.
      (vector 'gam-field kind x z radius half-length yaw duration rate period 0.0)))

  (define (field-kind f) ($need-f 'field-kind f) (vector-ref f 1))
  (define (field-x f) ($need-f 'field-x f) ($x f))
  (define (field-z f) ($need-f 'field-z f) ($z f))
  (define (field-radius f) ($need-f 'field-radius f) ($radius f))
  (define (field-half-length f) ($need-f 'field-half-length f) ($half f))
  (define (field-yaw f) ($need-f 'field-yaw f) ($yaw f))
  (define (field-life f) ($need-f 'field-life f) ($life f))
  (define (field-rate f) ($need-f 'field-rate f) ($rate f))
  (define (field-period f) ($need-f 'field-period f) ($period f))

  ;; The point is turned into the field's own frame, the length of the
  ;; capsule is subtracted from the distance along its axis, and what is
  ;; left is compared against the radius.  Squared throughout: the
  ;; comparison is the same one and there is no square root to pay for.
  ;;
  ;; A point past the end of the axis has its overshoot measured from
  ;; the end cap, which is what makes the ends round rather than square.
  (define (field-contains? f x z)
    ($need-f 'field-contains? f)
    (unless (and (real? x) (real? z))
      (error 'field-contains? "a position is two reals" x z))
    (let* ((dx (- x ($x f)))
           (dz (- z ($z f)))
           (a ($yaw f))
           (along (+ (* dx (cos a)) (* dz (sin a))))
           (across (- (* dz (cos a)) (* dx (sin a))))
           (over (max 0.0 (- (abs along) ($half f))))
           (r ($radius f)))
      (not (< (* r r) (+ (* over over) (* across across))))))

  ;; Answers nothing.  What comes out of a field comes out through the
  ;; procedure the caller passes, which is called with the field and the
  ;; amount owed -- and called only when something is owed, so a caller
  ;; that does work per settlement does not have to test for zero.
  ;;
  ;; A dead field is quiet rather than an error: fields expire while the
  ;; caller is holding a list of them, and requiring the list to be
  ;; pruned before the next step would make the natural loop wrong.
  (define (field-step! f dt settle)
    ($need-f 'field-step! f)
    (unless (and (real? dt) (not (< dt 0)))
      (error 'field-step! "an elapsed time is a non-negative real" dt))
    (unless (procedure? settle)
      (error 'field-step! "settling takes a procedure of a field and an amount" settle))
    (when (< 0 ($life f))
      ;; Clamped to the life remaining: this is the last partial period
      ;; the header is about.
      (let ((lived (min dt ($life f))))
        ($life! f (max 0.0 (- ($life f) dt)))
        ($acc! f (+ ($acc f) lived))
        ;; Expiry settles whatever has accumulated, however little, so
        ;; the tail of the life is never dropped for being short.
        (when (or (not (< ($acc f) ($period f))) (not (< 0 ($life f))))
          (let ((owed (* ($acc f) ($rate f))))
            ($acc! f 0.0)
            (settle f owed)))))))
