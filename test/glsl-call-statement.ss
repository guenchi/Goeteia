;; expect: #t
;; A function call is a statement of the shader forms: (call f arg ...).
;;
;; The forms had no expression statement, so a void function -- and a
;; function with out or inout parameters, whose effect IS the call --
;; could only be reached through a non-void function inside another
;; expression.  (call f arg ...) renders "f(arg, ...); " in both GLSL
;; dialects and in WGSL.  It is spelt out rather than read off any
;; unknown head, so a misspelt statement keyword is still refused as a
;; bad statement instead of becoming a call to a function of that name.
;;
;; Checked by glsl-check (so every GLSL emission path) and wgsl-check,
;; with who glsl / wgsl:
;;   (call) with nothing to call, and (call 7) whose callee is not a name;
;;   a loop exit in EXPRESSION position, wherever an expression stands --
;;   a set!'s value, a local's initializer, a return value, an if's
;;   condition, a for's test, a call's argument, nested inside another
;;   expression, and a top-level constant's initializer -- inside a for or
;;   not: (set! x (break)) used to render
;;   "x = break();", a shader the GLSL compiler refuses.
;; WGSL renders the same forms through its own walkers, so each refusal is
;; read there too, and so is the control that an unknown head stays a bad
;; statement rather than becoming a call.
;;
;; WGSL renames every uniform and varying reference (u.x, o.x, vin.x)
;; before it renders, and that renaming used to reach the HEADS of lists
;; too: with a uniform or a varying named call, (call tick) became
;; (u.call tick), a bad statement; named local, (local ...) did; named fl,
;; (fl 2) became a call to u.fl.  A list's head is syntax -- a keyword, a
;; type, a function or an operator -- never a uniform or varying, so it is
;; not renamed; an element still is.
;; A real GLSL compiler reads the call forms through the glsl-forms entry
;; in tools/shader-emit.ss.
;;
;; ON THE TREE BEFORE THE CHANGE the emission rows raise "bad statement"
;; and the expression-position rows pass silently; the cell is red.
(import (rnrs) (gfx glsl) (gfx wgsl))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t (list 'raised (condition-who e)))) (thunk)))
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(define forms
  '((precision mediump float)
    (define (bump (inout vec3 a) (in float k)) void (set! a (* a k)))
    (define (main) void
      (local vec3 v (vec3 (fl 1)))
      (call bump v (fl 2))
      (set! gl_FragColor (vec4 v (fl 1))))))

(want "ES 1.00: a call statement"
      (try (lambda () (glsl->string forms)))
      (string-append "precision mediump float; "
                     "void bump(inout vec3 a, in float k) { a = (a * k); } "
                     "void main() { vec3 v = vec3(1.0); bump(v, 2.0); "
                     "gl_FragColor = vec4(v, 1.0); } "))
