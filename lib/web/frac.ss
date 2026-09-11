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

;; The digits after a decimal point, and nothing else.
;;
;; (web css) and (gfx glsl) both render a number written as a whole part
;; and a fraction -- (em 3 4) and (fl 3 4) -- and both had their own copy
;; of the rule for turning that fraction into digits.  The copies drifted:
;; glsl took a width and padded to it, css always padded to two, so the
;; same pair of operands meant different numbers in the two languages.
;; One rule now, imported by both.
;;
;; THE CONTRACT STOPS AT THE DIGITS.  This answers a string that may be
;; empty; it does not know about a decimal point, a sign, or a whole
;; part.  That boundary is not fastidiousness -- the consumers disagree
;; about the empty case and both are right.  CSS must drop the point,
;; because "1.em" is not a value; GLSL must keep it, because "1" is an
;; int and "1.0" is a float.  A helper that returned the whole rendered
;; number would have to choose, and would be wrong for one of them.
;;
(library (web frac)
  (export frac-digits fl->fixed)
  (import (rnrs))

  ;; PAD FIRST, THEN STRIP.  (em 0 50 3) is 0.05: 50 becomes "050" and
  ;; loses its trailing zero.  Stripping first would leave "5", pad to
  ;; "005", and answer 0.005 -- the order is the whole of the rule, and
  ;; it is what test/css.ss checks with 50/3 and 100/4.
  (define (frac-digits f width)
    (let pad ((s (number->string f)))
      (if (< (string-length s) width)
          (pad (string-append "0" s))
          (let strip ((n (string-length s)))
            (cond
             ((= n 0) "")
             ((char=? #\0 (string-ref s (- n 1))) (strip (- n 1)))
             (else (substring s 0 n)))))))

  ;; ---- fl->fixed ---------------------------------------------------
  ;;
  ;; The d-decimal spelling of the double NEAREST x*10^d: scale, round
  ;; half to even, split.  Flonum and fixnum only -- no exact
  ;; arithmetic, no bignum -- because the callers are frame sites and
  ;; pay this per frame.  That is the whole reason it is not the exact
  ;; printer: the exact printer answers a different question and costs
  ;; what answering it costs.
  ;;
  ;; So it is NOT the exact-decimal rounding of x, and the difference is
  ;; observable: 2.675 answers "2.68" and 0.995 answers "1.00", each one
  ;; unit from what rounding the literal's exact value would give
  ;; ("2.67", "0.99").  Those two ARE the contract, not an artefact --
  ;; the nearest double to 2.675*100 is 267.50000000000002842..., which
  ;; rounds up.  Anything that "fixes" them has changed the contract.
  ;; archive/goeteia-float-printer-oracle.ss computes both columns, so
  ;; the expectation never comes from this code's own output.

  (define (pow10 d)
    (let loop ((i d) (a 1.0))
      (if (= i 0) a (loop (- i 1) (fl* a 10.0)))))

  ;; Half to even, built from flfloor: there is no flround among the
  ;; primitives.  An integral flonum f is even when f - 2*floor(f/2) is
  ;; zero.
  (define (round-half-even v)
    (let* ((f (flfloor v))
           (diff (fl- v f)))
      (cond
       ((fl<? diff 0.5) f)
       ((fl<? 0.5 diff) (fl+ f 1.0))
       ((fl=? 0.0 (fl- f (fl* 2.0 (flfloor (fl/ f 2.0))))) f)
       (else (fl+ f 1.0)))))

  (define (pad-left s width)
    (if (< (string-length s) width)
        (pad-left (string-append "0" s) width)
        s))

  ;; Finite, without a predicate for it: v - v is 0.0 for every finite
  ;; flonum and NaN for an infinity or a NaN, and NaN is equal to
  ;; nothing including itself.
  (define (fl-finite? v) (fl=? 0.0 (fl- v v)))

  ;; The largest value %fl->fx can take.  Checked AFTER scaling, because
  ;; rounding can carry a value across the edge that was inside it
  ;; before.
  (define $fixnum-edge 1073741823.0)

  ;; A negative zero prints unsigned, and so does any value whose digits
  ;; all rounded away: -0.001 at two decimals is "0.00", not "-0.00".
  ;;
  ;; OUT OF CONTRACT -- not finite, or scaled past the fixnum edge --
  ;; answers what number->string answers (design 8.4).  d decimals are
  ;; not guaranteed there, but this is a public export of (web frac) and
  ;; a page may hand it any flonum at all: %fl->fx traps on 1e300 with
  ;; "float unrepresentable in integer range", and a crash is a worse
  ;; answer than a slow one.  test/frac-fl-fixed.ss reaches this with
  ;; +inf.0, +nan.0 and 1e300 -- a guard nothing reaches is a guard
  ;; nobody can show works.
  (define (fl->fixed x d)
    (if (not (fl-finite? x))
        (number->string x)
        (fl->fixed* x d)))

  (define (fl->fixed* x d)
    (let* ((neg (fl<? x 0.0))
           (a (if neg (fl- 0.0 x) x))
           (scaled (round-half-even (fl* a (pow10 d)))))
      (if (fl<? $fixnum-edge scaled)
          (number->string x)
          (fl->fixed-spell scaled neg d))))

  (define (fl->fixed-spell scaled neg d)
    (let* ((n (%fl->fx scaled))
           (s (pad-left (number->string n) (+ d 1)))
           (k (string-length s))
           (whole (substring s 0 (- k d)))
           (frac (if (> d 0) (string-append "." (substring s (- k d) k)) "")))
      (string-append (if (and neg (not (= n 0))) "-" "") whole frac)))

  )
