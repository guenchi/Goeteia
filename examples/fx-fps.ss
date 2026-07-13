;; First-person walking: click to capture the mouse (Esc releases),
;; WASD or arrows to move, look around freely.  The camera is
;; (web mat)'s look-at fed by pointer-motion! deltas, and the walls
;; push back through (web collide)'s sphere-aabb-push -- motion along
;; a wall survives, so you slide instead of sticking.
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

;; the player: an eye-height sphere on the xz plane
(define px 0.0)
(define pz 6.0)
(define yaw 0.0)
(define pitch 0.0)

(define (clamp v lo hi) (if (fl<? v lo) lo (if (fl<? hi v) hi v)))
(define (down? . ks)
  (let loop ((ks ks))
    (and (pair? ks) (or (key-down? (car ks)) (loop (cdr ks))))))

(fx-loop!
 (lambda (t dt)
   ;; look: relative mouse while captured
   (let ((d (pointer-motion!)))
     (set! yaw (fl+ yaw (fl* 0.0025 (car d))))
     (set! pitch (clamp (fl- pitch (fl* 0.0025 (cdr d))) -1.4 1.4)))
   ;; move in the yaw plane
   (let* ((sp (fl* 5.0 (if (fl<? 0.05 dt) 0.05 dt)))
          (fwx (fl* sp (flsin yaw))) (fwz (fl* sp (fl- 0.0 (flcos yaw))))
          (rtx (fl* sp (flcos yaw))) (rtz (fl* sp (flsin yaw))))
     (when (down? "w" "W" "ArrowUp")
       (set! px (fl+ px fwx)) (set! pz (fl+ pz fwz)))
     (when (down? "s" "S" "ArrowDown")
       (set! px (fl- px fwx)) (set! pz (fl- pz fwz)))
     (when (down? "d" "D" "ArrowRight")
       (set! px (fl+ px rtx)) (set! pz (fl+ pz rtz)))
     (when (down? "a" "A" "ArrowLeft")
       (set! px (fl- px rtx)) (set! pz (fl- pz rtz))))
   ;; the walls push back; sliding falls out of the shortest exit
   (for-each
    (lambda (w)
      (let ((push (sphere-aabb-push (v3 px 0.9 pz) 0.35
                                    (vector-ref w 2) (vector-ref w 3))))
        (when push
          (set! px (fl+ px (v3-x push)))
          (set! pz (fl+ pz (v3-z push))))))
    walls)
   (set! px (clamp px -11.5 11.5))
   (set! pz (clamp pz -11.5 11.5))
   ;; camera and frame
   (let* ((cp (flcos pitch))
          (eye (v3 px 0.9 pz))
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
