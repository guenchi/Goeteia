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

(define (sub-at s sub)   ; position of the first occurrence, or #f
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) i)
            (else (loop (+ i 1)))))))
(define (contains? s sub)
  (let ((sl (string-length s)) (bl (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i bl) sl) #f)
            ((string=? (substring s i (+ i bl)) sub) #t)
            (else (loop (+ i 1)))))))

(define (attr-bytes forms)
  (fold-left (lambda (n a) (+ n (* 4 (caddr a))))
             0 (glsl-attributes forms)))

;; full (type name) pairs -- glsl-varyings returns names only, and a
;; name-level match would bless (varying vec2 v_normal) against an fs
;; that declares vec3: real WebGL refuses to link that.
(define (varying-schema forms)
  (let loop ((fs forms) (acc '()))
    (cond ((null? fs) (reverse acc))
          ((and (pair? (car fs)) (eq? (caar fs) 'varying))
           (let ((d (car fs)))               ; (varying type name)
             (loop (cdr fs)
                   (cons (list (cadr d) (caddr d)) acc))))
          (else (loop (cdr fs) acc)))))

;; ---- the normal-mapped static shader, skinned ----
(define sk-nmap (gltf-skin-shader mesh-normal-vs))
(define nmap-src (glsl->string sk-nmap))

;; ---- normals ride the cofactor matrix, tangents keep their handedness ----
;; A normal is a covector: under a joint that scales unevenly or
;; mirrors it must move by the cofactor matrix of the blended joint
;; matrix (columns cross(c1,c2) cross(c2,c0) cross(c0,c1)), signed by
;; the determinant, then normalized when it has a length; the tangent
;; keeps riding the matrix itself and its w flips with the
;; determinant.  test/gltf-skin-normals.ss pins the CPU numbers; this
;; pins the shader text that must compute the same thing.
(define (count-sub s sub)
  (let loop ((i 0) (n 0))
    (let ((k (sub-at (substring s i (string-length s)) sub)))
      (if k (loop (+ i k 1) (+ n 1)) n))))
(define normal-matrix-ok
  (and (>= (count-sub nmap-src "cross(") 3)                 ; the three cofactor columns
       (not (contains? nmap-src "g_skin * vec4(a_normal"))  ; the old, wrong transform
       (contains? nmap-src "normalize(")                    ; unit length on the way out
       (contains? nmap-src "> 0.0")                         ; ...only when there is a length
       (contains? nmap-src "< 0.0 ? -1.0 : 1.0")            ; handedness from the determinant's sign
       (contains? nmap-src "a_tangent.w")))


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
       ;; the varying interface survives: same fs still pairs --
       ;; types included, or the real linker would refuse the pair
       (equal? (varying-schema sk-nmap) (varying-schema mesh-normal-vs))
       (equal? (varying-schema sk-nmap) (varying-schema mesh-normal-fs))))

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
;; (a_uv is the padding slot the loader always emits for skinned
;; layouts -- see the no-uv case below)
(define weird-ok
  (equal? (map car (glsl-attributes (gltf-skin-shader weird)))
          '(a_pos a_normal a_uv a_joints a_weights)))

;; ---- a static shader without a_uv still matches the loader ----
;; the interleave carries a uv slot for every skinned layout, so the
;; combinator supplies the padding attribute rather than producing a
;; program the loader can never feed.
(define no-uv-ok
  (and (equal? (map car (glsl-attributes
                         (gltf-skin-shader mesh-lit-vs)))
               '(a_pos a_normal a_uv a_joints a_weights))
       (= (attr-bytes (gltf-skin-shader mesh-lit-vs)) 64)))

;; the padding goes where the interleave puts it -- right after
;; normal -- not merely at the end: a shader with tangent but no uv
;; would otherwise get (pos normal tangent uv ...) and never match
(define no-uv-order-ok
  (equal? (map car (glsl-attributes
                    (gltf-skin-shader
                     '((attribute vec3 a_pos)
                       (attribute vec3 a_normal)
                       (attribute vec4 a_tangent)
                       (uniform mat4 u_mvp)
                       (varying vec3 v_t)
                       (define (main) void
                         (set! gl_Position
                               (* u_mvp (vec4 a_pos (fl 1))))
                         (set! v_t (+ a_normal a_tangent.xyz)))))))
          '(a_pos a_normal a_uv a_tangent a_joints a_weights)))

;; the built-in skinned shader must carry u_model like the composed
;; ones do: gltf-draw! folds an optional root into u_mvp, and only a
;; program declaring u_model gets the root applied to its normals
;; too -- without it a rotated root turns the model on screen while
;; the lighting stays put.
(define builtin-has-model-ok
  (and (assq 'u_model (glsl-uniforms gltf-skin-vs))
       ;; the normal actually goes through it
       (contains? (glsl->string gltf-skin-vs) "u_model * vec4(g_normal")
       ;; and it still pairs with mesh-tex-fs, so the varyings must
       ;; match that shader's -- deriving it from a source without
       ;; v_uv would leave the fragment stage without its input, and
       ;; a type drift (vec2 v_normal) would fail the real linker
       (equal? (varying-schema gltf-skin-vs) (varying-schema mesh-tex-vs))
       (equal? (varying-schema gltf-skin-vs) (varying-schema mesh-tex-fs))))

(define (errors? thunk)
  (guard (e (#t #t)) (thunk) #f))

;; ---- widths matter as much as names ----
;; the loader gives COLOR_0 16 bytes whatever the accessor said (a
;; VEC3 colour fills alpha with 1), so a shader declaring vec3
;; a_color computes a 76-byte stride against the loader's 80 and
;; misreads every vertex past the first.  Names alone cannot catch
;; that, so the canonical attributes carry a type contract.
(define width-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec3 a_normal)
                     (attribute vec2 a_uv)
                     (attribute vec3 a_color)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec2 a_pos)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 0) (fl 1))))))))
       ;; every canonical slot, not just the two that prompted this
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos) (attribute vec4 a_normal)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos) (attribute vec3 a_normal)
                     (attribute vec3 a_uv)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos) (attribute vec3 a_normal)
                     (attribute vec2 a_uv) (attribute vec3 a_tangent)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       ;; the right widths still compose
       (equal? (map car
                    (glsl-attributes
                     (gltf-skin-shader
                      '((attribute vec3 a_pos)
                        (attribute vec3 a_normal)
                        (attribute vec2 a_uv)
                        (attribute vec4 a_color)
                        (define (main) void
                          (set! gl_Position (vec4 a_pos (fl 1))))))))
               '(a_pos a_normal a_uv a_color a_joints a_weights))))

