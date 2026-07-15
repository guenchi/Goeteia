;; The Goeteia homepage — rendered by Goeteia, compiled in your browser.
;; The title and the tagline are GPU particles: (web typeset) lays the texts
;; out, their pixels become home positions, and a transform-feedback
;; shader — the physics IS the vertex shader.
;; Edit anything and press Run: the words, the fonts, the forces, the palette.
(import (web sx) (web dom) (web reactive) (web js)
        (gfx gl) (gfx glsl) (gfx fx)
        (web typeset) (web canvas) (web glyphs))

;; ---- the page ----
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero") (translate "no"))
        (canvas (@ (id "gl-title") (width "720") (height "230")
                   (role "img")
                   (aria-label "Γοητεία — The black ars of commanding what lies beneath.")
                   (style "display:block;width:100%;max-width:40em")))
        (div (@ (id "sub-flow") (class "sub")
                (style "position:relative;height:1.6em;font:17px system-ui,sans-serif;max-width:40em")))
        (pre (@ (class "cmd")) "$ npm install goeteia")
        (div (@ (class "links"))
          (a (@ (class "btn primary") (href "#editor")) "Try it now")
          (a (@ (class "btn") (href "https://github.com/guenchi/Goeteia")) "GitHub")))))

(fx-init! (get-element-by-id "gl-title"))

;; ---- rasterize the words on a hidden canvas ----
(define title-font "italic 700 92px Georgia, 'Times New Roman', serif")
(define lead-font "italic 700 26px Georgia, 'Times New Roman', serif")
(define tag-font "italic 24px Georgia, 'Times New Roman', serif")

(define hidden (create-element "canvas"))
(js-set! hidden "width" 720)
(js-set! hidden "height" 230)
(js-set! (js-global) "__hero_cv" hidden)
;; the sampler reads this canvas back repeatedly: say so, and the
;; browser keeps it off the GPU (and stops warning about it)
(define hctx
  (js-eval "globalThis.__hero_cv.getContext('2d', { willReadFrequently: true })"))
(js-set! hctx "fillStyle" "#fff")
(js-set! hctx "textBaseline" "top")

;; typeset measures and flows; the 2d canvas rasterizes
(define (draw-lines! text font y0 lh)
  (js-set! hctx "font" font)
  (let ((l (layout (prepare text (canvas-measurer font)) 690.0 lh)))
    (for-each
     (lambda (ln)
       (js-method hctx "fillText" (line-text ln)
                  (fl/ (fl- 720.0 (line-width ln)) 2.0)
                  (fl+ y0 (line-y ln))))
     (layout-lines l))))
(define (draw-at! text font x y)
  (js-set! hctx "font" font)
  (js-method hctx "fillText" text x y))
(define (clear!) (js-method hctx "clearRect" 0 0 720 230))

;; lit pixels -> home positions, in Scheme: ONE bulk Uint8Array.set
;; copies the canvas pixels into staging memory, then a plain byte
;; scan turns every step-th pixel whose alpha clears 100 into a home
;; (x y) pair at base.  The view is built fresh per call: fx-alloc!
;; may have grown (and so detached) the buffer since the last one.
(define samp-px (fx-alloc! (* 720 230 4)))
(define (sample! base max step)
  (let* ((img (js-method hctx "getImageData" 0 0 720 230))
         (view (js-new (js-get (js-global) "Uint8Array")
                       (js-get (js-get (js-global) "__goeteia_mem")
                               "buffer")
                       samp-px (* 720 230 4))))
    (js-method view "set" (js-get img "data"))
    (let yloop ((y 0) (n 0))
      (if (>= y 230)
          n
          (let xloop ((x 0) (n n))
            (cond
             ((>= x 720) (yloop (+ y step) n))
             ((and (< n max)
                   (> (%mem-u8-ref
                       (+ samp-px (+ (* (+ (* y 720) x) 4) 3)))
                      100))
              (%mem-f32-set! (+ base (* n 8)) (fixnum->flonum x))
              (%mem-f32-set! (+ base (+ (* n 8) 4)) (fixnum->flonum y))
              (xloop (+ x step) (+ n 1)))
             (else (xloop (+ x step) n))))))))

;; ---- particle state: pos2 vel2 homeA2 homeB2 seed block = 40B ----
(define CAP 16000)
(define samp-a (fx-alloc! (* CAP 8)))
(define samp-b (fx-alloc! (* CAP 8)))
(define state (fx-alloc! (* CAP 40)))

