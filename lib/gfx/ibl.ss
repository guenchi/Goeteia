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

;; Image-based lighting, baked on the GPU: the two precomputations
;; that turn a cube map into a physically-plausible light probe.
;;
;;   (define lut (ibl-brdf-lut!))            ; once, ~a millisecond
;;   (define env (ibl-prefilter! sky 64 6))  ; once per sky
;;   ... per frame:
;;   (cmd-bind-cubemap! 0 env)
;;   (cmd-bind-texture! 1 lut)
;;   (fx-uniform! p 'u_sky 0) (fx-uniform! p 'u_lut 1) ...
;;
;; ibl-prefilter! renders a NEW cube map whose mip chain holds the
;; source environment convolved with GGX at increasing roughness --
;; level 0 is a mirror, the last level is nearly diffuse -- so a
;; shader picks its reflection blur with one textureCube bias.
;; ibl-brdf-lut! bakes the split-sum BRDF integration (scale and
;; bias over NdotV x roughness) into a 2D texture.  Both use
;; Fibonacci-spiral GGX importance sampling (no bit tricks, so the
;; shaders stay ESSL 1.00), after Karis' split-sum approximation.
;;
;; mesh-pbr-vs/-fs in (gfx mesh) consume exactly these two.
;;
(library (gfx ibl)
  (export ibl-brdf-lut! ibl-prefilter! ibl-shaders)
  (import (rnrs) (gfx gl) (gfx glsl) (gfx fx))

  ;; GGX importance sample k of n around +z, for alpha = r*r:
  ;; a Fibonacci spiral supplies the (u, phi) sequence
  (define $ggx-sample
    '((define (ggx_h (float k) (float n) (float a)) vec3
        (local float u (/ (+ k (fl 0 50)) n))
        (local float phi (* k "2.3999632"))
        (local float ct (sqrt (/ (- (fl 1) u)
                                 (+ (fl 1) (* (- (* a a) (fl 1)) u)))))
        (local float st (sqrt (max (- (fl 1) (* ct ct)) (fl 0))))
        (return (vec3 (* st (cos phi)) (* st (sin phi)) ct)))))

  ;; ---- the environment prefilter ----
  ;; one pass per face x level; u_face picks the cube face the
  ;; fragment looks through, u_rough the GGX width
  (define $prefilter-fs
    (append
     '((precision mediump float)
       (uniform samplerCube u_src)
       (uniform float u_face)
       (uniform float u_rough)
       (uniform float u_dim))
     $ggx-sample
     '((define (face_dir (float f) (float a) (float b)) vec3
         (if (< f (fl 0 50)) (return (vec3 (fl 1) (- b) (- a))))
         (if (< f (fl 1 50)) (return (vec3 (- (fl 1)) (- b) a)))
         (if (< f (fl 2 50)) (return (vec3 a (fl 1) b)))
         (if (< f (fl 3 50)) (return (vec3 a (- (fl 1)) (- b))))
         (if (< f (fl 4 50)) (return (vec3 a (- b) (fl 1))))
         (return (vec3 (- a) (- b) (- (fl 1)))))
       (define (main) void
         (local vec2 uv (- (* (/ gl_FragCoord.xy u_dim) (fl 2))
                           (vec2 (fl 1) (fl 1))))
         (local vec3 n (normalize (face_dir u_face uv.x uv.y)))
         ;; a tangent frame around n
         (local vec3 up (vec3 (fl 0) (fl 0) (fl 1)))
         (if (> (abs n.z) "0.999") (set! up (vec3 (fl 1) (fl 0) (fl 0))))
         (local vec3 tx (normalize (cross up n)))
         (local vec3 ty (cross n tx))
         (local vec3 acc (vec3 (fl 0) (fl 0) (fl 0)))
         (local float wsum (fl 0))
         (for (int i 0 (< i 32) (+ i 1))
           (local vec3 h (ggx_h (float i) "32.0" (* u_rough u_rough)))
           (local vec3 hw (normalize (+ (+ (* tx h.x) (* ty h.y))
                                        (* n h.z))))
           (local vec3 l (normalize (- (* hw (* (fl 2) (dot n hw))) n)))
           (local float nl (dot n l))
           (if (> nl (fl 0))
               (local vec4 c (textureCube u_src l))
               (set! acc (+ acc (* c.rgb nl)))
               (set! wsum (+ wsum nl))))
         (set! gl_FragColor (vec4 (/ acc (max wsum "0.001")) (fl 1)))))))

  ;; prefilter the cube map in `src-slot` (dim x dim faces) into a
  ;; fresh cube map with `levels` GGX-convolved mips; returns its slot
  (define (ibl-prefilter! src-slot dim levels)
    (let ((dst (fx-slot!))
          (q (fx-fullscreen! $prefilter-fs)))
      (gl-cubemap-empty! dst dim levels)
      (cmd-begin!)
      (let level ((l 0) (ldim dim))
        (when (< l levels)
          (let ((rough (if (= levels 1)
                           0.0
                           (fl/ (fixnum->flonum l)
                                (fixnum->flonum (- levels 1))))))
            (let face ((f 0))
              (when (< f 6)
                (let ((fb (fx-slot!)))
                  (gl-cube-face-fb! fb dst f l)
                  (cmd-bind-target! fb)
                  (cmd-viewport! 0 0 ldim ldim)
                  (fx-fullscreen-use! q 0.0)
                  (cmd-bind-cubemap! 0 src-slot)
                  (let ((p (fx-quad-program q)))
                    (fx-uniform! p 'u_src 0)
                    (fx-uniform! p 'u_face (fixnum->flonum f))
                    (fx-uniform! p 'u_rough rough)
                    (fx-uniform! p 'u_dim (fixnum->flonum ldim)))
                  (fx-fullscreen-draw! q))
                (face (+ f 1)))))
          (level (+ l 1) (quotient ldim 2))))
      (cmd-bind-canvas!)
      (cmd-flush!)
      dst))

  ;; ---- the split-sum BRDF lookup table ----
  ;; x = NdotV, y = roughness; out r = F0 scale, g = bias
  (define $lut-fs
    (append
     '((precision mediump float)
       (uniform float u_dim))
     $ggx-sample
     '((define (main) void
         (local vec2 uv (/ gl_FragCoord.xy u_dim))
         (local float nv (max uv.x "0.004"))
         (local float rough uv.y)
         (local float a (* rough rough))
         (local vec3 v (vec3 (sqrt (max (- (fl 1) (* nv nv)) (fl 0)))
                             (fl 0) nv))
         (local float sa (fl 0))
         (local float sb (fl 0))
         (for (int i 0 (< i 64) (+ i 1))
           (local vec3 h (ggx_h (float i) "64.0" a))
           (local vec3 l (- (* h (* (fl 2) (dot v h))) v))
           (local float nl l.z)
           (if (> nl (fl 0))
               (local float nh (max h.z (fl 0)))
               (local float vh (max (dot v h) (fl 0)))
               ;; Smith-Schlick G, IBL flavor (k = a/2)
               (local float kk (/ a (fl 2)))
               (local float g (* (/ nl (+ (* nl (- (fl 1) kk)) kk))
                                 (/ nv (+ (* nv (- (fl 1) kk)) kk))))
               (local float gv (/ (* g vh) (max (* nh nv) "0.001")))
               (local float fc (pow (- (fl 1) vh) (fl 5)))
               (set! sa (+ sa (* gv (- (fl 1) fc))))
               (set! sb (+ sb (* gv fc)))))
         (set! gl_FragColor (vec4 (/ sa "64.0") (/ sb "64.0")
                                  (fl 0) (fl 1)))))))

  ;; bake the LUT once; returns the texture slot to bind and sample
  ;; with (NdotV, roughness)
  (define (ibl-brdf-lut!)
    (let ((tgt (fx-target! 256 256))
          (q (fx-fullscreen! $lut-fs)))
      (cmd-begin!)
      (fx-bind-target! tgt)
      (fx-fullscreen-use! q 0.0)
      (fx-uniform! (fx-quad-program q) 'u_dim 256.0)
      (fx-fullscreen-draw! q)
      (cmd-bind-canvas!)
      (cmd-flush!)
      (fx-target-texture tgt)))
  ;; ---- the shaders this library compiles, as data ----
  ;;
  ;; Each entry is (name dialect vertex-forms fragment-forms): the name
  ;; is a symbol, the dialect is es100 or es300 and says which renderer
  ;; to use (glsl->string, or the glsl300-* pair), and either shader
  ;; may be #f where this library does not supply one.
  ;;
  ;; The dialect travels IN THE DATA rather than in a comment, because
  ;; a caller that has to look up which renderer a shader wants is a
  ;; caller that will eventually look up the wrong one.
  ;;
  ;; These exist so a shader can be handed to a real GLSL compiler
  ;; without going through a GL context: the page verifier's GL is a
  ;; stub whose compileShader does nothing, so a shader that is only
  ;; ever compiled there is never compiled at all.
  ;; Both run through fx-fullscreen!, which supplies the quad vertex
  ;; shader, so the vertex half is #f here.
  ;;
  ;; !! $ggx-sample is deliberately NOT listed.  It is a set of helper
  ;; FUNCTIONS spliced into the shaders below, not a shader: it has no
  ;; main, and compiling it on its own would fail forever.  A permanent
  ;; red in a checking table teaches people to ignore the table, so the
  ;; omission is recorded here instead of being discovered later.
  (define (ibl-shaders)
    (list (list 'prefilter 'es100 #f $prefilter-fs)
          (list 'brdf-lut 'es100 #f $lut-fs)))
)
