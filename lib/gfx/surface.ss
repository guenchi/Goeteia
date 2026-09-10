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

;; The geometry of a surface at one point: the tangent basis, and the
;; normal a normal map gives once it is expressed in that basis.
;;
;; The basis is derived from the screen-space derivatives of the world
;; position and of the texture coordinate, so a mesh does NOT have to
;; carry a tangent attribute. That matters for glTF, where the tangent
;; accessor is optional and frequently absent, and where its absence
;; otherwise means the normal map cannot be used at all.
;;
;; DEPENDENCY, and it is not visible to a GLSL compiler: these call
;; safe_unit from (gfx mat). GLSL has no imports, so a caller must
;; splice mat-shader-functions ahead of these -- appending the two
;; lists is enough. Forgetting it is an undefined-function error at
;; shader compile time, which is loud, but it names safe_unit and not
;; the reason, so it is said here.
(library (gfx surface)
  (export surface-shader-functions)
  (import (rnrs))

  (define $surface-shader-functions
    '(;; An orthonormal basis whose third column is the shading normal,
      ;; built from the derivatives of position and texture coordinate
      ;; across the pixel quad. The two tangent columns come out
      ;; already perpendicular to the normal, because each is built
      ;; from vectors that are: crossing the position derivatives with
      ;; the normal projects them into the tangent plane before the
      ;; texture derivatives weight them.
      ;;
      ;; The two failures worth naming, both silent on a device:
      ;;
      ;;   A back face keeps the front face's interpolated normal, so
      ;;   without the flip a two-sided material is lit from behind and
      ;;   its back is black. front is a parameter rather than a read
      ;;   of gl_FrontFacing so a caller that wants to force one side
      ;;   can, and so this does not depend on a fragment-stage
      ;;   built-in.
      ;;
      ;;   A triangle with zero area in UV space makes both tangent
      ;;   columns zero, and the reciprocal square root of zero is
      ;;   infinity. The floor under the larger of the two squared
      ;;   lengths keeps the result finite; the basis it gives is
      ;;   arbitrary, which is the honest answer when the texture
      ;;   coordinates carry no direction.
      (define (tangent_frame (vec3 n) (vec3 wp) (vec2 uv) (bool front)) mat3
        (local vec3 nn (?: front (safe_unit n) (- (safe_unit n))))
        (local vec3 dp1 (dFdx wp))
        (local vec3 dp2 (dFdy wp))
        (local vec2 du1 (dFdx uv))
        (local vec2 du2 (dFdy uv))
        (local vec3 perp2 (cross dp2 nn))
        (local vec3 perp1 (cross nn dp1))
        (local vec3 t (+ (* perp2 du1.x) (* perp1 du2.x)))
        (local vec3 b (+ (* perp2 du1.y) (* perp1 du2.y)))
        (local float inv (inversesqrt (max (max (dot t t) (dot b b))
                                           (fl 0 1 5))))
        (return (mat3 (* t inv) (* b inv) nn)))

      ;; A tangent-space texel turned into a world-space normal.
      ;;
      ;; bump is the texel AS SAMPLED, with each channel in [0, 1]; the
      ;; decode to [-1, 1] happens here, because a caller who has to
      ;; remember it is a caller who will one day not. Sampling stays
      ;; the caller's: it owns the sampler, the coordinate, and any
      ;; level-of-detail bias it wants, and none of that is arithmetic
      ;; this library can do for it.
      ;;
      ;; scale weights the two tangent components only. Scaling the
      ;; third as well would tilt nothing -- it would only shorten the
      ;; vector before it is normalized again, which is a no-op with a
      ;; cost.
      (define (apply_normal_map (mat3 frame) (vec3 bump) (float scale)) vec3
        (local vec3 m (- (* bump (fl 2)) (fl 1)))
        (set! m.xy (* m.xy scale))
        (return (safe_unit (* frame m))))

      ;; The two above, composed. It exists because GLSL has no default
      ;; arguments and the common path is exactly this composition: a
      ;; caller that wants only the basis, for anisotropy or for
      ;; blending a detail map, takes tangent_frame alone.
      ;;
      ;; It is written as the composition rather than as its own
      ;; arithmetic, so the preset cannot drift away from the two
      ;; primitives it stands for.
      (define (surface_normal (vec3 n) (vec3 wp) (vec2 uv)
                              (vec3 bump) (float scale) (bool front)) vec3
        (return (apply_normal_map (tangent_frame n wp uv front) bump scale)))))

  (define (surface-shader-functions) $surface-shader-functions))
