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
;; The sRGB transfer function, both directions, as shader forms.
;;
;; An 8-bit color a person picks, a texel from an ordinary image, a
;; byte on the canvas: each is sRGB-encoded, and light does not add up
;; in that encoding.  A shader decodes what comes in, does its lighting
;; on linear values, and encodes what goes out.  These are the exact
;; piecewise curve of IEC 61966-2-1 -- a straight segment near black and
;; a 2.4 power above it -- and not the single power 2.2 that often
;; stands in for it: the two agree in the middle and part in the dark,
;; where the straight segment is.
;;
;; DEPENDENCY, and it is not visible to a GLSL compiler: a function
;; elsewhere that calls these -- triplanar_srgb, in (gfx surface)'s
;; surface-srgb-shader-functions --
;; needs this list spliced ahead of it, and splicing it twice defines
;; each function twice, which is a compile error.  So no other list of
;; functions includes this one; the caller splices it, once.  The
;; fragment shaders in (gfx mesh), and the grade pass in (gfx post),
;; are complete shaders rather than lists of functions: they already
;; contain it, and a caller extending one of them must not splice it
;; again.
;;
;; Where to splice it: after the precision statement.  An ES 1.00
;; fragment shader has no default float precision, and a function
;; declared before the statement has none either.
(library (gfx srgb)
  (export srgb-shader-functions)
  (import (rnrs))
  (define $srgb-shader-functions
    '(
      ;; Encoded to linear.  step picks the straight segment at or below
      ;; 0.04045.  mix evaluates both sides, so the side it does not
      ;; pick has to be a number too: GLSL ES does not say what an
      ;; operation on NaN gives, and where it follows IEEE, NaN times
      ;; zero is NaN and the unpicked side reaches the result.  pow of a
      ;; negative base is undefined, so the base is held at zero or
      ;; above.  That changes nothing in [0, 1] and gives an
      ;; input below -0.055 the straight segment's answer, as it gives
      ;; every input down to there.
      (define (decode_srgb (vec3 c)) vec3
        (local vec3 curve (pow (max (/ (+ c "0.055") "1.055") (vec3 (fl 0)))
                               (vec3 "2.4")))
        (return (mix curve (/ c "12.92") (step c (vec3 "0.04045")))))
      ;; Linear to encoded.  A negative value has no encoding, so it is
      ;; taken as zero first, which also keeps pow's base in its domain.
      ;; A value above one encodes above one: an 8-bit target clamps it
      ;; and a floating-point target keeps it.  The straight segment is
      ;; computed on the value held at its own threshold, which is all
      ;; it is ever picked for; unheld, a large value times 12.92 can
      ;; overflow -- in half precision from about 5000 -- and where the
      ;; arithmetic follows IEEE the unpicked infinity reaches the
      ;; result as NaN.
      (define (encode_srgb (vec3 c)) vec3
        (local vec3 v (max c (vec3 (fl 0))))
        (local vec3 curve (- (* (pow v (vec3 (/ (fl 1) "2.4"))) "1.055")
                             "0.055"))
        (local vec3 line (* (min v (vec3 "0.0031308")) "12.92"))
        (return (mix curve line (step v (vec3 "0.0031308")))))))
  (define (srgb-shader-functions) $srgb-shader-functions))