;; ---- the after-main rule only binds attributes the loader feeds ----
;; a caller's own attribute is not read by the injected body, does
;; not take part in padding, and is fed from elsewhere -- refusing
;; it contradicts the rule two lines up that leaves such names alone
(define after-main-scope-ok
  (and (guard (e (#t #f))
         (equal? (map car
                      (glsl-attributes
                       (gltf-skin-shader
                        '((attribute vec3 a_pos)
                          (uniform mat4 u_mvp)
                          (define (main) void
                            (set! gl_Position
                                  (* u_mvp (vec4 a_pos (fl 1)))))
                          (attribute vec3 a_custom)))))
                 '(a_pos a_normal a_uv a_joints a_weights a_custom)))
       ;; ... while a canonical one after main is still refused
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (uniform mat4 u_mvp)
                     (define (main) void
                       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1)))))
                     (attribute vec3 a_normal)))))))

;; only MAIN bounds where the injected globals go -- a helper
;; function declared ahead of the attributes is legal GLSL and must
;; still compose (an earlier bound on "the first define" made the
;; whole joints injection vanish for this input)
(define helper-first-ok
  (equal? (map car (glsl-attributes
                    (gltf-skin-shader
                     '((define (bump (in float x)) float
                         (return (+ x (fl 1))))
                       (attribute vec3 a_pos)
                       (attribute vec3 a_normal)
                       (attribute vec2 a_uv)
                       (uniform mat4 u_mvp)
                       (define (main) void
                         (set! gl_Position
                               (* u_mvp (vec4 a_pos (fl 1)))))))))
          '(a_pos a_normal a_uv a_joints a_weights)))

;; ... and NO attribute may follow main: main's injected body reads
;; a_pos/a_normal/a_tangent, and the padding lands next to whichever
;; of them the input declares, so an attribute after main puts a
;; declaration after its use
(define attrs-before-main-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader
                   '((define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))
                     (attribute vec3 a_pos)))))
       ;; a_pos before main is not enough: a_normal after it still
       ;; ends up declared below the g_normal that reads it
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (uniform mat4 u_mvp)
                     (define (main) void
                       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1)))))
                     (attribute vec3 a_normal)))))))

