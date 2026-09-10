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

;; Crossing from one level of detail to the next.
;;
;; Choosing WHICH level draws is a separate question, and (gfx scene)
;; already answers it: a (lod (@ (switch d1 d2 ...)) ...) container
;; picks one alternative by distance and draws it. That switch is hard
;; -- one frame the fine mesh, the next the coarse one -- and the seam
;; is what these two functions cover.
;;
;; They live in their own library rather than in (gfx scene) because
;; both backends want them and neither can import the other's scene
;; layer: (gfx scene) is the GL declarative DSL and pulls in (web
;; reactive) with it, and (gfx sgpu) says in its own header that lod
;; containers are not there yet. A caller writing its own draw loop
;; straight against (gfx fx) wants a dithered transition too, and
;; should not have to import a reactive system to get two shader
;; functions. Nothing here depends on anything but (rnrs).
(library (gfx lod)
  (export lod-shader-functions)
  (import (rnrs))

  ;; lod_interval answers the half-open coverage interval [lo, hi) this
  ;; tier occupies in the dither space, and dither_threshold answers
  ;; where a pixel falls in that space. A fragment draws when its
  ;; threshold is inside its tier's interval, so a pixel belongs to
  ;; exactly one tier and the transition is a dissolve rather than a
  ;; pop, with no blending state and no sorted second pass.
  ;;
  ;; The three tiers partition [0, 1): tier 0 fades in as the near edge
  ;; passes, tier 1 holds the middle, tier 2 takes over past the far
  ;; edge. `complete` is how finished the fine tier's own work is (an
  ;; asset still streaming in is not ready to own its pixels), and it
  ;; scales the near tier's share.
  ;;
  ;; The edges are FORCED into order rather than assumed, because there
  ;; is no error on a device and no way to test for one from inside a
  ;; fragment shader. Both failures are silent and neither looks like a
  ;; bug in this function:
  ;;
  ;;   near.y above far.x  ->  the middle interval runs backwards, is
  ;;                           empty for every threshold, and that tier
  ;;                           draws not one pixel;
  ;;   complete above one  ->  the first and last intervals both cover
  ;;                           all of [0, 1) and the fine mesh and the
  ;;                           distant stand-in draw on top of each
  ;;                           other.
  ;;
  ;; Ordering by min and max costs three instructions and removes both.
  (define $lod-shader-functions
    '((define (lod_interval (float d) (float complete)
                            (vec2 near_edges) (vec2 far_edges)
                            (float tier)) vec2
        (local float ready (clamp complete (fl 0) (fl 1)))
        (local float n1 (min near_edges.y far_edges.x))
        (local float n0 (min near_edges.x n1))
        (local float f1 (max far_edges.y far_edges.x))
        (local float full (* (- (fl 1) (smoothstep n0 n1 d)) ready))
        (local float distant (smoothstep far_edges.x f1 d))
        (return (?: (> tier (fl 1 5))
                    (vec2 (- (fl 1) distant) (fl 1))
                    (?: (> tier (fl 0 5))
                        (vec2 full (- (fl 1) distant))
                        (vec2 (fl 0) full)))))

      ;; A per-pixel value in [0, 1) that is stable frame to frame and
      ;; has no visible structure: the interleaved-gradient hash, which
      ;; is one dot product and two fracts. Screen coordinates are
      ;; floored first, so every sample within a pixel answers the same
      ;; and a tier's dissolve does not shimmer under multisampling.
      (define (dither_threshold (vec2 pixel)) float
        (return (fract (* (fl 52 9829189)
                          (fract (dot (floor pixel)
                                      (vec2 (fl 0 6711056 8)
                                            (fl 0 583715 8))))))))))

  (define (lod-shader-functions) $lod-shader-functions))