(define seed 99)
(define (rnd!)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))

;; one particle: scattered start, its two homes, its block's palette
(define (state! i ax ay bx by block)
  (let ((at (+ state (* i 40))))
    (%mem-f32-set! at (fl* 720.0 (rnd!)))
    (%mem-f32-set! (+ at 4) (fl* 230.0 (rnd!)))
    (%mem-f32-set! (+ at 8) 0.0)
    (%mem-f32-set! (+ at 12) 0.0)
    (%mem-f32-set! (+ at 16) ax)
    (%mem-f32-set! (+ at 20) ay)
    (%mem-f32-set! (+ at 24) bx)
    (%mem-f32-set! (+ at 28) by)
    (%mem-f32-set! (+ at 32) (rnd!))
    (%mem-f32-set! (+ at 36) (fixnum->flonum block))))
(define (samp-x s i) (%mem-f32-ref (+ s (* 8 i))))
(define (samp-y s i) (%mem-f32-ref (+ s (* 8 i) 4)))

;; the title: TWO spellings sampled into A and B homes; the smaller
;; word parks its spare dots off the sides, so they fly in and out
(clear!) (draw-lines! "GOETEIA" title-font 8.0 116.0)
(define na (sample! samp-a CAP 2))
(clear!) (draw-lines! "ΓΟΗΤΕΙΑ" title-font 8.0 116.0)
(define nb (sample! samp-b CAP 2))
(define pool (max na nb))
(define (park) (if (fl<? (rnd!) 0.5)
                   (fl- 0.0 (fl+ 40.0 (fl* 60.0 (rnd!))))
                   (fl+ 760.0 (fl* 60.0 (rnd!)))))
(let fill ((i 0))
  (when (< i pool)
    (state! i
            (if (< i na) (samp-x samp-a i) (park))
            (if (< i na) (samp-y samp-a i) (fl* 230.0 (rnd!)))
            (if (< i nb) (samp-x samp-b i) (park))
            (if (< i nb) (samp-y samp-b i) (fl* 230.0 (rnd!)))
            0)
    (fill (+ i 1))))

;; the second row -- an azure Γοητεία leading the tagline -- and the
;; subtitle: fixed homes (A = B), centered together by measured width
(define count
  (let* ((lead "Γοητεία")
         (tag "The black ars of commanding what lies beneath.")
         (w0 ((canvas-measurer lead-font) lead))
         (w1 ((canvas-measurer tag-font) tag))
         (x0 (fl/ (fl- 720.0 (fl+ w0 (fl+ 12.0 w1))) 2.0))
         (add! (lambda (n block)
                 (let ((got (sample! samp-a (- CAP n) 1)))
                   (let fill ((i 0) (k n))
                     (if (= i got)
                         k
                         (begin (state! k (samp-x samp-a i)
                                        (samp-y samp-a i)
                                        (samp-x samp-a i)
                                        (samp-y samp-a i) block)
                                (fill (+ i 1) (+ k 1)))))))))
    (clear!) (draw-at! lead lead-font x0 160.0)
    (let ((n1 (add! pool 1)))
      (clear!) (draw-at! tag tag-font (fl+ x0 (fl+ w0 12.0)) 163.0)
      (add! n1 2))))

;; ---- the subtitle: whole characters that dodge the cursor ----
;; (web glyphs) explodes the text into per-glyph spans and owns the
;; pointer/scroll/resize listeners; the GL loop drives the steps
(define sub-el (get-element-by-id "sub-flow"))
(set-style! sub-el "textAlign" "center")
(set-text! sub-el "A pure-Scheme web toolkit, compiled to WebAssembly.")
(define sub-glyphs (glyphs! sub-el))
(glyphs-track! (list sub-glyphs))

