;; expect: #t
;; (gfx wgsl): the same shader forms (gfx glsl) renders, respelled
;; as one WGSL module -- merged uniform struct, VOut varyings,
;; entry-point rewrites -- plus the pipeline layout from the same
;; attribute declarations.  Pure strings, verified exactly.
(import (rnrs) (gfx wgsl))

(define (t got want)
  (or (string=? got want)
      (begin (display "got:  ") (display got) (newline)
             (display "want: ") (display want) (newline)
             #f)))

(define vs
  '((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    (uniform mat4 u_mvp)
    (uniform mat4 u_model)
    (varying vec3 v_n)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (local vec4 nw (* u_model (vec4 a_normal (fl 0))))
      (set! v_n nw.xyz))))
(define fs
  '((uniform mat4 u_model)               ; deduped against the VS's
    (varying vec3 v_n)
    (define (main) void
      (local float d (max (dot (normalize v_n)
                               (vec3 (fl 0 50) (fl 0 80) (fl 0 40)))
                          (fl 0)))
      (set! gl_FragColor (vec4 d d d (fl 1))))))

(and
 (t (wgsl->string vs fs)
    (string-append
     "struct U { u_mvp : mat4x4f, u_model : mat4x4f } "
     "@group(0) @binding(0) var<uniform> u : U; "
     "struct VOut { @builtin(position) goe_pos : vec4f, "
     "@location(0) v_n : vec3f } "
     "@vertex fn vs(@location(0) a_pos : vec3f, "
     "@location(1) a_normal : vec3f) -> VOut { var o : VOut; "
     "o.goe_pos = (u.u_mvp * vec4f(a_pos, 1.0)); "
     "var nw : vec4f = (u.u_model * vec4f(a_normal, 0.0)); "
     "o.v_n = nw.xyz; return o; } "
     "@fragment fn fs(vin : VOut) -> @location(0) vec4f { "
     "var goe_out : vec4f; "
     "var d : f32 = max(dot(normalize(vin.v_n), "
     "vec3f(0.50, 0.80, 0.40)), 0.0); "
     "goe_out = vec4f(d, d, d, 1.0); return goe_out; } "))
 ;; the layout: stride and formats off the attribute declarations
 (equal? (wgsl-layout vs) '(24 . "float32x3,float32x3"))
 ;; helpers travel; for loops respell as var; a fragment-only module
 (t (wgsl->string
     '((attribute vec2 a_pos)
       (define (main) void
         (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
     '((define (twice (float x)) float
         (return (* x (fl 2))))
       (define (main) void
         (local float acc (fl 0))
         (for (int i 0 (< i 4) (+ i 1))
           (set! acc (+ acc (twice (float i)))))
         (if-else (< acc (fl 6))
           ((set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1))))
           ((set! gl_FragColor (vec4 acc acc acc (fl 1))))))))
    (string-append
     "struct VOut { @builtin(position) goe_pos : vec4f } "
     "fn twice(x : f32) -> f32 { return (x * 2.0); } "
     "@vertex fn vs(@location(0) a_pos : vec2f) -> VOut { "
     "var o : VOut; "
     "o.goe_pos = vec4f(a_pos, 0.0, 1.0); return o; } "
     "@fragment fn fs(vin : VOut) -> @location(0) vec4f { "
     "var goe_out : vec4f; "
     "var acc : f32 = 0.0; "
     "for (var i : i32 = 0; (i < 4); i = (i + 1)) { "
     "acc = (acc + twice(f32(i))); } "
     "if ((acc < 6.0)) { goe_out = vec4f(1.0, 0.0, 0.0, 1.0); } "
     "else { goe_out = vec4f(acc, acc, acc, 1.0); } "
     "return goe_out; } "))
 ;; a sampler2D splits into a sampler + texture pair after the
 ;; struct, and texture2D respells as textureSample
 (t (wgsl->string
     '((attribute vec2 a_pos)
       (uniform mat4 u_mvp)
       (varying vec2 v_uv)
       (define (main) void
         (set! v_uv a_pos)
         (set! gl_Position (* u_mvp (vec4 a_pos (fl 0) (fl 1))))))
     '((uniform sampler2D u_tex)
       (varying vec2 v_uv)
       (define (main) void
         (set! gl_FragColor (texture2D u_tex v_uv)))))
    (string-append
     "struct U { u_mvp : mat4x4f } "
     "@group(0) @binding(0) var<uniform> u : U; "
     "@group(0) @binding(1) var u_tex_s : sampler; "
     "@group(0) @binding(2) var u_tex_t : texture_2d<f32>; "
     "struct VOut { @builtin(position) goe_pos : vec4f, "
     "@location(0) v_uv : vec2f } "
     "@vertex fn vs(@location(0) a_pos : vec2f) -> VOut { "
     "var o : VOut; "
     "o.v_uv = a_pos; "
     "o.goe_pos = (u.u_mvp * vec4f(a_pos, 0.0, 1.0)); return o; } "
     "@fragment fn fs(vin : VOut) -> @location(0) vec4f { "
     "var goe_out : vec4f; "
     "goe_out = textureSample(u_tex_t, u_tex_s, vin.v_uv); "
     "return goe_out; } ")))
