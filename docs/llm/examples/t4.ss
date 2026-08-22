;; T4 -- a fragment shader.  This file IS the browser half.  Shaders
;; are s-expressions: glsl->string is a pure function from forms to
;; GLSL, so they compose with append and map and verify headlessly.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx))

(define (num v) (exact->inexact (js->number v)))

(fx-init! (get-element-by-id "c"))

;; (fl W F) is a float literal whose F is the digits after the point,
;; exactly as written: (fl 2) -> "2.0", (fl 0 5) -> "0.5", and
;; (fl 0 625) -> "0.625".  Scheme drops a leading zero before this
;; code sees it, so a third argument gives a minimum width and the
;; padding it implies: (fl 0 5 2) -> "0.05", (fl 0 2037 5) ->
;; "0.02037".  A string passes
;; through verbatim: "0.4545".  There are no Scheme flonums in shader
;; forms, and no exponent syntax.
;;
;; Every name this introduces -- locals, uniforms, parameters, the
;; functions -- is checked against the GLSL ES 1.00 AND 3.00 reserved
;; lists at GENERATION time, so a local called `out`, `sample` or
;; `filter` is a named error here instead of a blank canvas in the
;; browser.  Built-in functions are called, not declared, so sin /
;; mix / clamp / length pass straight through.
(define plasma
  '((precision mediump float)
    (uniform float u_time)                ; fx wires these two
    (uniform vec2 u_resolution)           ; iff they are declared
    (uniform float u_warp)
    ;; A function with parameters is (define (name (T arg) ...) RET
    ;; stmt ...): Scheme's shape with the types spelled out, `return`
    ;; as a statement, and `local` for its variables.
    (define (band (vec2 p) (float k) (float ph)) float
      (local float d (length p))
      (return (sin (+ (* d k) ph))))
    (define (main) void
      ;; pixel coords -> [-1,1] with the aspect kept
      (local vec2 uv (/ (- (* gl_FragCoord.xy (fl 2)) u_resolution)
                        u_resolution.y))
      (local float a (band uv (* (fl 6) u_warp) (* u_time (fl 0 90))))
      (local float b (band (- uv (vec2 (fl 0 40) (fl 0 20)))
                           (fl 9) (* u_time (fl 0 55))))
      (local float k (clamp (+ (fl 0 50) (* (fl 0 25) (+ a b)))
                            (fl 0) (fl 1)))
      ;; a vector that can plausibly be zero is divided by a floored
      ;; length, never normalized: normalize(0) is NaN, and a NaN
      ;; fragment is black with nothing to say why
      (local vec2 dir (/ uv (max (length uv) "0.00001")))
      (local float rim (* (fl 0 30) (+ (fl 1) dir.y)))
      (local vec3 cool (vec3 "0.05" "0.08" "0.18"))
      (local vec3 warm (vec3 "0.38" "0.66" "1.0"))
      (set! gl_FragColor
            (vec4 (+ (mix cool warm k) (* warm rim)) (fl 1))))))

;; fx-fullscreen! pairs the forms with a built-in vertex shader and a
;; static 4-vertex triangle strip -- a shadertoy in three lines.
(define quad (fx-fullscreen! plasma))

;; Any other uniform is an ordinary fx-uniform! on the quad's own
;; program, and the control that drives it is built like any other.
(define warp 1.0)
(let ((s (create-element "input")))
  (set-attribute! s "type" "range")
  (set-attribute! s "min" "20")
  (set-attribute! s "max" "400")
  (set-attribute! s "value" "100")
  (append-child! (get-element-by-id "app") s)
  (add-event-listener! s "input"
    (lambda (ev)
      (set! warp (fl/ (num (js-get (js-get ev "target") "value")) 100.0))
      (js-undefined))))

(fx-loop!
 (lambda (t dt)
   (fx-fullscreen-use! quad t)          ; sets u_time / u_resolution
   (fx-uniform! (fx-quad-program quad) 'u_warp warp)
   (fx-fullscreen-draw! quad)))
