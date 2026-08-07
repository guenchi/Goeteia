;; expect: #t
;; (gfx glsl): reserved words are rejected where a name is introduced.
;; The DSL passes identifiers through verbatim, so a local named `out'
;; used to become invalid GLSL that failed to compile inside the
;; driver -- a blank frame and no Scheme-side error.  These cases pin
;; the generation-time check: which names are refused, at which
;; declaration positions, what the message says, and -- the half that
;; matters just as much -- what is still accepted.
(import (rnrs) (gfx glsl) (gfx mesh))

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

(define (main-with . stmts)             ; a shader around one statement
  (list (append '(define (main) void) stmts)))

(define (all? f xs)
  (or (null? xs) (and (f (car xs)) (all? f (cdr xs)))))

(and
 ;; ---- locals: the case that was actually hit ----
 (rejected? (lambda ()
              (glsl->string (main-with '(local float out (fl 1)))))
            'out "local variable")
 (rejected? (lambda ()
              (glsl->string (main-with '(local float in (fl 1)))))
            'in "local variable")
 (rejected? (lambda ()
              (glsl->string (main-with '(local vec4 sample (fl 1)))))
            'sample "local variable")
 (rejected? (lambda ()
              (glsl->string (main-with '(local float filter (fl 1)))))
            'filter "local variable")
 ;; nested statements are declarations too
 (rejected? (lambda ()
              (glsl->string
               (main-with '(if (> d (fl 1))
                             (local float out (fl 0))))))
            'out "local variable")
 (rejected? (lambda ()
              (glsl->string
               (main-with '(if-else (> d (fl 1))
                                    ((set! x (fl 0)))
                                    ((local float sample (fl 0)))))))
            'sample "local variable")
 ;; ---- function names and parameters ----
 (rejected? (lambda ()
              (glsl->string '((define (filter (vec3 c)) float
                                (return c.x)))))
            'filter "function")
 (rejected? (lambda ()
              (glsl->string '((define (lum (vec3 sample)) float
                                (return sample.x)))))
            'sample "function parameter")
 (rejected? (lambda ()
              (glsl->string '((define (lum (vec3 c) (float in)) float
                                (return c.x)))))
            'in "function parameter")
 ;; ---- loop index ----
 (rejected? (lambda ()
              (glsl->string
               (main-with '(for (int sample 0 (< sample 3) (+ sample 1))
                             (set! x (+ x sample))))))
            'sample "loop index")
 ;; ---- global declarations ----
 (rejected? (lambda () (glsl->string '((attribute vec2 in))))
            'in "attribute")
 (rejected? (lambda () (glsl->string '((uniform float filter))))
            'filter "uniform")
 (rejected? (lambda () (glsl->string '((varying vec2 out))))
            'out "varying")
 (rejected? (lambda () (glsl->string '((varying (array vec2 4) sample))))
            'sample "varying")
 (rejected? (lambda () (glsl300-vs->string '((attribute vec2 filter))))
            'filter "attribute")
 ;; ---- ESSL 3.00-only forms ----
 (rejected? (lambda ()
              (glsl300-fs->string '((out 0 vec4 filter)
                                    (define (main) void
                                      (set! filter (vec4 (fl 1)))))))
            'filter "fragment output")
 (rejected? (lambda ()
              (glsl300-vs->string '((uniform-block sample (mat4 u_vp)))))
            'sample "uniform block")
 (rejected? (lambda ()
              (glsl300-vs->string '((uniform-block Env (mat4 in)))))
            'in "uniform block member")
 (rejected? (lambda ()
              (glsl300-vs->string
               '((uniform-block Env ((array mat4 8) filter)))))
            'filter "uniform block member")
 ;; ---- gl_ prefix and __ ----
 (rejected? (lambda () (glsl->string (main-with '(local float gl_foo (fl 1)))))
            'gl_foo "local variable")
 (rejected? (lambda () (glsl->string '((uniform float gl_Depth))))
            'gl_Depth "uniform")
 (rejected? (lambda () (glsl->string (main-with '(local float __x (fl 1)))))
            '__x "local variable")
 (rejected? (lambda () (glsl->string '((attribute vec2 a__b))))
            'a__b "attribute")
 (rejected? (lambda () (glsl->string '((define (a__b) void (return)))))
            'a__b "function")
 ;; ---- 3.00-only reserved words are refused in BOTH dialects ----
 ;; `sample', `filter', `layout' and `smooth' are free identifiers
 ;; under 1.00 and reserved under 3.00.  The forms are dialect-
 ;; neutral, so a shader accepted here as 1.00 is one call away from
 ;; being emitted as 300 es -- accepting it now would only move the
 ;; blank frame to the day someone ports it.  Both are refused, and
 ;; the message cites 3.00 as the spec that reserves them.
 (rejected? (lambda () (glsl->string (main-with '(local float layout (fl 1)))))
            'layout "local variable")
 (rejected? (lambda () (glsl->string (main-with '(local float smooth (fl 1)))))
            'smooth "local variable")
 (rejected? (lambda () (glsl300-vs->string (main-with '(local float sample (fl 1)))))
            'sample "local variable")
 (guard (e ((error? e) (has-sub? (condition-message e) "3.00")))
   (glsl->string (main-with '(local float sample (fl 1))))
   #f)
 (guard (e ((error? e) (has-sub? (condition-message e) "1.00")))
   (glsl->string (main-with '(local float out (fl 1))))
   #f)
 ;; ---- what must NOT be refused ----
 ;; built-in variables are referenced, never declared
 (ok? (lambda ()
        (glsl->string
         (main-with '(set! gl_Position (vec4 p (fl 0) (fl 1)))
                    '(set! gl_PointSize (fl 2))))))
 (ok? (lambda ()
        (glsl->string
         (main-with '(local float s (fl 1))
                    '(if gl_FrontFacing (set! s (- s)))
                    '(set! gl_FragColor (vec4 s s s (fl 1)))))))
 ;; the DSL's own structure words: `out' heads (out loc T name), and
 ;; attribute/uniform/varying/uniform-block head their forms.  None
 ;; of them is a declared identifier, so none is matched
 (ok? (lambda ()
        (glsl300-fs->string '((out 0 vec4 o_albedo)
                              (out 1 vec4 o_normal)
                              (define (main) void
                                (set! o_albedo (vec4 (fl 1)))
                                (set! o_normal (vec4 (fl 0))))))))
 (ok? (lambda ()
        (glsl300-vs->string '((attribute vec3 a_pos) (varying vec3 v_n)
                              (uniform mat4 u_mvp)
                              (uniform-block Env (mat4 u_vp))))))
 ;; type names sit in type position and are not declarations either
 (ok? (lambda () (glsl->string '((uniform sampler2D u_tex)
                                 (uniform (array mat4 32) u_joints)))))
 ;; a reserved word is a whole name, not a substring: u_glow starts
 ;; with neither "gl_" nor anything reserved, and outc/in_pos/inout2
 ;; merely begin with one.  "gl_" is reserved as a *prefix* only, so
 ;; u_gl_scale is a legal name -- a substring test here would reject
 ;; it
 (ok? (lambda () (glsl->string '((uniform float u_glow)
                                 (uniform float u_gl_scale)
                                 (uniform vec3 u_input)
                                 (attribute vec2 in_pos)
                                 (varying float inout2)))))
 (ok? (lambda () (glsl->string (main-with '(local vec3 outc (fl 1))
                                          '(local float sampler (fl 1))
                                          '(local float _x (fl 1))))))
 ;; the rendering itself is untouched
 (string=? (glsl->string '((attribute vec2 p)
                           (define (main) void
                             (set! gl_Position (vec4 p (fl 0) (fl 1))))))
           (string-append "attribute vec2 p; void main() { "
                          "gl_Position = vec4(p, 0.0, 1.0); } "))
 ;; ---- positive control: every shipped shader, both dialects ----
 (let ((vs (list mesh-lit-vs mesh-tex-vs mesh-normal-vs mesh-pbr-vs))
       (fs (list mesh-lit-fs mesh-tex-fs mesh-normal-fs mesh-pbr-fs)))
   (and (all? (lambda (s) (ok? (lambda () (glsl->string s))))
              (append vs fs))
        (all? (lambda (s) (ok? (lambda () (glsl300-vs->string s)))) vs)
        (all? (lambda (s) (ok? (lambda () (glsl300-fs->string s)))) fs)
        ;; glsl-check is the same answer standing alone
        (all? (lambda (s) (glsl-check s)) (append vs fs)))))
