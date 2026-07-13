;; expect: #t
;; (gfx glsl): s-expressions -> GLSL source. Pure, fully verifiable.
(import (rnrs) (gfx glsl))

(define (t got want) (string=? got want))

(and
 ;; declarations
 (t (glsl->string '((attribute vec2 p)))
    "attribute vec2 p; ")
 (t (glsl->string '((precision mediump float) (uniform float u_time)))
    "precision mediump float; uniform float u_time; ")
 ;; float literals: whole + fraction-in-hundredths, no Scheme flonums
 (t (glsl->string '((define (main) void (set! x (fl 2)))))
    "void main() { x = 2.0; } ")
 (t (glsl->string '((define (main) void (set! x (fl 0 50)))))
    "void main() { x = 0.5; } ")
 (t (glsl->string '((define (main) void (set! x (fl 1 25)))))
    "void main() { x = 1.25; } ")
 (t (glsl->string '((define (main) void (set! x (fl 0 5)))))
    "void main() { x = 0.05; } ")
 ;; infix arithmetic, unary minus, calls, swizzles pass through
 (t (glsl->string '((define (main) void
                      (set! gl_Position (vec4 (* p.x (fl 2)) (- p.y) (fl 0) (fl 1))))))
    "void main() { gl_Position = vec4((p.x * 2.0), (-p.y), 0.0, 1.0); } ")
 ;; locals, comparison, if/else, discard
 (t (glsl->string '((define (main) void
                      (local float d (distance v (vec2 (fl 0) (fl 0))))
                      (if (> d (fl 1)) (discard))
                      (set! gl_FragColor (vec4 d d d (fl 1))))))
    (string-append
     "void main() { float d = distance(v, vec2(0.0, 0.0)); "
     "if ((d > 1.0)) { discard; } "
     "gl_FragColor = vec4(d, d, d, 1.0); } "))
 ;; a helper function with parameters and a return
 (t (glsl->string '((define (lum (vec3 c)) float
                      (return (dot c (vec3 (fl 0 30) (fl 0 59) (fl 0 11)))))))
    "float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); } ")
 ;; composition: shaders are lists -- append shared declarations
 (let ((decls '((attribute vec2 p)))
       (body '((define (main) void (set! gl_Position (vec4 p (fl 0) (fl 1)))))))
   (t (glsl->string (append decls body))
      "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); } "))
 ;; interface extraction: declarations back out as data, in order
 (equal? (glsl-attributes
          '((attribute vec2 a_pos) (uniform float u_t)
            (attribute vec4 a_tint) (varying vec2 v_uv)
            (define (main) void (set! x (fl 1)))))
         '((a_pos vec2 2) (a_tint vec4 4)))
 (equal? (glsl-uniforms
          '((precision mediump float) (uniform sampler2D u_tex)
            (attribute vec2 a_pos) (uniform vec2 u_res)
            (define (main) void (set! x (fl 1)))))
         '((u_tex sampler2D) (u_res vec2)))
 (null? (glsl-attributes '((uniform float u_t) (precision mediump float))))
 (null? (glsl-uniforms '((attribute vec2 p))))
 ;; for loops: kernel sweeps for PCF shadows and blurs.  The index
 ;; steps by += / -= because ESSL 1.00 forbids plain = on it.
 (t (glsl->string '((define (main) void
                      (for (int i 0 (< i 3) (+ i 1))
                        (set! x (+ x i))))))
    "void main() { for (int i = 0; (i < 3); i += 1) { x = (x + i); } } ")
 (t (glsl->string '((define (main) void
                      (for (int x -1 (< x 2) (+ x 1))
                        (for (int y 2 (> y 0) (- y 1))
                          (set! a (+ a (f x y))))))))
    (string-append
     "void main() { for (int x = -1; (x < 2); x += 1) { "
     "for (int y = 2; (y > 0); y -= 1) { "
     "a = (a + f(x, y)); } } } "))
 ;; array uniforms and indexing, for skinning
 (t (glsl->string '((uniform (array mat4 32) u_joints)))
    "uniform mat4 u_joints[32]; ")
 (t (glsl->string '((define (main) void
                      (set! m (at u_joints (int j.x))))))
    "void main() { m = u_joints[int(j.x)]; } ")
 (equal? (glsl-uniforms '((uniform (array mat4 32) u_joints)))
         '((u_joints (array mat4 32))))
 ;; ---- the ES 3.00 dialect: same forms, respelled ----
 (t (glsl300-vs->string
     '((attribute vec3 a_pos)
       (varying vec3 v_n)
       (uniform mat4 u_mvp)
       (define (main) void
         (set! v_n a_pos)
         (set! gl_Position (* u_mvp (vec4 a_pos (fl 1)))))))
    (string-append
     "#version 300 es\n"
     "in vec3 a_pos; out vec3 v_n; uniform mat4 u_mvp; "
     "void main() { v_n = a_pos; "
     "gl_Position = (u_mvp * vec4(a_pos, 1.0)); } "))
 (t (glsl300-fs->string
     '((precision mediump float)
       (varying vec3 v_n)
       (uniform sampler2D u_tex)
       (define (main) void
         (set! gl_FragColor (texture2D u_tex v_n.xy)))))
    (string-append
     "#version 300 es\n"
     "out highp vec4 goe_FragColor; "
     "precision mediump float; in vec3 v_n; uniform sampler2D u_tex; "
     "void main() { goe_FragColor = texture(u_tex, v_n.xy); } "))
 ;; textureCube also folds into texture()
 (t (glsl300-fs->string
     '((define (main) void (set! gl_FragColor (textureCube u_sky d)))))
    (string-append
     "#version 300 es\nout highp vec4 goe_FragColor; "
     "void main() { goe_FragColor = texture(u_sky, d); } "))
 ;; uniform blocks: the syntax UBOs need
 (t (glsl300-vs->string
     '((uniform-block Env (mat4 u_vp) (vec4 u_fog))))
    (string-append
     "#version 300 es\n"
     "layout(std140) uniform Env { highp mat4 u_vp; highp vec4 u_fog; }; "))
 ;; explicit (out ...) forms: MRT.  They pin their locations, and the
 ;; implicit goe_FragColor head disappears -- it would collide with
 ;; an explicit location 0
 (t (glsl300-fs->string
     '((precision mediump float)
       (varying vec3 v_n)
       (out 0 vec4 o_albedo)
       (out 1 vec4 o_normal)
       (define (main) void
         (set! o_albedo (vec4 (fl 1)))
         (set! o_normal (vec4 v_n (fl 0))))))
    (string-append
     "#version 300 es\n"
     "precision mediump float; in vec3 v_n; "
     "layout(location = 0) out highp vec4 o_albedo; "
     "layout(location = 1) out highp vec4 o_normal; "
     "void main() { o_albedo = vec4(1.0); "
     "o_normal = vec4(v_n, 0.0); } "))
 ;; extraction still works on the neutral forms
 (equal? (glsl-attributes '((attribute vec3 a_pos) (varying vec3 v_n)))
         '((a_pos vec3 3)))
 ;; varyings in order: the transform-feedback capture list
 (equal? (glsl-varyings '((attribute vec3 a_pos) (varying vec3 v_pos)
                          (uniform float u_dt) (varying float v_life)))
         '(v_pos v_life)))
