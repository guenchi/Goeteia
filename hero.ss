;; The Goeteia homepage — rendered by Goeteia, compiled in your browser.
;; The title is a WebGL particle cloud: dot-matrix glyphs that scatter,
;; then reassemble into the Greek Γοητεία, and back — the
;; flight is a vertex shader written as s-expressions, the swap a
;; single buffer re-upload hidden by the scatter.
;; Edit either pattern, the shader, or the colors — and press Run.
(import (web sx) (web dom) (web reactive) (web js) (web gl) (web glsl))

;; ---- the page ----
(define spell (signal "commanding what lies beneath"))

(define (black-ars)                    ; dynamic-wind, live
  (with-output-to-string
    (lambda ()
      (dynamic-wind
        (lambda () (display "The "))
        (lambda () (display "black "))
        (lambda () (display "ars"))))))

(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "gl-title") (width "720") (height "180")
                   (style "display:block;width:100%;max-width:40em")))
        (p (@ (class "tagline"))
           (span (@ (class "gname")) "Γοητεία")
           " " ,(black-ars) " of " ,(signal-ref spell) ".")
        (p (@ (class "sub")) "A self-hosting Scheme for the WebAssembly GC era.")
        (pre (@ (class "cmd")) "$ git clone https://github.com/guenchi/Goeteia")
        (div (@ (class "links"))
          (a (@ (class "btn primary") (href "#editor")) "Try it now")
          (a (@ (class "btn") (href "https://github.com/guenchi/Goeteia")) "GitHub")))))

;; ---- the two dot-matrix words: edit these and press Run! ----
(define pattern-a                      ; GOETEIA
  '(".###. .###. ##### ##### ##### ##### .###."
    "#...# #...# #.... ..#.. #.... ..#.. #...#"
    "#.... #...# #.... ..#.. #.... ..#.. #...#"
    "#.### #...# ####. ..#.. ####. ..#.. #####"
    "#...# #...# #.... ..#.. #.... ..#.. #...#"
    "#...# #...# #.... ..#.. #.... ..#.. #...#"
    ".###. .###. ##### ..#.. ##### ##### #...#"))
(define pattern-b                      ; ΓΟΗΤΕΙΑ
  '(".###. .###. #...# ##### ##### ##### .###."
    "#.... #...# #...# ..#.. #.... ..#.. #...#"
    "#.... #...# #...# ..#.. #.... ..#.. #...#"
    "#.... #...# ##### ..#.. ####. ..#.. #####"
    "#.... #...# #...# ..#.. #.... ..#.. #...#"
    "#.... #...# #...# ..#.. #.... ..#.. #...#"
    "#.... .###. #...# ..#.. ##### ##### #...#"))

