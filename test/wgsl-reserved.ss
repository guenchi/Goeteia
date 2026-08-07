;; expect: #t
;; (gfx wgsl): WGSL's own reserved words are rejected where a name is
;; introduced.  The DSL passes identifiers through verbatim, so a
;; local named `let' or a uniform named `var' used to become a module
;; the browser refuses to create -- no pipeline, no draw, and no
;; Scheme-side error.  These cases pin the generation-time check:
;; which names are refused, at which declaration positions, what the
;; message says, and -- the half that matters just as much -- that
;; the table is WGSL's and not GLSL's respelled.
(import (rnrs) (gfx wgsl) (gfx glsl) (gfx mesh))

(define (has-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

;; a rejection must name the identifier -- in the message a human
;; reads and in the irritants a caller can match on -- and must say
;; which kind of declaration introduced it
(define (rejected? thunk name kind)
  (guard (e ((error? e)
             (and (memq name (condition-irritants e))
                  (has-sub? (condition-message e) (symbol->string name))
                  (has-sub? (condition-message e) kind)))
            (else #f))
    (begin (thunk) #f)))

;; renders, and renders something: a name wrongly refused shows up
;; as #f here rather than as an uncaught error
(define (ok? thunk)
  (guard (e (#t #f))
    (let ((s (thunk))) (and (string? s) (> (string-length s) 0)))))

(define (trivial-vs)                    ; a vertex half that is never
  '((attribute vec2 a_pos)              ; the subject of a case
    (define (main) void
      (set! gl_Position (vec4 a_pos (fl 0) (fl 1))))))

(define (fs-with . stmts)               ; a fragment shader around one
  (list (append '(define (main) void) stmts)))    ; statement

(define (render-fs . stmts)             ; ... rendered as a module
  (lambda () (wgsl->string (trivial-vs) (apply fs-with stmts))))

(define (all? f xs)
  (or (null? xs) (and (f (car xs)) (all? f (cdr xs)))))

;; a compute module around one extra top-level form
(define (compute-with f)
  (lambda ()
    (wgsl-compute->string
     (list f '(workgroup 64)
           '(define (main) void (local uint i gid.x))))))

(and
 ;; ---- locals: every WGSL declaration keyword is a trap here ----
 (rejected? (render-fs '(local float let (fl 1))) 'let "local variable")
 (rejected? (render-fs '(local float var (fl 1))) 'var "local variable")
 (rejected? (render-fs '(local float fn (fl 1))) 'fn "local variable")
 (rejected? (render-fs '(local float loop (fl 1))) 'loop "local variable")
 (rejected? (render-fs '(local vec4 alias (fl 1))) 'alias "local variable")
 (rejected? (render-fs '(local float override (fl 1)))
            'override "local variable")
 ;; reserved words, not keywords -- the second table row
 (rejected? (render-fs '(local float mut (fl 1))) 'mut "local variable")
 (rejected? (render-fs '(local float async (fl 1))) 'async "local variable")
 (rejected? (render-fs '(local float wgsl (fl 1))) 'wgsl "local variable")
 (rejected? (render-fs '(local float Self (fl 1))) 'Self "local variable")
 ;; nested statements are declarations too
 (rejected? (render-fs '(if (> d (fl 1)) (local float let (fl 0))))
            'let "local variable")
 (rejected? (render-fs '(if-else (> d (fl 1))
                                 ((set! x (fl 0)))
                                 ((local float var (fl 0)))))
            'var "local variable")
 (rejected? (render-fs '(for (int i 0 (< i 4) (+ i 1))
                          (local float fn (fl 0))))
            'fn "local variable")
 ;; ---- loop index ----
 (rejected? (render-fs '(for (int loop 0 (< loop 4) (+ loop 1))
                          (set! x (fl 0))))
            'loop "loop index")
 ;; ---- function names and parameters ----
 (rejected? (lambda ()
              (wgsl->string (trivial-vs)
                            '((define (loop (vec3 c)) float (return c.x))
                              (define (main) void (return)))))
            'loop "function")
 (rejected? (lambda ()
              (wgsl->string (trivial-vs)
                            '((define (lum (vec3 let)) float (return let.x))
                              (define (main) void (return)))))
            'let "function parameter")
 ;; ---- global declarations, on either half of the module ----
 (rejected? (lambda () (wgsl->string (cons '(attribute vec2 var) (trivial-vs))
                                     (fs-with)))
            'var "attribute")
 (rejected? (lambda () (wgsl->string (trivial-vs)
                                     (cons '(uniform float fn) (fs-with))))
            'fn "uniform")
 (rejected? (lambda () (wgsl->string (trivial-vs)
                                     (cons '(varying vec2 let) (fs-with))))
            'let "varying")
 ;; the vertex half is checked too, not just whichever list is first
 (rejected? (lambda ()
              (wgsl->string (cons '(varying vec3 discard) (trivial-vs))
                            (fs-with)))
            'discard "varying")
 ;; a sampler2D uniform reaches the module as name_s / name_t, so its
 ;; declaration is a declaration all the same
 (rejected? (lambda () (wgsl->string (trivial-vs)
                                     (cons '(uniform sampler2D var)
                                           (fs-with))))
            'var "uniform")
 ;; ---- the compute module's own declaration sites ----
 (rejected? (compute-with '(struct loop ((vec2 pos)))) 'loop "struct")
 (rejected? (compute-with '(struct P ((vec2 var)))) 'var "struct member")
 (rejected? (compute-with '(storage let (array P))) 'let "storage buffer")
 (rejected? (compute-with '(uniform float const)) 'const "uniform")
 (rejected? (lambda ()
              (wgsl-compute->string
               '((workgroup 64)
                 (define (main) void (local uint switch gid.x)))))
            'switch "local variable")
 ;; ---- the underscore rules ----
 (rejected? (render-fs '(local float __x (fl 1))) '__x "local variable")
 (rejected? (lambda () (wgsl->string (cons '(attribute vec2 __p) (trivial-vs))
                                     (fs-with)))
            '__p "attribute")
 (rejected? (render-fs '(local float _ (fl 1))) '_ "local variable")
 ;; ---- the message cites WGSL, and which clause reserves the word ----
 (guard (e ((error? e)
            (and (has-sub? (condition-message e) "WGSL keyword")
                 (has-sub? (condition-message e) "illegal local variable name: fn"))))
   ((render-fs '(local float fn (fl 1))))
   #f)
 (guard (e ((error? e) (has-sub? (condition-message e) "WGSL reserved word")))
   ((render-fs '(local float mut (fl 1))))
   #f)
 (guard (e ((error? e)
            (has-sub? (condition-message e) "names beginning __ are reserved")))
   ((render-fs '(local float __x (fl 1))))
   #f)

 ;; ---- the table is WGSL's, not GLSL's ----
 ;;
 ;; The two languages look like relatives and are not.  These words
 ;; are GLSL keywords -- (gfx glsl) refuses every one of them -- and
 ;; WGSL reserves none of them, so WGSL must let them through.  A
 ;; table copied from glsl.ss would fail here.
 (ok? (render-fs '(local float out (fl 1))
                 '(local float in (fl 1))
                 '(local float inout (fl 1))
                 '(local float void (fl 1))))
 (ok? (lambda () (wgsl->string '((attribute vec2 out)
                                 (define (main) void
                                   (set! gl_Position (vec4 out (fl 0) (fl 1)))))
                               (fs-with))))
 (ok? (compute-with '(struct P ((vec2 in) (float out)))))
 ;; ... and the same names really are refused by the GLSL renderer,
 ;; so the divergence above is a difference of tables and not a
 ;; check that quietly does nothing
 (all? (lambda (w)
         (guard (e ((error? e) (and (memq w (condition-irritants e)) #t))
                   (else #f))
           (glsl->string (list (list 'uniform 'float w)))
           #f))
       '(out in inout void))
 ;; the mirror image: WGSL words GLSL leaves free.  (gfx glsl)
 ;; renders these; (gfx wgsl) must not.
 (all? (lambda (w)
         (ok? (lambda () (glsl->string (list (list 'uniform 'float w))))))
       '(let var fn loop alias override mut async wgsl crate enable))
 (all? (lambda (w)
         (rejected? (lambda () (wgsl->string (trivial-vs)
                                             (cons (list 'uniform 'float w)
                                                   (fs-with))))
                    w "uniform"))
       '(let var fn loop alias override mut async wgsl crate enable))
 ;; the underscore rules differ as well: WGSL reserves __ as a
 ;; *prefix* only (section 2.2), where GLSL reserves it anywhere, so
 ;; a__b is a legal WGSL name and an illegal GLSL one.  Copying
 ;; glsl.ss's rule would reject it here.
 (ok? (render-fs '(local float a__b (fl 1))))
 (ok? (lambda () (wgsl->string (cons '(attribute vec2 a__b) (trivial-vs))
                               (fs-with))))
 (guard (e ((error? e) (and (memq 'a__b (condition-irritants e)) #t))
           (else #f))
   (glsl->string '((uniform float a__b)))
   #f)
 ;; nor is gl_ a WGSL prefix rule: gl_Position is rewritten to
 ;; o.goe_pos on the way in, and a name merely beginning gl_ is an
 ;; ordinary WGSL identifier
 (ok? (render-fs '(local float gl_scale (fl 1))))

 ;; ---- what must NOT be refused ----
 ;; a reserved word is a whole name, not a substring or a prefix
 (ok? (render-fs '(local float letter (fl 1))
                 '(local float variance (fl 1))
                 '(local vec2 loopback (fl 1))
                 '(local float u_const (fl 1))
                 '(local float _x (fl 1))
                 '(local float x__ (fl 1))))
 ;; built-in references are uses, not declarations
 (ok? (lambda ()
        (wgsl->string
         '((attribute vec2 a_pos)
           (define (main) void
             (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
         '((define (main) void
             (set! gl_FragColor (vec4 gl_FragCoord.x (fl 0) (fl 0) (fl 1))))))))
 ;; the DSL's own structure words sit in head position: `struct' and
 ;; `discard' are WGSL keywords, and neither is a declared name here
 (ok? (lambda ()
        (wgsl-compute->string
         '((struct P ((vec2 pos) (float age)))
           (storage ps (array P))
           (workgroup 64)
           (define (main) void
             (local uint i gid.x)
             (local P p (at ps i)))))))
 (ok? (render-fs '(if (> d (fl 1)) (discard))))

 ;; ---- rendering is untouched ----
 ;; the example shader of examples/gpu-torus.ss, pinned whole: the
 ;; check runs before emission and must not have moved a character
 (string=?
  (wgsl->string
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_n)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (local vec4 nw (* u_model (vec4 a_normal (fl 0))))
       (set! v_n nw.xyz)))
   '((varying vec3 v_n)
     (define (main) void
       (local vec3 l (normalize (vec3 (fl 0 50) (fl 0 80) (fl 0 40))))
       (local float d (max (dot (normalize v_n) l) (fl 0)))
       (local vec3 base (vec3 "0.95" "0.45" "0.35"))
       (set! gl_FragColor
             (vec4 (* base (+ (fl 0 25) (* (fl 0 75) d))) (fl 1))))))
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
   "var l : vec3f = normalize(vec3f(0.50, 0.80, 0.40)); "
   "var d : f32 = max(dot(normalize(vin.v_n), l), 0.0); "
   "var base : vec3f = vec3f(0.95, 0.45, 0.35); "
   "goe_out = vec4f((base * (0.25 + (0.75 * d))), 1.0); "
   "return goe_out; } "))

 ;; ---- positive control: every WGSL form list in the tree ----
 ;; the textured example (examples/gpu-tex.ss) ...
 (ok? (lambda ()
        (wgsl->string
         '((attribute vec3 a_pos)
           (attribute vec3 a_normal)
           (attribute vec2 a_uv)
           (uniform mat4 u_mvp)
           (uniform mat4 u_model)
           (varying vec3 v_n)
           (varying vec2 v_uv)
           (define (main) void
             (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
             (local vec4 nw (* u_model (vec4 a_normal (fl 0))))
             (set! v_n nw.xyz)
             (set! v_uv a_uv)))
         '((uniform sampler2D u_tex)
           (varying vec3 v_n)
           (varying vec2 v_uv)
           (define (main) void
             (local vec4 t (texture2D u_tex v_uv))
             (local vec3 l (normalize (vec3 (fl 0 50) (fl 0 80) (fl 0 40))))
             (local float d (max (dot (normalize v_n) l) (fl 0)))
             (set! gl_FragColor
                   (vec4 (* t.rgb (+ (fl 0 30) (* (fl 0 70) d))) (fl 1))))))))
 ;; ... the particle compute module of test/wgsl.ss ...
 (ok? (lambda ()
        (wgsl-compute->string
         '((struct P ((vec2 pos) (float age)))
           (storage ps (array P))
           (uniform float dt)
           (workgroup 64)
           (define (h (float n)) float
             (return (fract (* (sin n) "43758.547"))))
           (define (main) void
             (local uint i gid.x)
             (if (>= i (array-length ps)) (return))
             (local P p (at ps i))
             (set! p.age (+ p.age dt))
             (if (== (% i 61) 0)
                 (set! p.age (fl 0)))
             (set! (at ps i) p))))))
 ;; ... and the shipped mesh shaders, which are the same forms the
 ;; GLSL renderers take.  mesh-pbr uses a cube texture, outside the
 ;; WGSL subset, so it is checked rather than rendered -- which is
 ;; what wgsl-check standing alone is for.
 (let ((vs (list mesh-lit-vs mesh-tex-vs mesh-normal-vs))
       (fs (list mesh-lit-fs mesh-tex-fs mesh-normal-fs)))
   (and (all? (lambda (p) (ok? (lambda () (wgsl->string (car p) (cdr p)))))
              (list (cons mesh-lit-vs mesh-lit-fs)
                    (cons mesh-tex-vs mesh-tex-fs)
                    (cons mesh-normal-vs mesh-normal-fs)))
        (all? (lambda (s) (wgsl-check s))
              (append vs fs (list mesh-pbr-vs mesh-pbr-fs))))))
