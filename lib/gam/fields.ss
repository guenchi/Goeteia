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
  ;; A real that is still finite once made inexact, which is what it
  ;; becomes when +, -, * or / combines it with a flonum, or when sin or
  ;; cos takes it; +, -, * and / on exact operands alone stay exact.  An
  ;; exact number of any size is finite as an exact number, yet 2^1024
  ;; becomes +inf.0 and 2^-1100 becomes 0.0 when that happens.  (- y y)
  ;; is 0 for every finite flonum y and NaN for either infinity and for
  ;; NaN; 1.7e308 passes, which a bound such as (< y 1e300) would
  ;; wrongly refuse.  A positive bound is tested on (inexact v) for the
  ;; same reason, since 2^-1100 is positive and becomes 0.0.  A
  ;; non-negative bound is tested on v itself, the stricter of the two
  ;; there, since -2^-1100 becomes -0.0 and (<= 0 -0.0) holds.  Either
  ;; way the value is kept as given.  All of this measured on the three
  ;; back ends.  One private copy per (gam ...) library whose checks use
  ;; it; "Prelude gaps" in docs/limits.md says why, and all eight change
  ;; together when that entry does.
  (define ($finite? x) (let ((y (inexact x))) (= 0 (- y y))))

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
      ;; $finite? rather than a cutoff: these values may legitimately be
      ;; negative or very large, and a finite cutoff would refuse
      ;; legitimate values while (= x x) alone admits both infinities.  An
      ;; infinite position is not a far-away one.  Measured 2026-09-23:
      ;; with yaw 0, field-contains? multiplied an infinite offset by the
      ;; 0.0 that (sin 0.0) gives -- exactly zero, though inexact -- got
      ;; NaN, and with the comparison it used then answered that a point
      ;; infinitely far away was INSIDE a circle of radius five.
      ;; The helper stays private: a concept used only in argument checks
      ;; is not a reason for a public name.
      (unless (and (real? x) ($finite? x) (real? z) ($finite? z))
        (error 'make-field "a position is two reals, finite as flonums" x z))
      (unless (and (real? radius) ($finite? radius) (< 0 (inexact radius)))
        (error 'make-field
               "a radius is a real, positive and finite as a flonum"
               radius))
      (unless (and (real? half-length) ($finite? half-length)
                   (<= 0 half-length))
        (error 'make-field
               "a half-length is a non-negative real, finite as a flonum"
               half-length))
      (unless (and (real? yaw) ($finite? yaw))
        (error 'make-field
               "a yaw in radians is a real, finite as a flonum"
               yaw))
      (unless (and (real? duration) ($finite? duration)
                   (< 0 (inexact duration)))
        (error 'make-field
               "a duration is a real, positive and finite as a flonum"
               duration))
      (unless (and (real? rate) ($finite? rate))
        (error 'make-field
               "a rate per unit of time is a real, finite as a flonum"
               rate))
      (unless (and (real? period) ($finite? period) (<= 0 period))
        (error 'make-field
               "a settling period is a non-negative real, finite as a flonum"
               period))
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
    ;; $finite? excludes NaN and both infinities, all of which `real?'
    ;; admits, and an exact number too large to become a finite flonum.
    ;; An infinite query point is refused like a NaN one, so this entry
    ;; treats every value that is not finite as a flonum the same way.
    (unless (and (real? x) ($finite? x) (real? z) ($finite? z))
      (error 'field-contains?
             "a position is two reals, finite as flonums"
             x z))
    ;; Finite inputs can still overflow: two points near opposite ends of
    ;; the number line are an infinite distance apart, and an infinity
    ;; times (sin 0.0) -- exactly zero, though inexact -- is NaN.  So the
    ;; offsets are divided by the radius first and the test is the one
    ;; comparison (<= ... 1.0), which is true only for a sum that came out
    ;; a number no greater than one.  Which way a point on the radius
    ;; itself goes depends on how sin and cos round, not only on <=
    ;; against <.  Measured 2026-09-25 at yaw 0, where (cos 0.0) is
    ;; 0.9999999999939766: with a radius of 5e-324, the smallest positive
    ;; flonum, the product with cos rounded back to the radius, the sum
    ;; was exactly 1.0, and <= answered inside where < would not; with a
    ;; radius of 5, points at (5, 0) and (3, 4) from the centre gave a sum
    ;; of 0.9999999999879532 -- 6e-12 of the radius inside it -- and were
    ;; inside under <= and < alike.  So a point that close to the radius
    ;; may be answered either way; at other yaws the margin follows the
    ;; accuracy of sin and cos.  An infinity or a NaN makes the comparison
    ;; false, and false is "outside".  That holds for inputs finite as
    ;; flonums, which the checks here and in make-field ensure.
    ;; (max 0.0 NaN) answers 0.0 and can hide a NaN in along, but along
    ;; is NaN only through an
    ;; infinity times zero or an infinity minus an infinity, and in each
    ;; such case across is then infinite or NaN as well.  Before the checks
    ;; read values as flonums, an exact half-length of 2^1024 became
    ;; +inf.0 in the subtraction, max hid the NaN, and a point far outside
    ;; was answered inside.  An inside point can still be answered outside
    ;; when the subtraction overflows; that is the direction chosen.  Yaw
    ;; is outside this argument: sin and cos lose accuracy as the angle
    ;; grows ("Trigonometric accuracy" in docs/limits.md), and at a yaw of
    ;; 1e20 both answered 0.0, measured 2026-09-25, so the answer can be
    ;; wrong either way.  The former test was (not (< r^2 sum)), and
    ;; measured 2026-09-23 on all three back ends the `not' turned a false
    ;; comparison into INSIDE: a NaN sum for a centre at -1.7e308 and a
    ;; query at +1.7e308, and infinity against infinity for a query at
    ;; 2e200 with radius 1e200.  Dividing first also keeps that second case
    ;; finite, so it is answered right.
    (let* ((dx (- x ($x f)))
           (dz (- z ($z f)))
           (a ($yaw f))
           (along (+ (* dx (cos a)) (* dz (sin a))))
           (across (- (* dz (cos a)) (* dx (sin a))))
           (over (max 0.0 (- (abs along) ($half f))))
           (r ($radius f))
           (u (/ over r))
           (v (/ across r)))
      (<= (+ (* u u) (* v v)) 1.0)))

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
    (unless (and (real? dt) ($finite? dt) (<= 0 dt))
      (error 'field-step!
             "an elapsed time is a non-negative real, finite as a flonum"
             dt))
    (unless (procedure? settle)
      (error 'field-step! "settling takes a procedure of a field and an amount" settle))
    (when (< 0 ($life f))
      ;; Clamped to the life remaining: this is the last partial period
      ;; the header is about.
      ;; Both new values are worked out before either is stored, and
      ;; the accumulator is checked first: a finite accumulator and a
      ;; finite step can add up to one that is not, and a refused step
      ;; leaves the life and the accumulator as they were.
      (let* ((lived (min dt ($life f)))
             (next-life (max 0.0 (- ($life f) dt)))
             (next-acc (+ ($acc f) lived)))
        (unless ($finite? next-acc)
          (error 'field-step!
                 "the settling accumulator would not be finite as a flonum"
                 ($acc f) dt))
        ($life! f next-life)
        ($acc! f next-acc)
        ;; Expiry settles whatever has accumulated, however little, so
        ;; the tail of the life is never dropped for being short.
        (when (or (not (< ($acc f) ($period f))) (not (< 0 ($life f))))
          (let ((owed (* ($acc f) ($rate f))))
            ($acc! f 0.0)
            (settle f owed)))))))