;; ---- injected names must be free in the input ----
;; the loader writes a +Y normal even when the asset has none, so
;; every skinned layout carries a normal slot: a position-only
;; shader needs that padding too, not just the uv one
(define no-normal-ok
  (equal? (map car (glsl-attributes
                    (gltf-skin-shader
                     '((attribute vec3 a_pos)
                       (uniform mat4 u_mvp)
                       (define (main) void
                         (set! gl_Position
                               (* u_mvp (vec4 a_pos (fl 1)))))))))
          '(a_pos a_normal a_uv a_joints a_weights)))

;; GLSL shares one top-level namespace across storage classes, so a
;; name taken by a uniform blocks the attribute this injects (and
;; vice versa)
(define cross-class-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec3 a_normal)
                     (uniform vec2 a_uv)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec4 u_joints)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (varying vec4 a_weights)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       ;; an anonymous uniform block puts its members in the global
       ;; scope too, so they take the name just as a plain uniform
       ;; would
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (uniform-block Env (mat4 u_joints))
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))))

;; a function name lives in the same namespace as the injected
;; uniform, and the g_* locals injected into main must be free too
(define name-space-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (uniform mat4 u_mvp)
                     (define (u_joints) float (return (fl 1)))
                     (define (main) void
                       (set! gl_Position
                             (* u_mvp (vec4 a_pos (fl 1)))))))))
       ;; all four reserved locals, not just the first
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (define (main) void
                       (local float g_skin (fl 2))
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (define (main) void
                       (local vec3 g_pos (vec3 (fl 1) (fl 1) (fl 1)))
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec3 a_normal)
                     (define (main) void
                       (local vec3 g_normal a_normal)
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (varying vec4 g_tangent)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))))

;; every global main uses is declared before it -- the injected
;; ones included (an input with an attribute after main is refused
;; outright, see attrs-before-main-ok)
(define decl-order-ok
  (let* ((src (glsl->string
               (gltf-skin-shader
                '((attribute vec3 a_pos)
                  (attribute vec3 a_normal)
                  (attribute vec2 a_uv)
                  (uniform mat4 u_mvp)
                  (define (main) void
                    (set! gl_Position (* u_mvp (vec4 a_pos (fl 1)))))))))
         (main-at (let loop ((i 0))
                    (cond ((> (+ i 9) (string-length src)) -1)
                          ((string=? (substring src i (+ i 9))
                                     "void main")
                           i)
                          (else (loop (+ i 1))))))
         (decl-at (let loop ((i 0))
                    (cond ((> (+ i 8) (string-length src)) -1)
                          ((string=? (substring src i (+ i 8))
                                     "a_joints")
                           i)
                          (else (loop (+ i 1)))))))
    (and (> main-at 0) (> decl-at 0) (< decl-at main-at))))

