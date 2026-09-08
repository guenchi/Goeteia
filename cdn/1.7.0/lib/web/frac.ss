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
  (export frac-digits)
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
  )
