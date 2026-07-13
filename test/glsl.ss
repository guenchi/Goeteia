;; expect: #t
;; (web glsl): s-expressions -> GLSL source. Pure, fully verifiable.
(import (rnrs) (web glsl))

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
 ;; array uniforms and indexing, for skinning
 (t (glsl->string '((uniform (array mat4 32) u_joints)))
    "uniform mat4 u_joints[32]; ")
 (t (glsl->string '((define (main) void
                      (set! m (at u_joints (int j.x))))))
    "void main() { m = u_joints[int(j.x)]; } ")
 (equal? (glsl-uniforms '((uniform (array mat4 32) u_joints)))
         '((u_joints (array mat4 32)))))
