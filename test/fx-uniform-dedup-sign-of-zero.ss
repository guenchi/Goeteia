;; expect: #t
;; fx-uniform! does not take -0.0 for a repeat of 0.0, or 0.0 for a
;; repeat of -0.0 (R54: archive/goeteia-m26-2026-11-12.md).
;;
;; THE DEFECT.  The scalar/vector cache compared values with fl=?, under
;; which 0.0 and -0.0 are equal, so a set of -0.0 after 0.0 in one stream
;; sent nothing and the draw after it read 0.0.  A shader that divides by
;; the uniform, or takes its sign, sees the difference.
;;
;; THE RULE.  A set is a repeat only when every component it sends is
;; equal to the recorded one AND of the same sign when it is a zero.
;; Nothing else changes: equal values of one sign are still skipped.
;;
;; THE INSTRUMENT.  test/lib/glstate.ss records the value each draw
;; reads.  Its call log prints -0 as "0", and js->number answers the
;; exact 0 for a JS -0, so the sign is read on the JS side: each draw's
;; first component of the uniform, written "-0" for negative zero.
;; (equal? does not tell 0.0 from -0.0 in this language today either --
;; ledger row R59 -- so no row compares zeros as numbers.)
;;
;; Rows (base = the tree before the change):
;;   Z1  0.0, draw, -0.0, draw: the second draw reads -0.0 (base: 0.0)
;;   Z2  -0.0, draw, 0.0, draw: the second draw reads 0.0 (base: -0.0)
;;   Z3  a vec4 whose last component goes from 0.0 to -0.0 is sent, and
;;       the draw reads -0.0 there (base: not sent)
;;   Z4  in a vec2, a vec3 and a vec4, a sign change of ONE zero component,
;;       each component in turn, both directions, the others fixed: the
;;       draw after it reads the new sign there (a comparison that checks
;;       some components only)
;;   N1  NaN set twice in one stream is sent twice, and both draws read NaN
;;       (the ruling leaves NaN never equal; a comparison that takes NaN for
;;       a repeat)
;;   C1  0.0 twice, and -0.0 twice, in one stream: one call each (a
;;       comparison that never skips a zero)
(import (rnrs) (web js) (gfx gl) (gfx fx) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(fx-init! (glstate-canvas 64 64))
(define (prog)
  (fx-program! '((attribute vec2 a_pos)
                 (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
               '((precision mediump float) (uniform float u_k) (uniform vec4 u_v)
                 (uniform vec2 u_2) (uniform vec3 u_3)
                 (define (main) void
                   (set! gl_FragColor (+ u_v (vec4 u_k (+ u_2.x u_3.x) (fl 0) (fl 1))))))))
(define buf (fx-buffer!))
(define (D) (cmd-draw-arrays! GL-TRIANGLES 0 3))
(define pz 0.0)
(define nz (fl* -1.0 0.0))
;; per draw since the last reset: component i of the uniform as the draw
;; read it, "-0" for negative zero, "NaN", "none" where unset
(define (draw-reads-at name i)
  (js->string
   (js-eval (string-append
             "globalThis.__glstate.draws.map(d => { const v = d.vals['" name "'];"
             " if (v === undefined) return 'none'; const x = v[" (number->string i) "];"
             " return Object.is(x, -0) ? '-0' : Number.isNaN(x) ? 'NaN' : String(x); }).join(' ')"))))
(define (draw-reads name) (draw-reads-at name 0))
(define (one-stream thunk)
  (cmd-begin!) (thunk) (glstate-reset!) (cmd-flush!))
;; uniform calls of a name since the last reset
(define (calls prefix)
  (length (filter (lambda (e) (and (>= (string-length e) (string-length prefix))
                                   (string=? (substring e 0 (string-length prefix)) prefix)))
                  (glstate-uniform-log))))

(want "setup -0.0 is negative zero" (fl<? (fl/ 1.0 nz) 0.0) #t)

(let ((p (prog)))
  (one-stream (lambda () (fx-use! p buf) (fx-uniform! p 'u_k pz) (D) (fx-uniform! p 'u_k nz) (D)))
  (want "Z1 0.0 then -0.0: the second draw reads -0.0"
        (draw-reads "u_k") "0 -0"))

(let ((p (prog)))
  (one-stream (lambda () (fx-use! p buf) (fx-uniform! p 'u_k nz) (D) (fx-uniform! p 'u_k pz) (D)))
  (want "Z2 -0.0 then 0.0: the second draw reads 0.0"
        (draw-reads "u_k") "-0 0"))

(let ((p (prog)))
  (one-stream (lambda ()
                (fx-use! p buf)
                (fx-uniform! p 'u_v 1.0 2.0 3.0 pz) (D)
                (fx-uniform! p 'u_v 1.0 2.0 3.0 nz) (D)))
  (want "Z3 a vec4 whose last component changes sign is sent again"
        (calls "4f:u_v:") 2)
  (want "Z3 and the draws read 0.0 then -0.0 there"
        (draw-reads-at "u_v" 3) "0 -0"))

;; Z4: one zero component of an n-vector, set with one sign then the
;; other, the rest fixed at 1.0
(define (vec-with n i x) (let loop ((k 0)) (if (= k n) '() (cons (if (= k i) x 1.0) (loop (+ k 1))))))
(for-each
 (lambda (spec)
   (let ((name (car spec)) (n (cadr spec)))
     (let loop ((i 0))
       (when (< i n)
         (for-each
          (lambda (dir)
            (let ((p (prog)) (a (car dir)) (b (cadr dir)) (want-s (caddr dir)))
              (one-stream (lambda ()
                            (fx-use! p buf)
                            (apply fx-uniform! p name (vec-with n i a)) (D)
                            (apply fx-uniform! p name (vec-with n i b)) (D)))
              (want (string-append "Z4 " (symbol->string name) " component "
                                   (number->string i) " " want-s)
                    (draw-reads-at (symbol->string name) i) want-s)))
          (list (list pz nz "0 -0") (list nz pz "-0 0")))
         (loop (+ i 1))))))
 '((u_2 2) (u_3 3) (u_v 4)))

(let ((p (prog)) (nan (fl/ 0.0 0.0)))
  (one-stream (lambda () (fx-use! p buf)
                (fx-uniform! p 'u_k nan) (D) (fx-uniform! p 'u_k nan) (D)))
  (want "N1 NaN twice in one stream is two calls" (calls "1f:u_k:") 2)
  (want "N1 and both draws read NaN" (draw-reads "u_k") "NaN NaN"))

(let ((p (prog)))
  (one-stream (lambda () (fx-use! p buf)
                (fx-uniform! p 'u_k pz) (D) (fx-uniform! p 'u_k pz) (D)))
  (want "C1 0.0 twice in one stream is one call" (calls "1f:u_k:") 1)
  (one-stream (lambda () (fx-use! p buf)
                (fx-uniform! p 'u_k nz) (D) (fx-uniform! p 'u_k nz) (D)))
  (want "C1 -0.0 twice in one stream is one call" (calls "1f:u_k:") 1)
  (want "C1 and both draws read -0.0"
        (draw-reads "u_k") "-0 -0"))

(display (if (null? fails) #t (reverse fails)))
