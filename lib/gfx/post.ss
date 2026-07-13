;; Post-processing passes over (gfx fx): the chains every effect
;; rebuilds -- threshold, separable gaussian, composite -- packaged
;; once.  fx-bloom, fx-ssao and the Igropyr fire each hand-wrote
;; these; this is that code, made a library.
;;
;;   (define bloom (make-bloom 400 300))
;;   ... per frame, after the scene renders into an (HDR) target:
;;   (bloom-run! bloom (fx-target-texture scene) 1.0 2.0)
;;   (bloom-composite! bloom (fx-target-texture scene) #f 'reinhard 1.1)
;;
;; make-bloom builds its targets at the given (usually half) size;
;; bloom-run! thresholds the source by luminance (smoothstep between
;; the two edges, so the cutoff has no hard edge) and ping-pongs a
;; 9-tap separable gaussian twice; bloom-composite! adds the glow
;; over the source into a target (or the canvas for #f), with 'none,
;; 'clamp (hue-preserving normalize) or 'reinhard (extended, lows
;; pass untouched) as the tonemap.
;;
;; The lower floors are exported too: post-quad! wraps fullscreen
;; fragment forms, post-pass! points one at a target with textures
;; and uniforms, and make-blur/blur-run! is the gaussian alone (blur
;; anything: shadows, AO, glow).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx post)
  (export post-quad! post-pass!
          make-blur blur-run! blur-texture
          make-bloom bloom-run! bloom-texture bloom-composite!
          make-fxaa fxaa-run! make-grade grade-run!
          make-dof dof-run!)
  (import (rnrs) (gfx gl) (gfx glsl) (gfx fx))

  ;; ---- the floor: one fullscreen pass ----
  (define (post-quad! fs-forms) (fx-fullscreen! fs-forms))

  ;; run quad `q` into target `tgt` (#f = the canvas); `setup`
  ;; receives the program to bind textures / set uniforms
  (define (post-pass! q tgt setup)
    (if tgt (fx-bind-target! tgt) (fx-bind-canvas!))
    (fx-fullscreen-use! q 0.0)
    (setup (fx-quad-program q))
    (fx-fullscreen-draw! q))

  ;; ---- the separable gaussian, ping-ponged ----
  (define-record-type ($blur $make-blur blur?)
    (fields (immutable a $blur-a)
            (immutable b $blur-b)
            (immutable q $blur-q)
            (immutable w $blur-w)
            (immutable h $blur-h)))

  (define $blur-fs
    '((precision mediump float)
      (uniform sampler2D u_src)
      (uniform vec2 u_texel)
      (uniform vec2 u_dir)
      (define (tap (vec2 uv) (float o) (float w)) vec3
        (local vec4 c (texture2D u_src (+ uv (* (* u_dir u_texel) o))))
        (return (* c.rgb w)))
      (define (main) void
        (local vec2 uv (* gl_FragCoord.xy u_texel))
        (local vec3 acc (tap uv (fl 0) "0.227027"))
        (set! acc (+ acc (tap uv (fl 1) "0.1945946")))
        (set! acc (+ acc (tap uv (- (fl 1)) "0.1945946")))
        (set! acc (+ acc (tap uv (fl 2) "0.1216216")))
        (set! acc (+ acc (tap uv (- (fl 2)) "0.1216216")))
        (set! acc (+ acc (tap uv (fl 3) "0.054054")))
        (set! acc (+ acc (tap uv (- (fl 3)) "0.054054")))
        (set! acc (+ acc (tap uv (fl 4) "0.016216")))
        (set! acc (+ acc (tap uv (- (fl 4)) "0.016216")))
        (set! gl_FragColor (vec4 acc (fl 1))))))

  (define (make-blur w h)
    ($make-blur (fx-target! w h) (fx-target! w h)
                (post-quad! $blur-fs) w h))

  ;; run `passes` H+V rounds over src-tex; the result is
  ;; (blur-texture bl)
  (define (blur-run! bl src-tex passes)
    (let* ((q ($blur-q bl))
           (tx (fl/ 1.0 (fixnum->flonum ($blur-w bl))))
           (ty (fl/ 1.0 (fixnum->flonum ($blur-h bl))))
           (one! (lambda (src dst dx dy)
                   (post-pass! q dst
                               (lambda (p)
                                 (cmd-bind-texture! 0 src)
                                 (fx-uniform! p 'u_src 0)
                                 (fx-uniform! p 'u_texel tx ty)
                                 (fx-uniform! p 'u_dir dx dy))))))
      (let round ((k 0) (src src-tex))
        (if (= k passes)
            src
            (begin
              (one! src ($blur-a bl) 1.0 0.0)
              (one! (fx-target-texture ($blur-a bl)) ($blur-b bl)
                    0.0 1.0)
              (round (+ k 1)
                     (fx-target-texture ($blur-b bl))))))))

  (define (blur-texture bl) (fx-target-texture ($blur-b bl)))

  ;; ---- bloom: threshold + blur + composite ----
  (define-record-type ($bloom $make-bloom bloom?)
    (fields (immutable bright $bloom-bright)
            (immutable blur $bloom-blur)
            (immutable tq $bloom-tq)
            (immutable cq $bloom-cq)
            (immutable w $bloom-w)
            (immutable h $bloom-h)))

  (define $threshold-fs
    '((precision mediump float)
      (uniform sampler2D u_scene)
      (uniform vec2 u_texel)
      (uniform vec2 u_edges)             ; smoothstep lo / hi
      (define (main) void
        (local vec2 uv (* gl_FragCoord.xy u_texel))
        (local vec4 c (texture2D u_scene uv))
        (local float l (dot c.rgb (vec3 "0.2126" "0.7152" "0.0722")))
        (set! gl_FragColor
              (vec4 (* c.rgb (smoothstep u_edges.x u_edges.y l))
                    (fl 1))))))

  (define $composite-fs
    '((precision mediump float)
      (uniform sampler2D u_scene)
      (uniform sampler2D u_glow)
      (uniform vec2 u_texel)
      (uniform float u_gain)
      (uniform float u_mode)             ; 0 none, 1 clamp, 2 reinhard
      (define (main) void
        (local vec2 uv (* gl_FragCoord.xy u_texel))
        (local vec4 c (texture2D u_scene uv))
        (local vec4 g (texture2D u_glow uv))
        (local vec3 one (vec3 (fl 1) (fl 1) (fl 1)))
        (local vec3 sum (+ c.rgb (* g.rgb u_gain)))
        ;; 'clamp: hue-preserving normalize -- at or below 1 passes
        (local float mx (max (max sum.r sum.g) sum.b))
        (local vec3 clamped (/ sum (max mx (fl 1))))
        ;; 'reinhard (extended): lows pass, highs roll toward white
        (local vec3 rein (* sum (/ (+ one (/ sum "9.0")) (+ one sum))))
        (set! sum (mix sum clamped
                       (* (step (fl 0 50) u_mode)
                          (- (fl 1) (step (fl 1 50) u_mode)))))
        (set! sum (mix sum rein (step (fl 1 50) u_mode)))
        (set! gl_FragColor (vec4 sum c.a)))))

  (define (make-bloom w h)
    ($make-bloom (fx-target! w h) (make-blur w h)
                 (post-quad! $threshold-fs)
                 (post-quad! $composite-fs)
                 w h))

  ;; threshold src-tex between the luminance edges, blur twice; the
  ;; glow lands in (bloom-texture b)
  (define (bloom-run! b src-tex lo hi)
    (let ((tx (fl/ 1.0 (fixnum->flonum ($bloom-w b))))
          (ty (fl/ 1.0 (fixnum->flonum ($bloom-h b)))))
      (post-pass! ($bloom-tq b) ($bloom-bright b)
                  (lambda (p)
                    (cmd-bind-texture! 0 src-tex)
                    (fx-uniform! p 'u_scene 0)
                    (fx-uniform! p 'u_texel tx ty)
                    (fx-uniform! p 'u_edges lo hi)))
      (blur-run! ($bloom-blur b)
                 (fx-target-texture ($bloom-bright b)) 2)))

  (define (bloom-texture b) (blur-texture ($bloom-blur b)))

  ;; ---- FXAA: the classic screen-space anti-alias, one pass ----
  ;; Runs on DISPLAY-READY (gamma-encoded) color -- put it last.
  (define $fxaa-fs
    '((precision mediump float)
      (uniform sampler2D u_src)
      (uniform vec2 u_texel)
      (define (lum (vec4 c)) float
        (return (dot c.rgb (vec3 "0.299" "0.587" "0.114"))))
      (define (main) void
        (local vec2 uv (* gl_FragCoord.xy u_texel))
        (local float lNW (lum (texture2D u_src
                                (+ uv (* u_texel (vec2 (- (fl 1))
                                                       (- (fl 1))))))))
        (local float lNE (lum (texture2D u_src
                                (+ uv (* u_texel (vec2 (fl 1)
                                                       (- (fl 1))))))))
        (local float lSW (lum (texture2D u_src
                                (+ uv (* u_texel (vec2 (- (fl 1))
                                                       (fl 1)))))))
        (local float lSE (lum (texture2D u_src
                                (+ uv (* u_texel (vec2 (fl 1) (fl 1)))))))
        (local vec4 cM (texture2D u_src uv))
        (local float lM (lum cM))
        (local float lo (min lM (min (min lNW lNE) (min lSW lSE))))
        (local float hi (max lM (max (max lNW lNE) (max lSW lSE))))
        ;; the local gradient picks the edge direction
        (local vec2 dir (vec2 (- (+ lSW lSE) (+ lNW lNE))
                              (- (+ lNW lSW) (+ lNE lSE))))
        (local float dr (max (* (+ (+ lNW lNE) (+ lSW lSE)) "0.03125")
                             "0.0078125"))
        (local float rcp (/ (fl 1) (+ (min (abs dir.x) (abs dir.y)) dr)))
        (set! dir (* (clamp (* dir rcp)
                            (vec2 "-8.0" "-8.0") (vec2 "8.0" "8.0"))
                     u_texel))
        ;; two taps near, two far along the edge
        (local vec4 a (* (fl 0 50)
                         (+ (texture2D u_src (+ uv (* dir "-0.166667")))
                            (texture2D u_src (+ uv (* dir "0.166667"))))))
        (local vec4 b (+ (* a (fl 0 50))
                         (* "0.25"
                            (+ (texture2D u_src (+ uv (* dir "-0.5")))
                               (texture2D u_src (+ uv (* dir "0.5")))))))
        ;; the far blend overshot the local range: fall back to near
        (local float lB (lum b))
        (local float useA (min (+ (step lB lo) (step hi lB)) (fl 1)))
        (set! gl_FragColor (mix b a useA)))))

  (define (make-fxaa) (post-quad! $fxaa-fs))
  ;; src-tex is w x h; tgt #f = the canvas
  (define (fxaa-run! q src-tex tgt w h)
    (post-pass! q tgt
                (lambda (p)
                  (cmd-bind-texture! 0 src-tex)
                  (fx-uniform! p 'u_src 0)
                  (fx-uniform! p 'u_texel
                               (fl/ 1.0 (fixnum->flonum w))
                               (fl/ 1.0 (fixnum->flonum h))))))

  ;; ---- depth of field: blur by distance from the focal plane ----
  ;; Needs a linear-depth texture alongside the scene (the fx-ssao
  ;; pattern: view distance / far into the red channel).  The circle
  ;; of confusion is |depth - focus| / range, and it mixes the sharp
  ;; scene toward a half-resolution gaussian of itself.
  (define-record-type ($dof $make-dof dof?)
    (fields (immutable blur $dof-blur)
            (immutable cq $dof-cq)
            (immutable w $dof-w)
            (immutable h $dof-h)))

  (define $dof-fs
    '((precision mediump float)
      (uniform sampler2D u_scene)
      (uniform sampler2D u_soft)
      (uniform sampler2D u_depth)
      (uniform vec2 u_texel)
      (uniform float u_focus)            ; both in depth-texture units
      (uniform float u_range)
      (define (main) void
        (local vec2 uv (* gl_FragCoord.xy u_texel))
        (local vec4 sharp (texture2D u_scene uv))
        (local vec4 soft (texture2D u_soft uv))
        (local vec4 d (texture2D u_depth uv))
        (local float coc (clamp (/ (abs (- d.r u_focus)) u_range)
                                (fl 0) (fl 1)))
        (set! gl_FragColor (vec4 (mix sharp.rgb soft.rgb coc)
                                 sharp.a)))))

  (define (make-dof w h)
    ($make-dof (make-blur (quotient w 2) (quotient h 2))
               (post-quad! $dof-fs) w h))

  ;; focus and range live in the depth texture's units (distance /
  ;; far, if you rendered it that way); tgt #f = the canvas
  (define (dof-run! d scene-tex depth-tex tgt focus range)
    (blur-run! ($dof-blur d) scene-tex 2)
    (post-pass! ($dof-cq d) tgt
                (lambda (p)
                  (cmd-bind-texture! 0 scene-tex)
                  (cmd-bind-texture! 1 (blur-texture ($dof-blur d)))
                  (cmd-bind-texture! 2 depth-tex)
                  (fx-uniform! p 'u_scene 0)
                  (fx-uniform! p 'u_soft 1)
                  (fx-uniform! p 'u_depth 2)
                  (fx-uniform! p 'u_focus focus)
                  (fx-uniform! p 'u_range range)
                  (fx-uniform! p 'u_texel
                               (fl/ 1.0 (fixnum->flonum ($dof-w d)))
                               (fl/ 1.0 (fixnum->flonum ($dof-h d)))))))

  ;; ---- grade: exposure + tonemap + gamma, LINEAR in, display out ----
  ;; 'aces is the Narkowicz fit; 'reinhard the extended curve; 'none
  ;; just exposure + gamma.  Point HDR scene targets at this, then
  ;; (optionally) FXAA the result.
  (define $grade-fs
    '((precision mediump float)
      (uniform sampler2D u_src)
      (uniform vec2 u_texel)
      (uniform float u_exposure)
      (uniform float u_mode)             ; 0 none, 1 reinhard, 2 aces
      (define (main) void
        (local vec2 uv (* gl_FragCoord.xy u_texel))
        (local vec4 c (texture2D u_src uv))
        (local vec3 x (* c.rgb u_exposure))
        (local vec3 one (vec3 (fl 1) (fl 1) (fl 1)))
        (local vec3 rein (* x (/ (+ one (/ x "9.0")) (+ one x))))
        (local vec3 aces (clamp (/ (* x (+ (* x "2.51") (vec3 "0.03" "0.03" "0.03")))
                                   (+ (* x (+ (* x "2.43") (vec3 "0.59" "0.59" "0.59")))
                                      (vec3 "0.14" "0.14" "0.14")))
                                (vec3 (fl 0) (fl 0) (fl 0)) one))
        (set! x (mix x rein (* (step (fl 0 50) u_mode)
                               (- (fl 1) (step (fl 1 50) u_mode)))))
        (set! x (mix x aces (step (fl 1 50) u_mode)))
        (set! gl_FragColor
              (vec4 (pow x (vec3 "0.4545" "0.4545" "0.4545")) c.a)))))

  (define (make-grade) (post-quad! $grade-fs))
  (define (grade-run! q src-tex tgt mode exposure w h)
    (post-pass! q tgt
                (lambda (p)
                  (cmd-bind-texture! 0 src-tex)
                  (fx-uniform! p 'u_src 0)
                  (fx-uniform! p 'u_exposure exposure)
                  (fx-uniform! p 'u_mode
                               (case mode
                                 ((none) 0.0)
                                 ((reinhard) 1.0)
                                 ((aces) 2.0)
                                 (else (error 'grade-run!
                                              "unknown tonemap" mode))))
                  (fx-uniform! p 'u_texel
                               (fl/ 1.0 (fixnum->flonum w))
                               (fl/ 1.0 (fixnum->flonum h))))))

  ;; scene + glow into `tgt` (#f = the canvas); tonemap is 'none,
  ;; 'clamp or 'reinhard
  (define (bloom-composite! b src-tex tgt tonemap gain)
    (post-pass! ($bloom-cq b) tgt
                (lambda (p)
                  (cmd-bind-texture! 0 src-tex)
                  (cmd-bind-texture! 1 (bloom-texture b))
                  (fx-uniform! p 'u_scene 0)
                  (fx-uniform! p 'u_glow 1)
                  (fx-uniform! p 'u_gain gain)
                  (fx-uniform! p 'u_mode
                               (case tonemap
                                 ((none) 0.0)
                                 ((clamp) 1.0)
                                 ((reinhard) 2.0)
                                 (else (error 'bloom-composite!
                                              "unknown tonemap"
                                              tonemap))))
                  (let* ((cv (if tgt
                                 (fx-target-width tgt)
                                 (fx-width)))
                         (ch (if tgt
                                 (fx-target-height tgt)
                                 (fx-height))))
                    (fx-uniform! p 'u_texel
                                 (fl/ 1.0 (fixnum->flonum cv))
                                 (fl/ 1.0 (fixnum->flonum ch))))))))