;; a pattern's lit cells become (x . y) home positions
(define (cells rows)
  (let walk ((rs rows) (r 0) (acc '()))
    (if (null? rs) (reverse acc)
        (let ((row (car rs)))
          (let scan ((c 0) (acc acc))
            (if (= c (string-length row))
                (walk (cdr rs) (+ r 1) acc)
                (if (char=? (string-ref row c) #\#)
                    (scan (+ c 1)
                          (cons (cons (fl* (fixnum->flonum (- c 20)) 0.0425)
                                      (fl* (fixnum->flonum (- 3 r)) 0.21))
                                acc))
                    (scan (+ c 1) acc))))))))

(define POS 4096)                      ; vertex (x,y) pairs, staging memory
(define cells-a (cells pattern-a))
(define cells-b (cells pattern-b))
(define pool (max (length cells-a) (length cells-b)))

;; write one pattern's homes into the staging buffer; the smaller word
;; parks its spare dots off-screen, so they fly in / out at the edges
(define (write-cells! cs)
  (let loop ((cs cs) (i 0))
    (when (< i pool)
      (let ((x (if (pair? cs) (caar cs) 9.0))
            (y (if (pair? cs) (cdar cs) 9.0)))
        (%mem-f32-set! (+ POS (* 8 i)) x)
        (%mem-f32-set! (+ POS (* 8 i) 4) y)
        (loop (if (pair? cs) (cdr cs) '()) (+ i 1))))))

;; ---- the shaders, as s-expressions ----
(define vs
  (glsl->string
   '((attribute vec2 p)
     (uniform float u_time)
     (uniform float u_shift)
     (varying float v_hue)
     (varying float v_glow)
     (define (main) void
       ;; every dot hashes its own fate from its home position
       (local float seed (fract (* (sin (dot p (vec2 (fl 12 98) (fl 78 23))))
                                   (fl 43758 50))))
       (local float s2 (fract (* seed (fl 7 13))))
       ;; a 6-second cycle: hold the word, burst fully apart at the
       ;; midpoint (where the buffer swaps to the other word), spiral
       ;; back onto the new word. Each dot staggered a little by its seed.
       (local float ph (- (fract (/ u_time (fl 6))) (* seed (fl 0 5))))
       (local float e (* (smoothstep (fl 0 25) (fl 0 50) ph)
                         (- (fl 1) (smoothstep (fl 0 50) (fl 0 75) ph))))
       ;; flight: a personal direction that keeps turning, so dots
       ;; leave and return along spirals
       (local float ang (+ (* seed (fl 6 28)) (* u_time (fl 0 40))))
       (local vec2 pos (+ p (* (vec2 (cos ang) (sin ang))
                               (+ (fl 0 50) (* s2 (fl 0 90))) e)))
       ;; depth: scattered dots spread in z; held dots breathe gently
       (local float z (+ (* (- seed (fl 0 50)) (fl 1 40) e)
                         (* (fl 0 5) (- (fl 1) e)
                            (sin (+ (* u_time (fl 2)) (* p.x (fl 5)))))))
       (local float s (/ (fl 1 55) (+ (fl 1 90) z)))
       ;; project, then shift: wide screens align the glyphs with the
       ;; left-aligned hero text, narrow ones keep them centered
       (set! gl_Position (vec4 (- (* pos.x s) u_shift) (* pos.y s) (fl 0) (fl 1)))
       (set! gl_PointSize (* s (- (fl 12) (* (fl 4) e))))
       (set! v_hue (+ (* p.x (fl 0 60)) (* e (fl 0 80)) z))
       (set! v_glow (* s (- (fl 1) (* (fl 0 30) e))))))))

(define fs
  (glsl->string
   '((precision mediump float)
     (varying float v_hue)
     (varying float v_glow)
     (define (main) void
       (local vec2 d (- gl_PointCoord (vec2 (fl 0 50) (fl 0 50))))
       (if (> (dot d d) (fl 0 25)) (discard))    ; round dots
       (local vec3 lapis (vec3 (fl 0 8) (fl 0 31) (fl 0 77)))
       (local vec3 azure (vec3 (fl 0 35) (fl 0 62) (fl 0 96)))
       (local vec3 c (mix lapis azure (fract v_hue)))
       (set! gl_FragColor (vec4 (* c (+ (fl 0 60) (* (fl 0 50) v_glow))) (fl 1)))))))

;; ---- one bridge call per frame ----
(gl-attach! (get-element-by-id "gl-title"))
(gl-program! 0 vs fs)
(gl-buffer! 1)
(gl-uniform! 2 0 "u_time")
(gl-uniform! 3 0 "u_shift")
(cmd-region! 0)

;; match the page's own breakpoint: the hero text is left-aligned on
;; wide screens, centered on narrow ones
(define (title-shift)
  (if (js-truthy? (js-eval "matchMedia('(min-width: 64em)').matches"))
      0.25
      0.0))
(define shift (title-shift))
(add-event-listener! (js-global) "resize"
  (lambda (e) (set! shift (title-shift))))

(write-cells! cells-a)                 ; start on GOETEIA
(cmd-begin!)
(cmd-bind-buffer! 1)
(cmd-buffer-data! POS (* 8 pool))
(cmd-vertex-attrib! 0 2 0 0)
(cmd-flush!)

(define buffered 0)                    ; which word is in the buffer (0/1)
(define t 0.0)
(define (frame!)
  (set! t (fl+ t 0.016))
  ;; past the scatter midpoint we want the NEXT word loaded, so it is
  ;; already assembling by the time the dots converge; the swap lands
  ;; while every dot is flung apart, so it is invisible
  (let* ((r (fl/ t 6.0))
         (cyc (%fl->fx (flfloor r)))
         (phase (fl- r (fixnum->flonum cyc)))
         (want (remainder (if (fl<? 0.5 phase) (+ cyc 1) cyc) 2))
         (swap? (not (= want buffered))))
    (when swap?
      (write-cells! (if (= want 0) cells-a cells-b))
      (set! buffered want))
    (cmd-begin!)
    (cmd-viewport! 0 0 720 180)
    (cmd-clear! 0.0 0.0 0.0 0.0)       ; transparent: dots float on the page
    (when swap?                        ; re-upload the freshly written homes
      (cmd-bind-buffer! 1)
      (cmd-buffer-data! POS (* 8 pool)))
    (cmd-use-program! 0)
    (cmd-uniform1f! 2 t)
    (cmd-uniform1f! 3 shift)
    (cmd-draw-arrays! GL-POINTS 0 pool)
    (cmd-flush!)))

;; re-running this source bumps the generation; the old loop sees it
;; and lets go
(js-eval "globalThis.__hero_gen = (globalThis.__hero_gen || 0) + 1")
(define gen (js->number (js-get (js-global) "__hero_gen")))
(letrec ((tick (lambda _
                 (when (= gen (js->number (js-get (js-global) "__hero_gen")))
                   (frame!)
                   (js-method (js-global) "requestAnimationFrame" tick)))))
  (js-method (js-global) "requestAnimationFrame" tick))
