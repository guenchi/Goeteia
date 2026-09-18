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
        (return (apply_normal_map (tangent_frame n wp uv front) bump scale)))

      ;; ---- shading terms -------------------------------------------
      ;;
      ;; Closed functions of their arguments: no uniforms, no texture
      ;; state beyond the sampler passed in, and no dependence on the
      ;; stage they are called from except where a derivative is taken.
      ;;
      ;; surface_tangent and filtered_roughness take screen-space
      ;; derivatives, so this set needs ES 3.00 or the OES derivative
      ;; extension. Splitting those two out to keep the rest on ES 1.00
      ;; would split a set that callers use together.

      ;; Three samples of one texture along the cardinal planes, blended
      ;; by the caller's weights. The samples bind to locals because a
      ;; field of a CALL result has no spelling in this notation.
      (define (triplanar_color (sampler2D tex) (vec3 point) (vec3 weights)) vec3
        (local vec4 sx (texture tex point.yz))
        (local vec4 sy (texture tex point.xz))
        (local vec4 sz (texture tex point.xy))
        (return (+ (* sx.rgb weights.x) (* sy.rgb weights.y) (* sz.rgb weights.z))))

      ;; Height gradients projected onto the surface. The floor under
      ;; each map's z keeps the gradient finite where that map is flat,
      ;; and the last term removes the component along the base normal so
      ;; the result stays a perturbation rather than a rotation.
      (define (triplanar_normal (vec3 base) (vec3 x_map) (vec3 y_map) (vec3 z_map) (vec3 weights)) vec3
        (local vec3 x (- (* x_map (fl 2)) (fl 1)))
        (local vec3 y (- (* y_map (fl 2)) (fl 1)))
        (local vec3 z (- (* z_map (fl 2)) (fl 1)))
        (local vec3 gradient
          (+ (/ (* (vec3 (fl 0) x.x x.y) weights.x) (max x.z (fl 0 25)))
             (/ (* (vec3 y.x (fl 0) y.y) weights.y) (max y.z (fl 0 25)))
             (/ (* (vec3 z.x z.y (fl 0)) weights.z) (max z.z (fl 0 25)))))
        (return (normalize (- (+ base gradient) (* base (dot base gradient))))))

      ;; A tangent that follows the texture's V axis. The guard is the
      ;; degenerate case this shares with tangent_frame: where the UV
      ;; derivatives carry no direction the tangent collapses to zero and
      ;; normalize would divide by it, so an arbitrary perpendicular is
      ;; substituted -- arbitrary being the honest answer there.
      (define (surface_tangent (vec3 point) (vec2 uv) (vec3 normal)) vec3
        (local vec3 a (dFdx point)) (local vec3 b (dFdy point))
        (local vec2 u (dFdx uv)) (local vec2 v (dFdy uv))
        (local vec3 t (- (* b u.x) (* a v.x)))
        (set! t (- t (* normal (dot t normal))))
        (if (< (dot t t) (fl 0 1 8))
            (set! t (cross normal (?: (< (abs normal.y) (fl 0 9)) (vec3 0 1 0) (vec3 1 0 0)))))
        (return (normalize t)))

      ;; A normalized wrapped diffuse lobe: light that enters and leaves
      ;; nearby, approximated without a blur pass. The two divisions keep
      ;; the lobe energy-conserving as the wrap widens.
      (define (skin_diffuse (vec3 normal) (vec3 light) (vec3 albedo)) vec3
        (local float wrapped (/ (max (/ (+ (dot normal light) (fl 0 22)) (fl 1 22)) (fl 0)) (fl 1 22)))
        (return (/ (* albedo wrapped) (fl 3 14159265))))

      ;; An anisotropic highlight around a fiber's tangent, with the
      ;; normalization that keeps total energy roughly constant as the
      ;; exponent moves with roughness.
      (define (fiber_specular (vec3 tangent) (vec3 half_direction) (float roughness)) float
        (local float alignment (max (fl 0) (- (fl 1) (pow (dot tangent half_direction) (fl 2)))))
        (local float exponent (mix (fl 110) (fl 18) roughness))
        (return (* (pow alignment exponent) (sqrt exponent) (fl 0 45 3))))

      ;; Retroreflection at grazing angles, which is what reads as cloth.
      (define (cloth_sheen (vec3 normal) (vec3 view) (vec3 light)) float
        (return (* (pow (- (fl 1) (max (dot normal view) (fl 0))) (fl 4))
                   (max (dot normal light) (fl 0))
                   (fl 0 12))))

      ;; Light through a thin slab: a forward lobe for the light behind
      ;; the surface, attenuated by thickness and tinted toward the
      ;; wavelengths a leaf transmits rather than reflects.
      (define (leaf_transmission (vec3 albedo) (vec3 view) (vec3 light) (vec3 normal) (float thickness)) vec3
        (local float forward (pow (max (dot (- view) light) (fl 0)) (fl 4)))
        (local float thin (* (exp (* (- (max thickness (fl 0))) (fl 1 8)))
                             (+ (fl 0 4) (* (fl 0 6) (- (fl 1) (abs (dot normal light)))))))
        (return (* albedo (vec3 (fl 0 70) (fl 0 86) (fl 0 42)) forward thin)))

      ;; Roughness widened by the normal's variation inside one pixel, so
      ;; a minified normal map does not alias into specular sparkle. The
      ;; clamp keeps the result inside the range the BRDF was fitted over.
      (define (filtered_roughness (vec3 normal) (float roughness)) float
        (local vec3 dx (dFdx normal)) (local vec3 dy (dFdy normal))
        (local float variance (min (fl 0 18) (* (fl 0 25) (+ (dot dx dx) (dot dy dy)))))
        (return (clamp (sqrt (+ (* roughness roughness) variance)) (fl 0 16) (fl 0 98))))

      ;; Where a layer wins against the surface under it: coverage biased
      ;; by the height difference, with width as the transition.
      (define (surface_height_blend (float coverage) (float base_height) (float layer_height) (float width)) float
        (return (smoothstep (- width) width (- (+ coverage layer_height) base_height))))

      ;; Beer-Lambert through a depth of water, with in-scattering taking
      ;; over what absorption removes.
      (define (water_transmission (vec3 bottom) (vec3 scattering) (vec3 absorption) (float distance)) vec3
        (local vec3 transmittance (exp (* (- (max absorption (vec3 (fl 0)))) (max distance (fl 0)))))
        (return (+ (* bottom transmittance) (* scattering (- (fl 1) transmittance)))))

      ;; How wet ground is, from how far it sits above the water. The
      ;; floor under band keeps the transition from becoming a step when
      ;; a caller passes zero.
      (define (shore_wetness (float ground_height) (float water_height) (float band)) float
        (return (- (fl 1) (smoothstep (fl 0) (max band (fl 0 1 3)) (- ground_height water_height)))))

      ;; Hemisphere ambient: ground below, sky above, with metals taking
      ;; none of it as diffuse.
      (define (ambient_diffuse (vec3 albedo) (float metallic) (vec3 normal) (vec3 ground) (vec3 sky)) vec3
        (return (* albedo (- (fl 1) metallic) (mix ground sky (+ (* normal.y (fl 0 5)) (fl 0 5))))))

      ;; ---- water optics --------------------------------------------

      ;; The submerged length of one ray. Subtracting two rays' distances
      ;; instead would invent shallow bands under refraction, so the
      ;; fraction is taken along a single ray; a horizontal ray has no
      ;; fraction to take and the branch answers it directly.
      (define (water_path_length (vec3 eye) (vec3 bottom) (float height)) float
        (local float span (abs (- bottom.y eye.y)))
        (local float submerged (- height (min bottom.y eye.y)))
        (if (== span (fl 0)) (return (?: (< bottom.y height) (distance bottom eye) (fl 0))))
        (return (* (distance bottom eye) (clamp (/ submerged span) (fl 0) (fl 1)))))

      ;; A hash and the value noise built on it. Both are functions of
      ;; position alone, so foam does not swim when the camera moves.
      (define (water_foam_hash (vec2 p)) float
        (local vec3 q (fract (* (vec3 p.xyx) (fl 0 1031))))
        (set! q (+ q (dot q (+ q.yzx (fl 33 33)))))
        (return (fract (* (+ q.x q.y) q.z))))

      (define (water_foam_noise (vec2 p)) float
        (local vec2 cell (floor p)) (local vec2 f (fract p))
        (set! f (* f f (- (fl 3) (* (fl 2) f))))
        (return (mix (mix (water_foam_hash cell) (water_foam_hash (+ cell (vec2 1 0))) f.x)
                     (mix (water_foam_hash (+ cell (vec2 0 1))) (water_foam_hash (+ cell (vec2 1 1))) f.x)
                     f.y)))

      ;; Foam at the contact line: in across the shallows and out again
      ;; before deep water, broken up by noise in world space so the
      ;; contour carries no repeating direction.
      (define (water_shore_foam (vec2 position) (float depth) (float footprint) (float time) (float band)) float
        (local float edge (max footprint (fl 0 1 3)))
        (local float contact (* (smoothstep (fl 0) edge depth)
                                (- (fl 1) (smoothstep (* band (fl 0 25)) (+ band edge) depth))))
        (if (<= contact (fl 0)) (return (fl 0)))
        (local vec2 drift (vec2 (* time (fl 0 35 3)) (* (- time) (fl 0 23 3))))
        (local float patches (+ (* (water_foam_noise (+ (* position (fl 6 3)) drift)) (fl 0 65))
                                (* (water_foam_noise (- (* position (fl 17 7)) drift)) (fl 0 35))))
        (return (* contact (smoothstep (fl 0 48) (fl 0 74) patches))))))

  (define (surface-shader-functions) $surface-shader-functions))
