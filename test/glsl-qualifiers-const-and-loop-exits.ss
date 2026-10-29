;; expect: #t
;; The shader forms gain parameter qualifiers, top-level constants and
;; the two loop exits.
;;
;; THE CONTRACT, as these rows state it:
;;   a function parameter is (T name) as before, or (Q T name) with Q
;;     one of in out inout -> "Q T name"
;;   (const T name expr) at top level -> "const T name = expr; ", in
;;     both GLSL dialects
;;   (break) and (continue) are statements -> "break; " "continue; "
;; and what glsl-check (so every GLSL emission path) refuses, with who
;; glsl:
;;   a (break) or (continue) that is not inside a (for ...) of the same
;;     function -- the GLSL compiler refuses that too, and the point of
;;     the check is that the error is raised here, at the form, instead
;;     of in a shader that silently fails to compile;
;;   a (break) or (continue) with anything after it;
;;   a three-part parameter whose first part is not in, out or inout;
;;   a reserved word as a qualified parameter's name or as a constant's
;;     name -- the name of (Q T name) is its THIRD part, and a check
;;     still reading the second would look at the type and pass.
;; WGSL, which renders the same forms ((gfx wgsl)): break, continue
;; and an `in` parameter travel; a constant and an out or inout
;; parameter are refused, with who wgsl, rather than translated --
;; WGSL has no out parameter (it would need a pointer), and a top-level
;; form the module does not know is dropped without a word, which is
;; the failure this refusal exists to prevent.  wgsl-check refuses a
;; loop exit outside a for as glsl-check does.
;;
;; Whether a real GLSL compiler accepts what these forms render is read
;; by test/shader-compile.mjs, through the glsl-forms entries in
;; tools/shader-emit.ss -- the same forms as the first rows here.
;;
;; ON THE TREE BEFORE THE CHANGE the first rows are refused ("bad
;; statement (continue)", a parameter read as type `inout`) and the
;; refusal rows pass vacuously or fail; the cell is red.
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
    (const float K (fl 2))
    (define (f (inout vec3 a) (out float b) (in float c) (float d)) float
      (set! a (* a c)) (set! b (+ c d)) (return K))
    (define (main) void
      (local vec3 v (vec3 (fl 1)))
      (local float w (fl 0))
      (local float r (fl 0))
      (for (int i 0 (< i 4) (+ i 1))
        (if (== i 2) (continue))
        (if-else (> i 2) ((break)) ((set! r (f v w K (fl 1))))))
      (set! gl_FragColor (vec4 v (+ w r))))))

(define body
  (string-append
   "const float K = 2.0; "
   "float f(inout vec3 a, out float b, in float c, float d) { "
   "a = (a * c); b = (c + d); return K; } "
   "void main() { vec3 v = vec3(1.0); float w = 0.0; float r = 0.0; "
   "for (int i = 0; (i < 4); i += 1) { if ((i == 2)) { continue; } "
   "if ((i > 2)) { break; } else { r = f(v, w, K, 1.0); } } "))

(want "ES 1.00: qualifiers, const, continue and break, in place"
      (try (lambda () (glsl->string forms)))
      (string-append "precision mediump float; " body
                     "gl_FragColor = vec4(v, (w + r)); } "))
(want "ES 3.00 vertex: a constant and a qualified helper in a vertex shader"
      (try (lambda ()
             (glsl300-vs->string
              '((attribute vec2 p)
                (const float S (fl 0 5))
                (define (sc (inout vec2 q) (in float k)) float (set! q (* q k)) (return k))
                (define (main) void
                  (local vec2 x p)
                  (local float u (sc x S))
                  (set! gl_Position (vec4 x u (fl 1))))))))
      (string-append "#version 300 es\nin vec2 p; const float S = 0.5; "
                     "float sc(inout vec2 q, in float k) { q = (q * k); return k; } "
                     "void main() { vec2 x = p; float u = sc(x, S); "
                     "gl_Position = vec4(x, u, 1.0); } "))
(want "ES 3.00: the same, respelled"
      (try (lambda () (glsl300-fs->string forms)))
      (string-append "#version 300 es\nout highp vec4 goe_FragColor; "
                     "precision mediump float; " body
                     "goe_FragColor = vec4(v, (w + r)); } "))

