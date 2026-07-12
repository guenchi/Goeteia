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
                   (style "display:block;margin:0 auto;width:100%;max-width:40em")))
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
     (varying float v_hue)
     (varying float v_glow)
     (define (main) void
       ;; a wave rolls across the letters...
       (local float z (* (fl 0 12) (sin (+ (* u_time (fl 1 60))
                                           (* p.x (fl 4)) (* p.y (fl 2))))))
       ;; ...while the whole word sways in 3D
       (local float a (* (fl 0 45) (sin (* u_time (fl 0 70)))))
       (local float rx (- (* p.x (cos a)) (* z (sin a))))
       (local float rz (+ (* p.x (sin a)) (* z (cos a))))
       (local float s (/ (fl 1 35) (+ (fl 1 90) rz)))
       (set! gl_Position (vec4 (* rx s) (* (+ p.y (* z (fl 0 30))) s) (fl 0) (fl 1)))
       (set! gl_PointSize (* s (+ (fl 13) (* (fl 5) (sin (+ (* u_time (fl 2)) (* p.x (fl 8))))))))
       (set! v_hue (+ (* p.x (fl 0 60)) (* z (fl 3))))
       (set! v_glow s)))))

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
(cmd-region! 0)

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
