;; The Goeteia homepage — rendered by Goeteia, compiled in your browser.
;; The title is a WebGL particle cloud: GOETEIA as dot-matrix glyphs,
;; animated entirely in a vertex shader written as s-expressions.
;; Edit anything — the glyphs, the wave, the colors — and press Run.
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

;; ---- the title: dots become vertices ----
(define rows                           ; edit these and press Run!
  '(".###. .###. ##### ##### ##### ##### .###."
    "#...# #...# #.... ..#.. #.... ..#.. #...#"
    "#.... #...# #.... ..#.. #.... ..#.. #...#"
    "#.### #...# ####. ..#.. ####. ..#.. #####"
    "#...# #...# #.... ..#.. #.... ..#.. #...#"
    "#...# #...# #.... ..#.. #.... ..#.. #...#"
    ".###. .###. ##### ..#.. ##### ##### #...#"))

(define POS 4096)                      ; vertex (x,y) pairs, staging memory
(define count                          ; one particle per lit cell
  (let walk ((rs rows) (r 0) (n 0))
    (if (null? rs) n
        (let ((row (car rs)))
          (let scan ((c 0) (n n))
            (if (= c (string-length row))
                (walk (cdr rs) (+ r 1) n)
                (if (char=? (string-ref row c) #\#)
                    (begin
                      (%mem-f32-set! (+ POS (* 8 n))
                                     (fl* (fixnum->flonum (- c 20)) 0.0425))
                      (%mem-f32-set! (+ POS (* 8 n) 4)
                                     (fl* (fixnum->flonum (- 3 r)) 0.21))
                      (scan (+ c 1) (+ n 1)))
                    (scan (+ c 1) n))))))))

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
       ;; a 6-second cycle: hold, burst apart, spiral home --
       ;; each dot staggered a little by its seed
       (local float ph (- (fract (/ u_time (fl 6))) (* seed (fl 0 8))))
       (local float e (* (smoothstep (fl 0 52) (fl 0 70) ph)
                         (- (fl 1) (smoothstep (fl 0 78) (fl 0 97) ph))))
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

(cmd-begin!)                           ; upload the vertices once
(cmd-bind-buffer! 1)
(cmd-buffer-data! POS (* 8 count))
(cmd-vertex-attrib! 0 2 0 0)
(cmd-flush!)

(define t 0.0)
(define (frame!)
  (set! t (fl+ t 0.016))
  (cmd-begin!)
  (cmd-viewport! 0 0 720 180)
  (cmd-clear! 0.0 0.0 0.0 0.0)         ; transparent: dots float on the page
  (cmd-use-program! 0)
  (cmd-uniform1f! 2 t)
  (cmd-uniform1f! 3 shift)
  (cmd-draw-arrays! GL-POINTS 0 count)
  (cmd-flush!))

;; re-running this source bumps the generation; the old loop sees it
;; and lets go
(js-eval "globalThis.__hero_gen = (globalThis.__hero_gen || 0) + 1")
(define gen (js->number (js-get (js-global) "__hero_gen")))
(letrec ((tick (lambda _
                 (when (= gen (js->number (js-get (js-global) "__hero_gen")))
                   (frame!)
                   (js-method (js-global) "requestAnimationFrame" tick)))))
  (js-method (js-global) "requestAnimationFrame" tick))