;; ---- refusals by glsl-check, through both emission paths ----
(define (fn . stmts) (list (cons 'define (cons '(main) (cons 'void stmts)))))
(define loop-head '(int i 0 (< i 4) (+ i 1)))
(define (refused name fs)
  (want (string-append name " (ES 1.00)") (try (lambda () (glsl->string fs))) '(raised glsl))
  (want (string-append name " (ES 3.00)") (try (lambda () (glsl300-fs->string fs))) '(raised glsl))
  (want (string-append name " (ES 3.00 vertex)") (try (lambda () (glsl300-vs->string fs))) '(raised glsl))
  (want (string-append name " (glsl-check)") (try (lambda () (glsl-check fs))) '(raised glsl)))

(refused "break at a function's top level" (fn '(break)))
(refused "continue inside an if, outside any for" (fn '(if (== 1 1) (continue))))
(refused "break after a for has closed"
         (fn (list 'for loop-head '(break)) '(break)))
(refused "break in a function after one whose for held a break"
         (append (list (list 'define '(g) 'void (list 'for loop-head '(break))))
                 (fn '(break))))
(refused "break with an operand, inside a for" (fn (list 'for loop-head '(break 1))))
(refused "continue with an operand, inside a for" (fn (list 'for loop-head '(continue i))))
(refused "a parameter qualifier that is not in, out or inout"
         '((define (g (uniform vec3 a)) void (return))))
(refused "a reserved name after inout"
         '((define (g (inout vec3 sample)) void (return))))
(refused "a reserved name after in"
         '((define (g (in float sample)) void (return))))
(refused "a reserved name after out"
         '((define (g (out float sample)) void (return))))
(refused "a reserved constant name" '((const float filter (fl 1))))
;; A refusal raised INSIDE a for must not leave the checker believing it
;; is still in one: the next forms checked, in a separate call, start
;; outside every loop.  An implementation that tracks "inside a for" in
;; state that an error skips restoring passes every row above and fails
;; this one.
(try (lambda () (glsl-check (fn (list 'for loop-head '(local float sample (fl 0)))))))
(refused "break at top level, checked after a refusal raised inside a for" (fn '(break)))
(try (lambda () (wgsl-check (fn (list 'for loop-head '(local float var (fl 0)))))))
(want "WGSL: the same, after a refusal raised inside a for"
      (try (lambda () (wgsl-check (fn '(break))))) '(raised wgsl))

;; ---- CONTROLS: what must still pass, and the old checks still bite ----
(want "CONTROL break inside both branches of an if-else inside a for"
      (try (lambda ()
             (contains? (glsl->string (fn (list 'for loop-head
                                                '(if-else (> i 1) ((break)) ((continue))))))
                        "if ((i > 1)) { break; } else { continue; } ")))
      #t)
(want "CONTROL a for nested in a for: break in the inner one"
      (try (lambda ()
             (contains? (glsl->string (fn (list 'for loop-head
                                                (list 'for '(int j 0 (< j 2) (+ j 1)) '(break)))))
                        "{ break; } } ")))
      #t)
(want "CONTROL a loop exit in the outer for, after an inner for has closed"
      (try (lambda ()
             (contains? (glsl->string (fn (list 'for loop-head
                                                (list 'for '(int j 0 (< j 2) (+ j 1)) '(break))
                                                '(continue))))
                        "{ break; } continue; } ")))
      #t)
(want "CONTROL an unqualified reserved parameter name is still refused"
      (try (lambda () (glsl->string '((define (g (vec3 sample)) void (return))))))
      '(raised glsl))

;; ---- WGSL ----
(define vs '((attribute vec2 p) (define (main) void (set! gl_Position (vec4 p (fl 0) (fl 1))))))
(define (fs-with . top)
  (append top
          '((define (main) void
              (local float s (fl 0))
              (for (int i 0 (< i 4) (+ i 1))
                (if (== i 2) (continue))
                (if (> i 2) (break))
                (set! s (+ s (fl 1))))
              (set! gl_FragColor (vec4 s s s (fl 1)))))))
(define wgsl-out (try (lambda () (wgsl->string vs (fs-with)))))
(want "WGSL: continue travels"
      (and (string? wgsl-out) (contains? wgsl-out "if ((i == 2)) { continue; } ")) #t)
(want "WGSL: break travels"
      (and (string? wgsl-out) (contains? wgsl-out "if ((i > 2)) { break; } ")) #t)
(want "WGSL: an in parameter travels as a plain one"
      (try (lambda ()
             (contains? (wgsl->string vs (fs-with '(define (h (in float c) (float d)) float
                                                      (return (+ c d)))))
                        "fn h(c : f32, d : f32) -> f32 { ")))
      #t)
(want "WGSL: an inout parameter is refused, not translated"
      (try (lambda () (wgsl->string vs (fs-with '(define (h (inout float c)) float (return c))))))
      '(raised wgsl))
(want "WGSL: an out parameter is refused, not translated"
      (try (lambda () (wgsl->string vs (fs-with '(define (h (out float c)) float (return c))))))
      '(raised wgsl))
(want "WGSL: a constant is refused, not dropped"
      (try (lambda () (wgsl->string vs (fs-with '(const float K (fl 2))))))
      '(raised wgsl))
(want "WGSL: wgsl-check refuses a break outside a for"
      (try (lambda () (wgsl-check (fn '(break)))))
      '(raised wgsl))
(want "WGSL: wgsl-check refuses a continue outside a for"
      (try (lambda () (wgsl-check (fn '(if (== 1 1) (continue))))))
      '(raised wgsl))
(want "WGSL: wgsl->string refuses a continue outside a for"
      (try (lambda () (wgsl->string vs (fn '(continue)))))
      '(raised wgsl))
(want "WGSL: CONTROL a loop exit in the outer for, after an inner for has closed"
      (try (lambda ()
             (wgsl-check (fn (list 'for loop-head
                                   (list 'for '(int j 0 (< j 2) (+ j 1)) '(break))
                                   '(continue))))))
      #t)

(display (if (null? fails) #t (reverse fails)))