;; the loader's interleave is a fixed order; a shader declaring the
;; same attributes in another order can never match it, so say so
;; at compose time rather than handing back a program that only
;; fails once something tries to draw with it
(define canonical-order-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec4 a_color)
                     (attribute vec4 a_tangent)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       ;; an attribute of the caller's own is not the loader's
       ;; business: it composes, and gltf-draw! is what refuses to
       ;; feed the resulting program
       (equal? (map car
                    (glsl-attributes
                     (gltf-skin-shader
                      '((attribute vec3 a_pos)
                        (attribute vec3 a_custom)
                        (define (main) void
                          (set! gl_Position (vec4 a_pos (fl 1))))))))
               '(a_pos a_normal a_uv a_custom a_joints a_weights))
       ;; the second UV set is the interleave's TRAILING slot, after the
       ;; skin inputs: a static shader that reads a_uv1 must compose to
       ;; that order, or gltf-draw! refuses the program against the
       ;; layout `... joints weights uv1` the reader builds
       (equal? (map car
                    (glsl-attributes
                     (gltf-skin-shader
                      '((attribute vec3 a_pos)
                        (attribute vec2 a_uv1)
                        (define (main) void
                          (set! gl_Position (vec4 a_pos (fl 1))))))))
               '(a_pos a_normal a_uv a_joints a_weights a_uv1))
       ;; ...and moving it must not move it out of sight: a helper
       ;; declared between a_uv1 and a later attribute reads a_uv1, so
       ;; the composed source has to declare a_uv1 BEFORE that helper.
       ;; Attribute declarations may be hoisted; a helper may not be
       ;; read before its inputs exist.
       (let* ((src (glsl->string
                    (gltf-skin-shader
                     '((attribute vec3 a_pos)
                       (attribute vec2 a_uv1)
                       (define (second_uv) vec2 (return a_uv1))
                       (attribute vec3 a_custom)
                       (define (main) void
                         (set! gl_Position (vec4 a_pos (fl 1))))))))
              (decl (sub-at src "attribute vec2 a_uv1"))
              (use (sub-at src "second_uv")))
         (and decl use (< decl use)))
       ;; ...but never across a default-precision statement: an
       ;; attribute keeps the precision in effect where it was written.
       ;; Hoisting is per precision segment.
       (let* ((src (glsl->string
                    (gltf-skin-shader
                     '((precision lowp float)
                       (attribute vec3 a_pos)
                       (precision highp float)
                       (attribute vec3 a_normal)
                       (attribute vec2 a_uv)
                       (define (main) void
                         (set! gl_Position (vec4 a_pos (fl 1))))))))
              (lowp (sub-at src "precision lowp float"))
              (pos (sub-at src "a_pos"))
              (highp (sub-at src "precision highp float"))
              (nrm (sub-at src "a_normal"))
              (joints (sub-at src "attribute vec4 a_joints")))
         (and lowp pos highp nrm joints
              (< lowp pos) (< pos highp) (< highp nrm) (< nrm joints)))
       ;; a_uv1's own move must not change ITS precision either: moved
       ;; from under highp to a tail that sits under lowp, it is
       ;; re-declared under its original precision, and the tail's
       ;; precision is restored after it for whatever follows
       (let* ((src (glsl->string
                    (gltf-skin-shader
                     '((precision highp float)
                       (attribute vec3 a_pos)
                       (attribute vec2 a_uv1)
                       (precision lowp float)
                       (attribute vec3 a_custom)
                       (define (main) void
                         (set! gl_Position (vec4 a_pos (fl 1))))))))
              (uv1 (sub-at src "attribute vec2 a_uv1"))
              (main (sub-at src "void main"))
              ;; the last precision statement before a position
              (last-before (lambda (pos word)
                             (let loop ((i 0) (last #f))
                               (let ((k (sub-at (substring src i (string-length src)) word)))
                                 (if (or (not k) (>= (+ i k) pos)) last
                                     (loop (+ i k 1) (+ i k))))))))
         (and uv1 main
              (let ((hp (last-before uv1 "precision highp float"))
                    (lp (last-before uv1 "precision lowp float")))
                (and hp (or (not lp) (< lp hp))))          ; a_uv1 sits under highp
              (let ((lp2 (last-before main "precision lowp float")))
                (and lp2 (> lp2 uv1)))))                     ; and lowp is back before main
       ;; an a_uv1 declared after main is an attribute after main like
       ;; any other: refused, not relocated into a precision it cannot
       ;; name
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))
                     (precision mediump float)
                     (attribute vec2 a_uv1)))))
       ;; no precision statement at all means highp in a vertex shader,
       ;; so moving a_uv1 from "none" to an explicit highp adds nothing:
       ;; the composed source carries exactly the one statement written
       (let* ((src (glsl->string
                    (gltf-skin-shader
                     '((attribute vec3 a_pos)
                       (attribute vec2 a_uv1)
                       (precision highp float)
                       (attribute vec3 a_custom)
                       (define (main) void
                         (set! gl_Position (vec4 a_pos (fl 1))))))))
              (count (lambda (word)
                       (let loop ((i 0) (n 0))
                         (let ((k (sub-at (substring src i (string-length src)) word)))
                           (if k (loop (+ i k 1) (+ n 1)) n))))))
         (= (count "precision") 1))
       ;; a_uv1 has one width, vec2, and the combinator checks it at
       ;; compose time like the other seven names it knows
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec3 a_uv1)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       ;; the corner neither rule can serve -- a_uv1 read by a helper
       ;; that a precision statement pins ahead of a later attribute --
       ;; is refused by name at compose time, not composed wrong
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec2 a_uv1)
                     (define (second_uv) vec2 (return a_uv1))
                     (precision highp float)
                     (attribute vec3 a_custom)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       ;; ... while the canonical order composes fine
       (equal? (map car
                    (glsl-attributes
                     (gltf-skin-shader
                      '((attribute vec3 a_pos)
                        (attribute vec4 a_tangent)
                        (attribute vec4 a_color)
                        (define (main) void
                          (set! gl_Position (vec4 a_pos (fl 1))))))))
               '(a_pos a_normal a_uv a_tangent a_color
                 a_joints a_weights))))

(define collision-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (attribute vec4 a_joints)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       (errors? (lambda ()
                  (gltf-skin-shader
                   '((attribute vec3 a_pos)
                     (uniform (array mat4 8) u_joints)
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))))

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

(and builtin-has-model-ok nmap-ok tex-ok weird-ok no-uv-ok no-uv-order-ok no-normal-ok
     cross-class-ok name-space-ok decl-order-ok canonical-order-ok
     width-ok after-main-scope-ok
     helper-first-ok attrs-before-main-ok
     collision-ok near-ok degenerate-ok normal-matrix-ok)