;; ---- the update step: the vertex shader IS the physics ----
(define update-p
  (fx-tf-program!
   '((attribute vec2 a_pos)
     (attribute vec2 a_vel)
     (attribute vec2 a_homea)
     (attribute vec2 a_homeb)
     (attribute float a_seed)
     (attribute float a_block)
     (uniform vec2 u_mouse)
     (uniform float u_dt)
     (uniform float u_t)
     (varying vec2 v_pos)
     (varying vec2 v_vel)
     (varying vec2 v_homea)
     (varying vec2 v_homeb)
     (varying float v_seed)
     (varying float v_block)
     (define (main) void
       ;; a 12s cycle: hold, glide to the other spelling, hold, back
       (local float cyc (fract (/ u_t (fl 12))))
       (local float m (* (smoothstep "0.38" "0.5" cyc)
                         (- (fl 1) (smoothstep "0.88" (fl 1) cyc))))
       (local vec2 home (mix a_homea a_homeb m))
       ;; a whisper of life at rest
       (set! home (+ home (* (vec2 (sin (+ (* u_t "1.3")
                                           (* a_seed "6.28")))
                                   (cos (+ (* u_t "1.7")
                                           (* a_seed "6.28"))))
                             "0.6")))
       ;; the cursor pushes hard, fading out at ~230px
       (local vec2 dm (- a_pos u_mouse))
       (local float r2 (+ (dot dm dm) (fl 100)))
       (local float inf (max (- (fl 1) (* r2 "0.0000189")) (fl 0)))
       (local vec2 rep (* (/ dm r2) (* "260000.0" inf)))
       ;; home pulls, slightly underdamped for a lively settle
       (local vec2 spring (* (- home a_pos) (fl 24)))
       (local vec2 vel (* (+ a_vel (* (+ spring rep) u_dt))
                          (max (- (fl 1) (* (fl 8) u_dt)) (fl 0))))
       (set! v_pos (+ a_pos (* vel u_dt)))
       (set! v_vel vel)
       (set! v_homea a_homea)
       (set! v_homeb a_homeb)
       (set! v_seed a_seed)
       (set! v_block a_block)
       (set! gl_Position (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))))

;; ---- the draw step: the title in the site's lapis-to-azure
;; gradient, the lead word azure, the prose dim; sparks glint as
;; they fly ----
(define draw-p
  (fx-program3!
   '((attribute vec2 a_pos)
     (attribute vec2 a_vel)
     (attribute vec2 a_homea)
     (attribute vec2 a_homeb)
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
       (set! gl_PointSize (+ (- "3.0" (* (min a_block (fl 1)) "1.5"))
                             (* a_seed "0.7")))
       (set! v_hx (/ a_homea.x u_res.x))
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
       (local vec3 azure (vec3 "0.30" "0.55" "0.92"))
       (local vec3 dim (vec3 "0.33" "0.38" "0.48"))
       (local vec3 c (mix lapis azure v_hx))
       (set! c (mix c azure (* (step "0.5" v_block)
                               (- (fl 1) (step "1.5" v_block)))))
       (set! c (mix c dim (step "1.5" v_block)))
       ;; flight makes them glint toward sky blue
       (set! c (mix c (vec3 "0.55" "0.78" (fl 1))
                    (min (* v_speed "0.0035") "0.7")))
       (set! gl_FragColor
             (vec4 c (- (fl 1) (smoothstep "0.04" "0.25" d2))))))))

;; ---- two buffers ping-pong; upload the start state once ----
(define buf-a (fx-buffer!))
(define buf-b (fx-buffer!))
(cmd-begin!)
(cmd-bind-buffer! buf-a)
(cmd-buffer-data! state (* count 40))
(cmd-bind-buffer! buf-b)
(cmd-buffer-data! state (* count 40))
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
;; fx-use! rides vertex array objects now: the four
;; (program, buffer) pairs of the ping-pong record their six
;; attribute pointers once, in the first two frames -- after that
;; each use is a one-word VAO rebind instead of six pointer setups
(define front buf-a)
(define back buf-b)
(define t 0.0)
(define (frame!)
  (set! t (fl+ t 0.016))
  (when (fl<? 3768.0 t) (set! t (fl- t 3768.0)))  ; 314 cycles, f32-safe
  (cmd-begin!)
  (fx-use! update-p front)
  (fx-uniform! update-p 'u_mouse mx my)
  (fx-uniform! update-p 'u_dt 0.016)
  (fx-uniform! update-p 'u_t t)
  (cmd-tf-buffer! back)
  (cmd-tf-begin!)
  (cmd-draw-arrays! GL-POINTS 0 count)
  (cmd-tf-end!)
  (cmd-viewport! 0 0 720 230)
  (cmd-clear! 0.0 0.0 0.0 0.0)         ; transparent: dots on the page
  (cmd-blend! 'alpha)
  (fx-use! draw-p back)
  (fx-uniform! draw-p 'u_res 720.0 230.0)
  (cmd-draw-arrays! GL-POINTS 0 count)
  (cmd-flush!)
  (glyphs-step! sub-glyphs)
  (let ((tmp front)) (set! front back) (set! back tmp)))

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
