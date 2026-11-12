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
          field-contains? field-step!
          $field-exact-calls)
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

  ;; ---- containment, exactly: a filter in flonums, then exact arithmetic ----
  ;;
  ;; The constants of the filter's error bound, each built from 1.0 by
  ;; halving so that its value is exactly the power of two it names (a
  ;; decimal literal would be one more rounding to trust): u = 2^-53,
  ;; the unit roundoff; eta = 2^-1074, the smallest subnormal; 2^-1021,
  ;; below which the spacing of the flonums is eta; and 1 + 2^-51 = 1 + 4u.
  (define ($halved k)
    (let loop ((v 1.0) (i 0))
      (if (= i k) v (loop (fl/ v 2.0) (+ i 1)))))
  (define $u ($halved 53))
  (define $two-u (fl* 2.0 $u))
  (define $eta ($halved 1074))
  (define $two-eta (fl* 2.0 $eta))
  (define $up-floor ($halved 1021))
  (define $up-factor (fl+ 1.0 ($halved 51)))
  ;; The bound's arithmetic is written as macros, not procedures, so that
  ;; the fast path is one let* of flonum expressions: on the wasm target
  ;; a let binding whose value is an fl operation, or an if whose two
  ;; arms are, lives in an unboxed f64 slot, while every value a
  ;; procedure RETURNS is a boxed flonum -- an allocation per call, which
  ;; is what an earlier version of this paid at every step.  Each macro
  ;; expands into such an expression.  $up-of evaluates its argument
  ;; twice (the test and one arm), so every macro is given NAMES, bound
  ;; earlier in the let*: nesting them would repeat the inner arithmetic
  ;; at every level, which costs nothing much on wasm and an allocation
  ;; per repeat on the JS target.
  ;;
  ;; |w|.  (rnrs) here has no flabs.  -0.0 comes back as itself, which is
  ;; no matter: every use is a magnitude.
  (define-syntax $abs-of
    (syntax-rules ()
      ((_ w) (if (fl<? w 0.0) (fl- 0.0 w) w))))
  ;; up(w) >= the real value w is the rounding of, for w >= 0: below
  ;; 2^-1021 the rounding is off by at most eta/2 and w + 2 eta is exact;
  ;; above it by at most u w, and w (1 + 4u) rounded still covers that.
  ;; Every operation that computes an error BOUND is followed by it, so
  ;; each bound is no smaller than what it bounds.  A NaN or an infinity
  ;; passes through unchanged.
  (define-syntax $up-of
    (syntax-rules ()
      ((_ w) (if (fl<? w $up-floor) (fl+ w $two-eta) (fl* w $up-factor)))))
  ;; the error of one rounded operation whose result is w: 2u|w| + eta
  ;; (u relative in the normal range, eta for a subnormal result)
  (define-syntax $beta-of
    (syntax-rules ()
      ((_ w) ($up-of (fl+ ($up-of (fl* $two-u ($abs-of w))) $eta)))))
  ;; In the three below, bw is beta(w) -- the local error of the rounded
  ;; result -- bound to its own name first.
  ;; the error of a sum or difference w of two values carrying e1, e2:
  ;; e1 + e2 + beta(w)
  (define-syntax $sum-error-of
    (syntax-rules ()
      ((_ e1 e2 bw) ($up-of (fl+ ($up-of (fl+ e1 e2)) bw)))))
  ;; the error of a product p = d * k rounded, for a d carrying an error
  ;; ed and an exact k: |k| ed + beta(p)
  (define-syntax $product-error-of
    (syntax-rules ()
      ((_ k ed bp) ($up-of (fl+ ($up-of (fl* ($abs-of k) ed)) bp)))))
  ;; the error of z = v * v rounded, for a v carrying an error ev:
  ;; 2|v| ev + ev^2 + beta(z), given the bound vev = up(|v| ev) by name;
  ;; doubling a bound is exact, or overflows to +inf.0, which sends the
  ;; input to the exact path
  (define-syntax $square-error-of
    (syntax-rules ()
      ((_ vev ev bz)
       ($up-of (fl+ ($up-of (fl+ (fl* 2.0 vev) ($up-of (fl* ev ev)))) bz)))))
  ;; up(|v| ev), the first term of a square's error, named for the above
  (define-syntax $scaled-error-of
    (syntax-rules ()
      ((_ v ev) ($up-of (fl* ($abs-of v) ev)))))
  ;; the flonum an input becomes (a flonum is returned as it is, so this
  ;; allocates only for an exact input), and the error of converting an
  ;; EXACT input: none when the flonum equals it, else beta of the flonum.
  ;; field-contains? asks for the second only when the input is exact.
  (define ($as-flonum v) (if (flonum? v) v (inexact v)))
  (define ($exact-conversion-error v)
    (let ((w (inexact v)))
      (if (= (exact w) v) 0.0 ($beta-of w))))
  (define ($exactly v) (if (exact? v) v (exact v)))

  ;; The shape itself, on exact values: the inequality the filter stands
  ;; in for, decided with no rounding at all.  It is slow -- goeteia's
  ;; bignum ratios cost milliseconds a call -- and is reached only for
  ;; the inputs the filter cannot decide.  Each entry is counted, so that
  ;; a test can see which path a call took ($field-exact-calls, an
  ;; internal export): an ordinary point that reached this path would
  ;; give the right answer, slowly, and nothing else would show it.
  (define $exact-calls 0)
  (define ($field-exact-calls) $exact-calls)
  (define ($contains-exactly? fx fz r h c s x z)
    (set! $exact-calls (+ $exact-calls 1))
    (let* ((dx (- ($exactly x) ($exactly fx)))
           (dz (- ($exactly z) ($exactly fz)))
           (ce ($exactly c))
           (se ($exactly s))
           (along (+ (* dx ce) (* dz se)))
           (across (- (* dz ce) (* dx se)))
           (over (max 0 (- (abs along) ($exactly h))))
           (re ($exactly r)))
      (<= (+ (* over over) (* across across)) (* re re))))

  ;; THE SHAPE.  With c = (cos yaw) and s = (sin yaw) as computed -- not
  ;; normalised: goeteia's trigonometry is approximate, and c^2 + s^2 is
  ;; off 1 by up to about 1e-11 -- the field holds the real points (x, z)
  ;; with
  ;;     max(0, |A| - h)^2 + B^2 <= r^2,
  ;;     A = (x - fx) c + (z - fz) s,   B = (z - fz) c - (x - fx) s,
  ;; on the stored values and those two flonums, in exact arithmetic.
  ;; That is a capsule along (c, s): the point is turned into the field's
  ;; frame, the half-length is subtracted from the distance along the
  ;; axis -- a point past an end has its overshoot measured from the end
  ;; cap, which is what makes the ends round -- and what is left is
  ;; compared with the radius, squared so that there is no square root.
  ;; Every value in it is a dyadic rational, so the answer is exact, on
  ;; the boundary too (a point on it is inside: <=).
  ;;
  ;; A yaw so large that the computed c or s is not finite -- the range
  ;; reduction is lost: at a yaw of 1.070931672115544e40 both are -inf.0
  ;; -- has no shape under that definition, and holds no point: #f, with
  ;; no error, for every query.  Long before that, sin and cos stop
  ;; meaning the angle ((sin 1e20) is 0.0); the answer is then exact for
  ;; the c and s computed, which is all it promises ("Trigonometric
  ;; accuracy" in docs/limits.md).
  ;;
  ;; THE FILTER.  Exact arithmetic is far too slow for every call, so the
  ;; same expression is first evaluated in flonums, each input converted
  ;; with its conversion error, and every rounded step carries a bound on
  ;; its error, built up step by step (|w - exact| <= 2u|w| + eta for one
  ;; rounded result w; a product with the exact c or s scales its
  ;; operand's bound by |c| or |s|; a sum adds; a square of v with bound
  ;; e has 2|v| e + e^2; max(0, .) and abs keep their argument's), each
  ;; bound operation followed by $up.  With q the flonum value of the
  ;; left side, t = r^2 rounded, and E the sum of their bounds:
  ;;     inside   when up(q + E) < t
  ;;     outside  when q > up(t + E)
  ;; Each test proves the exact left side is on that side of the exact
  ;; r^2.  Everything else -- a point within E of the boundary, any value
  ;; or bound that overflows or is NaN (a finite E means every rounded
  ;; value and bound behind it was finite: each feeds its own bound into
  ;; E, and E only grows), a radius near the subnormal range -- goes to
  ;; the exact path.  For ordinary inputs the band is of relative width
  ;; about 1e-15, so the exact path is rare.  On the wasm target the
  ;; filter allocates nothing for flonum inputs beyond the two flonums
  ;; cos and sin return; the JS target, by its own design, boxes the
  ;; result of every flonum operation (src/js-backend.ss).
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
    ;; Every binding of the let* below is an fl operation or an if of
    ;; two, so on the wasm target each lives in an unboxed slot and the
    ;; filter allocates nothing past the two flonums cos and sin return.
    ;; An input is taken as (fl* v 1.0), which is v exactly (-0.0 too);
    ;; a conversion error is the literal 0.0 for a flonum input, and only
    ;; an exact input makes the call that may allocate.
    (let* ((a ($yaw f))
           (c (fl* ($as-flonum (cos a)) 1.0))
           (s (fl* ($as-flonum (sin a)) 1.0)))
      (and (fl=? (fl- c c) 0.0)
           (fl=? (fl- s s) 0.0)
           (let* ((fx ($x f)) (fz ($z f)) (r ($radius f)) (h ($half f))
                  (X (fl* ($as-flonum x) 1.0))
                  (eX (if (flonum? x) 0.0 (fl* ($exact-conversion-error x) 1.0)))
                  (Z (fl* ($as-flonum z) 1.0))
                  (eZ (if (flonum? z) 0.0 (fl* ($exact-conversion-error z) 1.0)))
                  (FX (fl* ($as-flonum fx) 1.0))
                  (eFX (if (flonum? fx) 0.0 (fl* ($exact-conversion-error fx) 1.0)))
                  (FZ (fl* ($as-flonum fz) 1.0))
                  (eFZ (if (flonum? fz) 0.0 (fl* ($exact-conversion-error fz) 1.0)))
                  (H (fl* ($as-flonum h) 1.0))
                  (eH (if (flonum? h) 0.0 (fl* ($exact-conversion-error h) 1.0)))
                  (R (fl* ($as-flonum r) 1.0))
                  (eR (if (flonum? r) 0.0 (fl* ($exact-conversion-error r) 1.0)))
                  (dx (fl- X FX)) (b-dx ($beta-of dx))
                  (edx ($sum-error-of eX eFX b-dx))
                  (dz (fl- Z FZ)) (b-dz ($beta-of dz))
                  (edz ($sum-error-of eZ eFZ b-dz))
                  (p1 (fl* dx c)) (b-p1 ($beta-of p1))
                  (e1 ($product-error-of c edx b-p1))
                  (p2 (fl* dz s)) (b-p2 ($beta-of p2))
                  (e2 ($product-error-of s edz b-p2))
                  (p3 (fl* dz c)) (b-p3 ($beta-of p3))
                  (e3 ($product-error-of c edz b-p3))
                  (p4 (fl* dx s)) (b-p4 ($beta-of p4))
                  (e4 ($product-error-of s edx b-p4))
                  (along (fl+ p1 p2)) (b-along ($beta-of along))
                  (e-along ($sum-error-of e1 e2 b-along))
                  (across (fl- p3 p4)) (b-across ($beta-of across))
                  (e-across ($sum-error-of e3 e4 b-across))
                  (w (fl- ($abs-of along) H)) (b-w ($beta-of w))
                  (e-over ($sum-error-of e-along eH b-w))
                  (over (if (fl<? w 0.0) 0.0 w))
                  (z-over (fl* over over)) (b-z-over ($beta-of z-over))
                  (s-over ($scaled-error-of over e-over))
                  (e-z-over ($square-error-of s-over e-over b-z-over))
                  (z-across (fl* across across))
                  (b-z-across ($beta-of z-across))
                  (s-across ($scaled-error-of across e-across))
                  (e-z-across ($square-error-of s-across e-across b-z-across))
                  (q (fl+ z-over z-across)) (b-q ($beta-of q))
                  (eq ($sum-error-of e-z-over e-z-across b-q))
                  (t (fl* R R)) (b-t ($beta-of t))
                  (s-r ($scaled-error-of R eR))
                  (et ($square-error-of s-r eR b-t))
                  (E-sum (fl+ eq et))
                  (E ($up-of E-sum))
                  (q-sum (fl+ q E))
                  (t-sum (fl+ t E))
                  (q-high ($up-of q-sum))
                  (t-high ($up-of t-sum)))
             (cond
              ((not (and (fl=? (fl- q q) 0.0) (fl=? (fl- t t) 0.0)
                         (fl=? (fl- E E) 0.0)))
               ($contains-exactly? fx fz r h c s x z))
              ((fl<? q-high t) #t)
              ((fl<? t-high q) #f)
              (else ($contains-exactly? fx fz r h c s x z)))))))

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
