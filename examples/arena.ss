;; The arena: everything this stack grew, in one playable page.
;; Click to capture the mouse, WASD to run, SPACE to jump (onto the
;; crates), click to shoot the drifting orbs.  Clear a wave and a
;; bigger one spawns.
;;
;; The static world casts shadows for FREE: its depth map renders
;; once, on the first frame, and never again -- crates, walls and
;; floor never move, so the cached map serves every later frame
;; (the orbs are lit but don't cast; they're made of light).
;;
;; What is doing the work: (gfx collide)'s packaged character over
;; the broadphase grid steps at a fixed 120Hz (fx-loop-fixed!), the
;; shot is one ray-sphere per orb, the HUD is a (gfx sprite) batch
;; whose glyphs come from the same typeset measurer as the layout,
;; hits chirp through (aud sfx), and the scene is raw WebGL
;; through the (gfx fx) command buffer.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx collide) (web typeset)
        (gfx sprite) (aud sfx))

(fx-init! (get-element-by-id "c"))
(fx-init-input!)
(pointer-lock!)

;; the world program samples the cached shadow map: light-space
;; reprojection, a 3x3 PCF, then the usual directional shade
(define p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (uniform mat4 u_light_mvp)
     (varying vec3 v_normal)
     (varying vec4 v_shadow)
     (define (main) void
       (local vec4 w (vec4 a_pos (fl 1)))
       (set! gl_Position (* u_mvp w))
       (set! v_shadow (* u_light_mvp w))
       (set! v_normal (vec3 (* u_model (vec4 a_normal (fl 0)))))))
   '((precision mediump float)
     (uniform sampler2D u_shadow)
     (uniform vec3 u_light)
     (uniform vec4 u_color)
     (uniform vec2 u_texel)
     (uniform float u_ambient)
     (varying vec3 v_normal)
     (varying vec4 v_shadow)
     (define (main) void
       (local vec3 sp (+ (* (/ v_shadow.xyz v_shadow.w) (fl 0 50))
                         (vec3 (fl 0 50) (fl 0 50) (fl 0 50))))
       (local float lit (fl 0))
       (for (int x -1 (< x 2) (+ x 1))
         (for (int y -1 (< y 2) (+ y 1))
           (local vec4 sv (texture2D u_shadow
                                     (+ sp.xy (* (vec2 x y) u_texel))))
           (set! lit (+ lit (step (- sp.z "0.002") sv.r)))))
       (set! lit (/ lit (fl 9)))
       (local float d (max (dot (normalize v_normal) u_light) (fl 0)))
       (set! gl_FragColor
             (vec4 (* u_color.rgb
                      (+ u_ambient
                         (* (- (fl 1) u_ambient) (* d lit))))
                   u_color.a))))))

;; the depth-only pass, from the light: runs ONCE
(define depth-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) (fl 1) (fl 1) (fl 1)))))))

