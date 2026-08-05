;; expect: #t
;; gltf-skin-shader: the skin combinator over static vertex shaders.
;; Skinning is one orthogonal dimension, not a hand-written shader
;; variant: the combinator appends a_joints/a_weights after the
;; static attributes (the loader's canonical interleave order), adds
;; the u_joints palette, and rewrites a_pos / a_normal / a_tangent
;; references (swizzles included) to read the skin-transformed
;; values.  The result declares the same varyings, so it pairs with
;; the very fragment shader the static program used.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf))

(define (contains? s sub)
  (let ((sl (string-length s)) (bl (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i bl) sl) #f)
            ((string=? (substring s i (+ i bl)) sub) #t)
            (else (loop (+ i 1)))))))

(define (attr-bytes forms)
  (fold-left (lambda (n a) (+ n (* 4 (caddr a))))
             0 (glsl-attributes forms)))

;; ---- the normal-mapped static shader, skinned ----
(define sk-nmap (gltf-skin-shader mesh-normal-vs))
(define nmap-src (glsl->string sk-nmap))

(define nmap-ok
  (and (equal? (map car (glsl-attributes sk-nmap))
               '(a_pos a_normal a_uv a_tangent a_joints a_weights))
       ;; = the loader's skinned+tangent interleave
       (= (attr-bytes sk-nmap) 80)
       (contains? nmap-src "u_joints")
       ;; every static reference rewrote to the transformed locals
       ;; (a_pos itself survives only inside the g_pos local)
       (contains? nmap-src "vec4(g_pos")
       (contains? nmap-src "vec4(g_normal")
       (contains? nmap-src "g_tangent.xyz")
       (contains? nmap-src "g_tangent.w")
       ;; the varying interface survives: same fs still pairs
       (equal? (glsl-varyings sk-nmap) (glsl-varyings mesh-normal-vs))))

;; ---- the plain textured shader, skinned: same layout as the
;; hand-written gltf-skin-vs it generalizes ----
(define sk-tex (gltf-skin-shader mesh-tex-vs))

(define tex-ok
  (and (equal? (map car (glsl-attributes sk-tex))
               (map car (glsl-attributes gltf-skin-vs)))
       (= (attr-bytes sk-tex) 64)
       (string? (glsl->string sk-tex))))

;; ---- attributes need not be contiguous: a_joints/a_weights must
;; land after the LAST one, not after the first run ----
(define weird
  '((attribute vec3 a_pos)
    (uniform mat4 u_mvp)
    (attribute vec3 a_normal)
    (varying vec3 v_n)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (set! v_n a_normal))))
(define weird-ok
  (equal? (map car (glsl-attributes (gltf-skin-shader weird)))
          '(a_pos a_normal a_joints a_weights)))

;; ---- near-prefix attribute names survive untouched ----
(define near-prefix
  '((attribute vec3 a_pos)
    (attribute vec3 a_position2)
    (uniform mat4 u_mvp)
    (varying vec3 v_x)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (set! v_x a_position2))))
(define near-src (glsl->string (gltf-skin-shader near-prefix)))
(define near-ok
  (and (contains? near-src "a_position2")
       (not (contains? near-src "g_position2"))))

;; ---- degenerate inputs fail loudly, not with broken GLSL ----
(define (errors? thunk)
  (guard (e (#t #t)) (thunk) #f))
(define degenerate-ok
  (and
   ;; no a_pos at all
   (errors? (lambda ()
              (gltf-skin-shader
               '((attribute vec3 a_dir)
                 (define (main) void
                   (set! gl_Position (vec4 a_dir (fl 1))))))))
   ;; an attribute read from a helper: g_* locals live in main, so
   ;; the rewrite cannot reach it -- refuse instead of miscompiling
   (errors? (lambda ()
              (gltf-skin-shader
               '((attribute vec3 a_pos)
                 (define (twice) vec3
                   (return (* a_pos (fl 2))))
                 (define (main) void
                   (set! gl_Position (vec4 a_pos (fl 1))))))))))

(and nmap-ok tex-ok weird-ok near-ok degenerate-ok)
