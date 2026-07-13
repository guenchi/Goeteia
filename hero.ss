;; The Goeteia homepage — rendered by Goeteia, compiled in your browser.
;; The title, the tagline and the subtitle are ~12,000 GPU particles:
;; (web typeset) lays the three texts out, their pixels become home
;; positions, and a transform-feedback shader — the physics runs on
;; the GPU, Scheme never touches a particle — springs each one home
;; while your cursor scatters them.  Edit anything and press Run:
;; the texts, the fonts, the forces, the palette.
(import (web sx) (web dom) (web reactive) (web js)
        (web gl) (web glsl) (web fx)
        (web typeset) (web typeset canvas))

;; ---- the page ----
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "gl-title") (width "720") (height "280")
                   (role "img")
                   (aria-label "Γοητεία — The black ars of commanding what lies beneath. A pure-Scheme web toolkit, compiled to WebAssembly.")
                   (style "display:block;width:100%;max-width:40em")))
        (pre (@ (class "cmd")) "$ npm install goeteia")
        (div (@ (class "links"))
          (a (@ (class "btn primary") (href "#editor")) "Try it now")
          (a (@ (class "btn") (href "https://github.com/guenchi/Goeteia")) "GitHub")))))

(fx-init! (get-element-by-id "gl-title"))

;; ---- the three texts, typeset then rasterized ----
;; each block: text, CSS font, top y, line height (px)
(define blocks
  (list (list "Γοητεία"
              "italic 700 96px Georgia, 'Times New Roman', serif"
              6.0 120.0)
        (list "The black ars of commanding what lies beneath."
              "italic 24px Georgia, 'Times New Roman', serif"
              158.0 30.0)
        (list "A pure-Scheme web toolkit, compiled to WebAssembly."
              "17px system-ui, sans-serif"
              218.0 22.0)))

(define hidden (create-element "canvas"))
(js-set! hidden "width" 720)
(js-set! hidden "height" 280)
(define hctx (js-method hidden "getContext" "2d"))
(js-set! (js-global) "__hero_cv" hidden)
(js-set! hctx "fillStyle" "#fff")
(js-set! hctx "textBaseline" "top")

;; typeset flows the text (wraps on narrow layouts), centers each
;; line by its measured width, and the 2d canvas rasterizes it
(define (draw-block! text font y0 lh)
  (js-method hctx "clearRect" 0 0 720 280)
  (js-set! hctx "font" font)
  (let ((l (layout (prepare text (canvas-measurer font))
                   690.0 lh)))
    (for-each
     (lambda (ln)
       (js-method hctx "fillText" (line-text ln)
                  (fl/ (fl- 720.0 (line-width ln)) 2.0)
                  (fl+ y0 (line-y ln))))
     (layout-lines l))))

;; lit pixels -> home positions, written straight into wasm memory
(js-eval "globalThis.__hero_sample = (base, max, step) => {
  const cv = globalThis.__hero_cv;
  const d = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data;
  const f = new Float32Array(globalThis.__goeteia_mem.buffer);
  let n = 0;
  for (let y = 0; y < cv.height; y += step)
    for (let x = 0; x < cv.width; x += step) {
      if (d[(y * cv.width + x) * 4 + 3] > 100 && n < max) {
        f[(base >> 2) + n * 2] = x;
        f[(base >> 2) + n * 2 + 1] = y;
        n++; } }
  return n; }")

;; ---- particle state: pos2 vel2 home2 seed block, 32 bytes each ----
(define CAP 16000)
(define samp (fx-alloc! (* CAP 8)))
(define state (fx-alloc! (* CAP 32)))

(define seed 99)
(define (rnd!)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))

;; sample each block, giving small text a denser step so it reads
(define count
  (let block ((bs blocks) (bi 0) (n 0))
    (if (null? bs)
        n
        (let* ((b (car bs)))
          (draw-block! (car b) (cadr b) (caddr b) (cadddr b))
          (let* ((step (if (= bi 0) 2 1))
                 (got (js->number
                       (js-call (js-get (js-global) "__hero_sample")
                                (js-undefined) samp (- CAP n) step))))
            ;; interleave: scattered start, home from the sample
            (let fill ((i 0))
              (when (< i got)
                (let ((at (+ state (* (+ n i) 32))))
                  (%mem-f32-set! at (fl* 720.0 (rnd!)))
                  (%mem-f32-set! (+ at 4) (fl* 280.0 (rnd!)))
                  (%mem-f32-set! (+ at 8) 0.0)
                  (%mem-f32-set! (+ at 12) 0.0)
                  (%mem-f32-set! (+ at 16) (%mem-f32-ref (+ samp (* 8 i))))
                  (%mem-f32-set! (+ at 20)
                                 (%mem-f32-ref (+ samp (* 8 i) 4)))
                  (%mem-f32-set! (+ at 24) (rnd!))
                  (%mem-f32-set! (+ at 28) (fixnum->flonum bi)))
                (fill (+ i 1))))
            (block (cdr bs) (+ bi 1) (+ n got)))))))