(define shadow-t (fx-target! 1024 1024 #t))
(define shadow-done #f)

;; ---- the room: floor, four walls, three crates ----
(define (upload m)
  (let* ((vbuf (fx-buffer!)) (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase (mesh-vertex-bytes m)
            (mesh-index-bytes m) (mesh-index-count m) #f)))

;; #(cx cy cz sx sy sz r g b) -- centers and sizes
(define solid-specs
  '(#(0.0 -0.5 0.0   28.0 1.0 28.0   0.32 0.36 0.44)   ; the floor
    #(0.0 2.0 -14.0  28.0 5.0 1.0    0.42 0.46 0.55)   ; north
    #(0.0 2.0 14.0   28.0 5.0 1.0    0.42 0.46 0.55)   ; south
    #(-14.0 2.0 0.0  1.0 5.0 28.0    0.42 0.46 0.55)   ; west
    #(14.0 2.0 0.0   1.0 5.0 28.0    0.42 0.46 0.55)   ; east
    #(-4.0 0.75 -3.0 2.4 1.5 2.4     0.75 0.55 0.35)   ; crates
    #(5.0 1.0 4.0    3.0 2.0 3.0     0.70 0.50 0.32)
    #(1.0 0.6 -7.0   2.0 1.2 2.0     0.78 0.60 0.40)))

(define solids
  (map (lambda (s)
         (let ((cx (vector-ref s 0)) (cy (vector-ref s 1))
               (cz (vector-ref s 2)) (sx (vector-ref s 3))
               (sy (vector-ref s 4)) (sz (vector-ref s 5)))
           (vector (upload (mesh-box sx sy sz))
                   (m4-translate cx cy cz)
                   (cons (v3 (fl- cx (fl/ sx 2.0)) (fl- cy (fl/ sy 2.0))
                             (fl- cz (fl/ sz 2.0)))
                         (v3 (fl+ cx (fl/ sx 2.0)) (fl+ cy (fl/ sy 2.0))
                             (fl+ cz (fl/ sz 2.0))))
                   (vector-ref s 6) (vector-ref s 7) (vector-ref s 8))))
       solid-specs))

(define grid (make-aabb-grid (map (lambda (s) (vector-ref s 2)) solids)
                             4.0))
(define orb-mesh (upload (mesh-sphere 0.55 24 12)))

;; ---- the orbs: a wave of drifting targets ----
(define seed 991)
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))

(define orbs '())                       ; each: #(x base-y z phase alive)
(define wave 0)
(define score 0)
(define (spawn-wave!)
  (set! wave (+ wave 1))
  (set! orbs
        (let make ((k 0) (acc '()))
          (if (= k (+ 2 wave))
              acc
              (make (+ k 1)
                    (cons (vector (fl- (fl* 22.0 (rand01)) 11.0)
                                  (fl+ 1.6 (fl* 2.2 (rand01)))
                                  (fl- (fl* 22.0 (rand01)) 11.0)
                                  (fl* 6.28 (rand01))
                                  #t)
                          acc))))))
(spawn-wave!)

(define (orb-pos o t)
  (v3 (vector-ref o 0)
      (fl+ (vector-ref o 1)
           (fl* 0.5 (flsin (fl+ t (vector-ref o 3)))))
      (vector-ref o 2)))

;; ---- the player ----
(define player (make-character (v3 0.0 0.51 9.0) 0.5))
(define yaw 0.0)
(define pitch 0.0)
(define now 0.0)                        ; render time, for the bob

(define (clamp v lo hi) (if (fl<? v lo) lo (if (fl<? hi v) hi v)))
(define (down? . ks)
  (let loop ((ks ks))
    (and (pair? ks) (or (key-down? (car ks)) (loop (cdr ks))))))

(define (fwd-dir)
  (let ((cp (flcos pitch)))
    (v3 (fl* cp (flsin yaw)) (flsin pitch)
        (fl* cp (fl- 0.0 (flcos yaw))))))
(define (eye-pos)
  (let ((pp (character-pos player)))
    (v3 (v3-x pp) (fl+ (v3-y pp) 0.5) (v3-z pp))))

;; ---- shooting: one ray against every living orb ----
(define (fire!)
  (let* ((o (eye-pos)) (d (fwd-dir)))
    (let scan ((os orbs) (best #f) (bd 0.0))
      (cond
       ((pair? os)
        (let* ((orb (car os))
               (hit (and (vector-ref orb 4)
                         (ray-sphere o d (orb-pos orb now) 0.55))))
          (if (and hit (or (not best) (fl<? hit bd)))
              (scan (cdr os) orb hit)
              (scan (cdr os) best bd))))
       (best
        (vector-set! best 4 #f)
        (set! score (+ score 1))
        (beep! 660 0.07 0.25)
        (beep! 990 0.05 0.2)
        (when (let all ((os orbs))
                (or (null? os)
                    (and (not (vector-ref (car os) 4))
                         (all (cdr os)))))
          (beep! 440 0.2 0.3)
          (spawn-wave!)))
       (else (beep! 150 0.05 0.15))))))

(define was-down #f)                    ; click edge, polled

;; ---- the HUD: sprite text over the 3D frame ----
(define atlas (make-atlas "700 22px system-ui" 22))
(define hud (make-batch atlas))
(define hud-text "")
(define hud-lay #f)
(define (hud! s)
  (unless (string=? s hud-text)
    (set! hud-text s)
    (set! hud-lay (layout (prepare s (atlas-measurer atlas))
                          800.0 (atlas-line-height atlas)))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define light (v3-normalize (v3 0.5 0.8 0.4)))
(define light-vp
  (m4-mul (m4-ortho -16.0 16.0 -16.0 16.0 1.0 60.0)
          (m4-look-at (v3-scale light 30.0) (v3 0.0 0.0 0.0)
                      (v3 0.0 1.0 0.0))))

(define (upload! obj)
  (unless (vector-ref obj 7)
    (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
    (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
    (vector-set! obj 7 #t)))

(define (draw-obj! obj model r g b vp)
  (fx-use! p (vector-ref obj 0))
  (cmd-bind-index! (vector-ref obj 1))
  (upload! obj)
  (fx-uniform! p 'u_mvp (m4-mul vp model))
  (fx-uniform! p 'u_model model)
  (fx-uniform! p 'u_light_mvp (m4-mul light-vp model))
  (fx-uniform! p 'u_color r g b 1.0)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6)))

;; the once-ever shadow bake: every static solid, from the light
(define (bake-shadows!)
  (fx-bind-target! shadow-t)
  (cmd-clear! 1.0 1.0 1.0 1.0)
  (cmd-depth! #t)
  (for-each (lambda (s)
              (let ((obj (vector-ref s 0)))
                (fx-use! depth-p (vector-ref obj 0))
                (cmd-bind-index! (vector-ref obj 1))
                (upload! obj)
                (fx-uniform! depth-p 'u_mvp
                             (m4-mul light-vp (vector-ref s 1)))
                (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6))))
            solids)
  (fx-bind-canvas!))

(fx-loop-fixed!
 0.0083333
 (lambda (step)                         ; physics at 120Hz
   (let ((fwx (flsin yaw)) (fwz (fl- 0.0 (flcos yaw)))
         (rtx (flcos yaw)) (rtz (flsin yaw))
         (vx 0.0) (vz 0.0))
     (when (down? "w" "W" "ArrowUp")
       (set! vx (fl+ vx fwx)) (set! vz (fl+ vz fwz)))
     (when (down? "s" "S" "ArrowDown")
       (set! vx (fl- vx fwx)) (set! vz (fl- vz fwz)))
     (when (down? "d" "D" "ArrowRight")
       (set! vx (fl+ vx rtx)) (set! vz (fl+ vz rtz)))
     (when (down? "a" "A" "ArrowLeft")
       (set! vx (fl- vx rtx)) (set! vz (fl- vz rtz)))
     (when (down? " ")
       (character-jump! player 8.0))
     (character-move! player (fl* 6.0 vx) (fl* 6.0 vz) step
                      (grid-near grid (character-pos player) 1.6))))
 (lambda (alpha t dt)
   (set! now t)
   ;; look, and the click edge fires
   (let ((d (pointer-motion!)))
     (set! yaw (fl+ yaw (fl* 0.0025 (car d))))
     (set! pitch (clamp (fl- pitch (fl* 0.0025 (cdr d))) -1.4 1.4)))
   (let ((pd (and (pointer-locked?) (pointer-down?))))
     (when (and pd (not was-down)) (audio-init!) (fire!))
     (set! was-down pd))
   ;; the 3D frame
   (let* ((eye (eye-pos))
          (vp (m4-mul proj (m4-look-at eye (v3-add eye (fwd-dir))
                                       (v3 0.0 1.0 0.0)))))
     ;; the world never moves, so this runs exactly once
     (unless shadow-done
       (bake-shadows!)
       (set! shadow-done #t))
     (cmd-clear! 0.05 0.07 0.12 1.0)
     (cmd-depth! #t)
     (cmd-use-program! (fx-program-slot p))
     (cmd-bind-texture! 0 (fx-target-texture shadow-t))
     (fx-uniform! p 'u_shadow 0)
     (fx-uniform! p 'u_texel (fl/ 1.0 1024.0) (fl/ 1.0 1024.0))
     (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! p 'u_ambient 0.32)
     (for-each (lambda (s)
                 (draw-obj! (vector-ref s 0) (vector-ref s 1)
                            (vector-ref s 3) (vector-ref s 4)
                            (vector-ref s 5) vp))
               solids)
     (for-each (lambda (o)
                 (when (vector-ref o 4)
                   (let ((c (orb-pos o t)))
                     (draw-obj! orb-mesh
                                (m4-translate (v3-x c) (v3-y c) (v3-z c))
                                0.95 0.55 0.25 vp))))
               orbs))
   ;; the HUD, over everything
   (cmd-depth! #f)
   (hud! (string-append "WAVE " (number->string wave)
                        "   SCORE " (number->string score)))
   (batch-begin! hud)
   (draw-text! hud hud-lay 16.0 12.0 1.0 1.0 1.0 0.9)
   ;; the crosshair: two slim rects
   (rect! hud 396.0 299.0 8.0 2.0 1.0 1.0 1.0 0.7)
   (rect! hud 399.0 296.0 2.0 8.0 1.0 1.0 1.0 0.7)
   (batch-draw! hud)))