(want "ES 3.00: the same"
      (try (lambda () (contains? (glsl300-fs->string forms) "bump(v, 2.0); ")))
      #t)
(want "ES 3.00 vertex: a call with no arguments"
      (try (lambda ()
             (contains? (glsl300-vs->string
                         '((attribute vec2 p)
                           (define (noop) void (return))
                           (define (main) void (call noop) (set! gl_Position (vec4 p (fl 0) (fl 1))))))
                        "noop(); ")))
      #t)
(want "a call inside a for and an if"
      (try (lambda ()
             (contains? (glsl->string
                         '((define (tick) void (return))
                           (define (main) void
                             (for (int i 0 (< i 2) (+ i 1)) (if (== i 1) (call tick))))))
                        "if ((i == 1)) { tick(); } ")))
      #t)

;; ---- refusals ----
(define (refused name fs)
  (want (string-append name " (ES 1.00)") (try (lambda () (glsl->string fs))) '(raised glsl))
  (want (string-append name " (ES 3.00)") (try (lambda () (glsl300-fs->string fs))) '(raised glsl))
  (want (string-append name " (glsl-check)") (try (lambda () (glsl-check fs))) '(raised glsl)))
(define (fn . stmts) (list (cons 'define (cons '(main) (cons 'void stmts)))))
(define loop-head '(int i 0 (< i 4) (+ i 1)))

(refused "a call with nothing to call" (fn '(call)))
(refused "a call whose callee is not a name" (fn '(call 7 (fl 1))))
(refused "break in expression position, inside a for"
         (fn '(local float x (fl 0)) (list 'for loop-head '(set! x (break)))))
(refused "continue in expression position, as an argument"
         (fn '(local float x (fl 0)) (list 'for loop-head '(set! x (max x (continue))))))
(refused "break in expression position, outside any loop"
         (fn '(local float x (fl 0)) '(set! x (break))))
;; the other places an expression stands
(define exits-in-expressions
  (list (list "a local's initializer" (fn (list 'for loop-head '(local float x (break)))))
        (list "a return value" (list (list 'define '(g) 'float (list 'for loop-head '(return (continue))) '(return (fl 0)))))
        (list "an if's condition" (fn (list 'for loop-head '(if (break) (discard)))))
        (list "an if-else's condition" (fn (list 'for loop-head '(if-else (continue) ((discard)) ((discard))))))
        (list "a for's test" (fn '(for (int i 0 (< i (break)) (+ i 1)) (discard))))
        (list "a call's argument" (append '((define (tick (in float k)) void (return)))
                                          (fn (list 'for loop-head '(call tick (break))))))
        (list "nested inside another expression" (fn '(local float x (fl 0)) (list 'for loop-head '(set! x (+ x (* (fl 2) (break)))))))))
(for-each (lambda (row) (refused (string-append "a loop exit in " (car row)) (cadr row)))
          exits-in-expressions)
(refused "a loop exit as a top-level constant's initializer"
         (cons '(const float k (break)) (fn '(discard))))
(refused "a loop exit nested in a top-level constant's initializer"
         (cons '(const float k (+ (fl 1) (continue))) (fn '(discard))))
(want "CONTROL a top-level constant whose initializer is no loop exit"
      (try (lambda () (contains? (glsl->string (cons '(const float k (+ (fl 1) (fl 2))) (fn '(discard))))
                                 "const float k = (1.0 + 2.0); ")))
      #t)
(want "CONTROL loop exits as statements, in a for, still render"
      (try (lambda () (contains? (glsl->string (fn (list 'for loop-head '(if (== i 1) (continue)) '(break))))
                                 "if ((i == 1)) { continue; } break; ")))
      #t)
(want "CONTROL a misspelt statement keyword is still a bad statement, not a call"
      (try (lambda () (glsl->string (fn '(retrun)))))
      '(raised glsl))

;; ---- WGSL ----
(define vs '((attribute vec2 p) (define (main) void (set! gl_Position (vec4 p (fl 0) (fl 1))))))
(define fs-call
  '((define (tick (in float k)) void (return))
    (define (main) void
      (local float s (fl 0))
      (call tick s)
      (set! gl_FragColor (vec4 s s s (fl 1))))))
(want "WGSL: a call statement travels"
      (try (lambda () (contains? (wgsl->string vs fs-call) "tick(s); ")))
      #t)
(want "WGSL: a call with nothing to call is refused"
      (try (lambda () (wgsl-check (fn '(call)))))
      '(raised wgsl))
(want "WGSL: break in expression position is refused"
      (try (lambda () (wgsl-check (fn '(local float x (fl 0)) (list 'for loop-head '(set! x (break)))))))
      '(raised wgsl))
(for-each
 (lambda (row)
   (want (string-append "WGSL: a loop exit in " (car row) " (wgsl-check)")
         (try (lambda () (wgsl-check (cadr row)))) '(raised wgsl)))
 exits-in-expressions)
(want "WGSL: a call whose callee is not a name is refused (wgsl-check)"
      (try (lambda () (wgsl-check (fn '(call 7 (fl 1)))))) '(raised wgsl))
(want "WGSL: a call whose callee is not a name is refused (wgsl->string)"
      (try (lambda () (wgsl->string vs (fn '(call 7 (fl 1)))))) '(raised wgsl))
(want "WGSL: a call with nothing to call is refused (wgsl->string)"
      (try (lambda () (wgsl->string vs (fn '(call))))) '(raised wgsl))
(want "WGSL: CONTROL a misspelt statement keyword is a bad statement, not a call"
      (try (lambda () (wgsl->string vs (fn '(retrun))))) '(raised wgsl))
(want "WGSL: CONTROL the same, nested in a for"
      (try (lambda () (wgsl->string vs (fn (list 'for loop-head '(retrun)))))) '(raised wgsl))

;; ---- WGSL: a uniform or varying named like a head ----
(define (renders-with? thunk sub)
  (try (lambda () (contains? (thunk) sub))))
(want "WGSL: a uniform named call beside a call statement"
      (renders-with? (lambda ()
                       (wgsl->string vs (list '(uniform float call)
                                              '(define (tick) void (return))
                                              '(define (main) void (call tick) (set! gl_FragColor (vec4 call call call (fl 1)))))))
                     "tick(); ")
      #t)
(want "WGSL: a varying named call, passed to the called function"
      (renders-with? (lambda ()
                       (wgsl->string
                        '((attribute vec2 p) (varying float call)
                          (define (main) void (set! call (fl 1)) (set! gl_Position (vec4 p (fl 0) (fl 1)))))
                        '((varying float call)
                          (define (tick (in float k)) void (return))
                          (define (main) void (call tick call) (set! gl_FragColor (vec4 call call call (fl 1)))))))
                     "tick(vin.call); ")
      #t)
(want "WGSL compute: a uniform named call beside a call statement"
      (renders-with? (lambda ()
                       (wgsl-compute->string
                        '((uniform float call) (workgroup 64)
                          (define (tick) void (return))
                          (define (main) void (call tick)))))
                     "tick(); ")
      #t)
(want "WGSL: a uniform named local does not turn local statements into calls"
      (renders-with? (lambda ()
                       (wgsl->string vs (list '(uniform float local)
                                              '(define (main) void (local float x (fl 1)) (set! gl_FragColor (vec4 x local x (fl 1)))))))
                     "var x : f32 = 1.0; ")
      #t)
(want "WGSL: a uniform named fl does not turn float literals into calls"
      (try (lambda ()
             (let ((out (wgsl->string vs (list '(uniform float fl)
                                               '(define (main) void (set! gl_FragColor (vec4 (fl 2) fl (fl 0) (fl 1))))))))
               (and (contains? out "vec4f(2.0, u.fl, 0.0, 1.0)") (not (contains? out "u.fl("))))))
      #t)
(want "WGSL: CONTROL a uniform in an argument is still renamed"
      (renders-with? (lambda ()
                       (wgsl->string vs (list '(uniform float amount)
                                              '(define (tick (in float k)) void (return))
                                              '(define (main) void (call tick amount) (set! gl_FragColor (vec4 amount amount amount (fl 1)))))))
                     "tick(u.amount); ")
      #t)

(display (if (null? fails) #t (reverse fails)))
