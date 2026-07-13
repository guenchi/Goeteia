;; First-person walking: click to capture the mouse (Esc releases),
;; WASD or arrows to move, SPACE to jump, look around freely.  The
;; player is (web collide)'s packaged character -- gravity, landing
;; and the slide all inside character-move! -- stepping at a fixed
;; 120Hz through fx-loop-fixed! so the physics ignores the frame
;; rate, and each step sweeps only the walls the broadphase grid
;; hands back.  Jump onto the low violet box.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh) (web collide))

(fx-init! (get-element-by-id "c"))
(fx-init-input!)
(pointer-lock!)

(define p (fx-program! mesh-lit-vs mesh-lit-fs))
(define proj (m4-perspective 1.1 (/ 800.0 600.0) 0.1 100.0))
(define light (v3-normalize (v3 0.4 0.9 0.3)))

;; geometry uploads once; #(vbuf ibuf vbase ibase vbytes ibytes n up?)
(define (upload m)
  (let* ((vbuf (fx-buffer!))
         (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase (mesh-vertex-bytes m)
            (mesh-index-bytes m) (mesh-index-count m) #f)))

;; the room: centre x/z, size x/y/z, colour
(define wall-specs
  '((0.0 -7.0   10.0 2.5 1.0   0.85 0.45 0.35)
    (-6.0 0.0   1.0 3.0 9.0    0.40 0.60 0.90)
    (6.0 2.0    3.0 1.8 3.0    0.45 0.85 0.50)
    (2.0 -3.0   1.5 3.5 1.5    0.95 0.85 0.40)
    (-2.5 4.0   4.0 1.2 1.0    0.75 0.55 0.90)))

;; each wall: #(geom model aabb-min aabb-max r g b)
(define walls
  (map (lambda (s)
         (let ((cx (list-ref s 0)) (cz (list-ref s 1))
               (sx (list-ref s 2)) (sy (list-ref s 3)) (sz (list-ref s 4))
               (r (list-ref s 5)) (g (list-ref s 6)) (b (list-ref s 7)))
           (vector (upload (mesh-box sx sy sz))
                   (m4-translate cx (fl/ sy 2.0) cz)
                   (v3 (fl- cx (fl/ sx 2.0)) 0.0 (fl- cz (fl/ sz 2.0)))
                   (v3 (fl+ cx (fl/ sx 2.0)) sy (fl+ cz (fl/ sz 2.0)))
                   r g b)))
       wall-specs))

(define ground
  (vector (upload (mesh-plane 24.0 24.0)) (m4-identity)
          #f #f 0.35 0.40 0.50))

(define (draw-obj! o vp)
  (let ((gv (vector-ref o 0))
        (model (vector-ref o 1)))
    (fx-use! p (vector-ref gv 0))
    (cmd-bind-index! (vector-ref gv 1))
    (unless (vector-ref gv 7)
      (cmd-buffer-data! (vector-ref gv 2) (vector-ref gv 4))
      (cmd-index-data! (vector-ref gv 3) (vector-ref gv 5))
      (vector-set! gv 7 #t))
    (fx-uniform! p 'u_mvp (m4-mul vp model))
    (fx-uniform! p 'u_model model)
    (fx-uniform! p 'u_color (vector-ref o 4) (vector-ref o 5)
                 (vector-ref o 6) 1.0)
    (cmd-draw-elements! GL-TRIANGLES (vector-ref gv 6))))

;; the player: the packaged character, spawned eye-height over a
;; solid ground slab (gravity needs a floor with thickness)
(define world
  (cons (cons (v3 -12.0 -1.0 -12.0) (v3 12.0 0.0 12.0))
        (map (lambda (w) (cons (vector-ref w 2) (vector-ref w 3)))
             walls)))
(define grid (make-aabb-grid world 4.0))
(define player (make-character (v3 0.0 0.36 6.0) 0.35))
(define yaw 0.0)
(define pitch 0.0)

(define (clamp v lo hi) (if (fl<? v lo) lo (if (fl<? hi v) hi v)))
(define (down? . ks)
  (let loop ((ks ks))
    (and (pair? ks) (or (key-down? (car ks)) (loop (cdr ks))))))

(fx-loop-fixed!
 0.0083333                              ; the physics ticks at 120Hz,
 (lambda (step)                         ; whatever the display does
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
     ;; only the boxes near the player are worth sweeping
     (character-move! player (fl* 5.0 vx) (fl* 5.0 vz) step
                      (grid-near grid (character-pos player) 1.5))))
 (lambda (alpha t dt)
   ;; look: relative mouse while captured (a per-frame affair)
   (let ((d (pointer-motion!)))
     (set! yaw (fl+ yaw (fl* 0.0025 (car d))))
     (set! pitch (clamp (fl- pitch (fl* 0.0025 (cdr d))) -1.4 1.4)))
   (let* ((cp (flcos pitch))
          (pp (character-pos player))
          (eye (v3 (v3-x pp) (fl+ (v3-y pp) 0.55) (v3-z pp)))
          (fwd (v3 (fl* cp (flsin yaw))
                   (flsin pitch)
                   (fl* cp (fl- 0.0 (flcos yaw)))))
          (vp (m4-mul proj (m4-look-at eye (v3-add eye fwd)
                                       (v3 0.0 1.0 0.0)))))
     (cmd-clear! 0.05 0.07 0.12 1.0)
     (cmd-depth! #t)
     (cmd-use-program! (fx-program-slot p))
     (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! p 'u_ambient 0.3)
     (draw-obj! ground vp)
     (for-each (lambda (w) (draw-obj! w vp)) walls))))