;; ---- the update step: the vertex shader IS the physics ----
(define update-p
  (fx-tf-program!
   '((attribute vec2 a_pos)
     (attribute vec2 a_vel)
     (attribute vec2 a_home)
     (attribute float a_seed)
     (attribute float a_block)
     (uniform vec2 u_mouse)
     (uniform float u_dt)
     (uniform float u_t)
     (varying vec2 v_pos)
     (varying vec2 v_vel)
     (varying vec2 v_home)
     (varying float v_seed)
     (varying float v_block)
     (define (main) void
       ;; a whisper of life at rest
       (local vec2 home (+ a_home
                           (* (vec2 (sin (+ (* u_t "1.3")
                                            (* a_seed "6.28")))
                                    (cos (+ (* u_t "1.7")
                                            (* a_seed "6.28"))))
                              "0.6")))
       ;; the cursor pushes, fading out at ~140px
       (local vec2 dm (- a_pos u_mouse))
       (local float r2 (+ (dot dm dm) (fl 100)))
       (local float inf (max (- (fl 1) (* r2 "0.000051")) (fl 0)))
       (local vec2 rep (* (/ dm r2) (* "60000.0" inf)))
       ;; home pulls, slightly underdamped for a lively settle
       (local vec2 spring (* (- home a_pos) (fl 24)))
       (local vec2 vel (* (+ a_vel (* (+ spring rep) u_dt))
                          (max (- (fl 1) (* (fl 8) u_dt)) (fl 0))))
       (set! v_pos (+ a_pos (* vel u_dt)))
       (set! v_vel vel)
       (set! v_home a_home)
       (set! v_seed a_seed)
       (set! v_block a_block)
       (set! gl_Position (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))))

;; ---- the draw step: soft round dots, the title in the site's own
;; lapis-to-azure gradient, sparks brighten as they fly ----
(define draw-p
  (fx-program3!
   '((attribute vec2 a_pos)
     (attribute vec2 a_vel)
     (attribute vec2 a_home)
     (attribute float a_seed)
     (attribute float a_block)
     (uniform vec2 u_res)
     (varying float v_hx)
     (varying float v_speed)
     (varying float v_block)
     (define (main) void
       (set! gl_Position
             (vec4 (- (* (/ a_pos.x u_res.x) (fl 2)) (fl 1))
                   (- (fl 1) (* (/ a_pos.y u_res.y) (fl 2)))
                   (fl 0) (fl 1)))
       (set! gl_PointSize (+ (- "2.8" (* (min a_block (fl 1)) "1.3"))
                             (* a_seed "0.7")))
       (set! v_hx (/ a_home.x u_res.x))
       (set! v_speed (length a_vel))
       (set! v_block a_block)))
   '((precision mediump float)
     (varying float v_hx)
     (varying float v_speed)
     (varying float v_block)
     (define (main) void
       (local vec2 pc (- gl_PointCoord (vec2 (fl 0 50) (fl 0 50))))
       (local float d2 (dot pc pc))
       (local vec3 lapis (vec3 "0.05" "0.19" "0.48"))
       (local vec3 azure (vec3 "0.35" "0.62" "0.96"))
       (local vec3 dim (vec3 "0.33" "0.38" "0.48"))
       (local vec3 c (mix (mix lapis azure v_hx) dim
                          (min v_block (fl 1))))
       ;; flight makes them glint toward sky blue
       (set! c (mix c (vec3 "0.55" "0.78" (fl 1))
                    (min (* v_speed "0.004") "0.65")))
       (set! gl_FragColor
             (vec4 c (- (fl 1) (smoothstep "0.04" "0.25" d2))))))))

;; ---- two buffers ping-pong; upload the start state once ----
(define buf-a (fx-buffer!))
(define buf-b (fx-buffer!))
(cmd-begin!)
(cmd-bind-buffer! buf-a)
(cmd-buffer-data! state (* count 32))
(cmd-bind-buffer! buf-b)
(cmd-buffer-data! state (* count 32))
(cmd-flush!)

;; ---- the cursor, in canvas pixels (parked far away when outside) ----
(define cvs (get-element-by-id "gl-title"))
(define mx -9999.0)
(define my -9999.0)
(define ($fl v) (if (flonum? v) v (exact->inexact v)))
(add-event-listener! cvs "pointermove"
  (lambda (e)
    (let* ((cw ($fl (js->number (js-get cvs "clientWidth"))))
           (s (if (fl<? cw 1.0) 1.0 (fl/ 720.0 cw))))
      (set! mx (fl* ($fl (js->number (js-get e "offsetX"))) s))
      (set! my (fl* ($fl (js->number (js-get e "offsetY"))) s)))
    (js-undefined)))
(add-event-listener! cvs "pointerleave"
  (lambda (e)
    (set! mx -9999.0)
    (set! my -9999.0)
    (js-undefined)))

;; ---- one bridge call per frame; Scheme only counts time ----
(define bufs (cons buf-a buf-b))
(define t 0.0)
(define (frame!)
  (set! t (fl+ t 0.016))
  (cmd-begin!)
  (fx-use! update-p (car bufs))
  (fx-uniform! update-p 'u_mouse mx my)
  (fx-uniform! update-p 'u_dt 0.016)
  (fx-uniform! update-p 'u_t t)
  (cmd-tf-buffer! (cdr bufs))
  (cmd-tf-begin!)
  (cmd-draw-arrays! GL-POINTS 0 count)
  (cmd-tf-end!)
  (cmd-viewport! 0 0 720 280)
  (cmd-clear! 0.0 0.0 0.0 0.0)         ; transparent: dots on the page
  (cmd-blend! 'alpha)
  (fx-use! draw-p (cdr bufs))
  (fx-uniform! draw-p 'u_res 720.0 280.0)
  (cmd-draw-arrays! GL-POINTS 0 count)
  (cmd-flush!)
  (set! bufs (cons (cdr bufs) (car bufs))))

;; re-running this source bumps the generation; the old loop lets go
(let ((v (js-get (js-global) "__hero_gen")))
  (js-set! (js-global) "__hero_gen"
           (+ 1 (if (js-truthy? v) (js->number v) 0))))
(define gen (js->number (js-get (js-global) "__hero_gen")))
(letrec ((tick (lambda _
                 (when (= gen (js->number (js-get (js-global) "__hero_gen")))
                   (frame!)
                   (js-method (js-global) "requestAnimationFrame" tick)))))
  (js-method (js-global) "requestAnimationFrame" tick))
