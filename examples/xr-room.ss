;; A room you can stand in: the same raw-GL scene renders two ways.
;; On a desktop it orbits under fx-loop! as usual; press Enter VR
;; (the button appears when WebXR answers) and (web xr) swaps the
;; pump for the session's rAF, takes each eye's projection and view
;; from the XRPose, and draws the frame once per eye into the
;; session's framebuffer -- the command buffer, the fx layer and
;; the shader do not change at all.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh) (web xr))

(define canvas (get-element-by-id "c"))
(fx-init! canvas)

(define p (fx-program! mesh-lit-vs mesh-lit-fs))

(define (upload m)
  (let* ((vbuf (fx-buffer!)) (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase (mesh-vertex-bytes m)
            (mesh-index-bytes m) (mesh-index-count m) #f)))

(define ground (upload (mesh-plane 12.0 12.0)))
(define pillar (upload (mesh-box 0.6 2.2 0.6)))
(define ring (upload (mesh-torus 0.5 0.18 32 16)))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

;; pillars around the player, a slowly turning ring on each
(define spots
  '((-3.0 . -3.0) (3.0 . -3.0) (-3.0 . 3.0) (3.0 . 3.0)
    (0.0 . -4.5) (4.5 . 0.0) (-4.5 . 0.0)))

(define (draw-obj! obj model r g b vp)
  (fx-use! p (vector-ref obj 0))
  (cmd-bind-index! (vector-ref obj 1))
  (unless (vector-ref obj 7)
    (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
    (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
    (vector-set! obj 7 #t))
  (fx-uniform! p 'u_mvp (m4-mul vp model))
  (fx-uniform! p 'u_model model)
  (fx-uniform! p 'u_color r g b 1.0)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6)))

;; ONE scene function; only the vp differs between desktop and XR
(define (draw-scene! vp t)
  (cmd-depth! #t)
  (cmd-use-program! (fx-program-slot p))
  (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
  (fx-uniform! p 'u_ambient 0.3)
  (draw-obj! ground (m4-identity) 0.35 0.40 0.50 vp)
  (for-each
   (lambda (s)
     (let ((x (car s)) (z (cdr s)))
       (draw-obj! pillar (m4-translate x 1.1 z) 0.55 0.50 0.62 vp)
       (draw-obj! ring
                  (m4-mul (m4-translate x 2.6 z)
                          (m4-rotate-y (fl+ t (fl* 0.5 x))))
                  0.95 0.55 0.25 vp)))
   spots))

;; ---- desktop: the usual orbit, retired when XR takes over ----
(define in-xr #f)
(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(fx-loop!
 (lambda (t dt)
   (unless in-xr
     (let* ((a (fl* 0.2 t))
            (eye (v3 (fl* 7.0 (flsin a)) 2.2 (fl* 7.0 (flcos a))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 1.2 0.0)
                                         (v3 0.0 1.0 0.0)))))
       (cmd-clear! 0.05 0.07 0.12 1.0)
       (draw-scene! vp t)))))

;; ---- the button appears only where a session could ----
(xr-supported?
 (lambda (ok)
   (when (js-truthy? ok)
     (let ((btn (get-element-by-id "enter")))
       (js-set! (js-get btn "style") "display" "inline-block")
       (js-set! btn "onclick"
                (lambda args
                  (set! in-xr #t)
                  (xr-start!
                   canvas
                   (lambda (t)                  ; once per XR frame
                     (cmd-begin!)
                     (cmd-bind-target! (xr-framebuffer))
                     (cmd-clear! 0.05 0.07 0.12 1.0)
                     (let eye ((i 0))
                       (when (< i (xr-eye-count))
                         (xr-eye-viewport! i)
                         (draw-scene! (xr-eye-vp i) t)
                         (eye (+ i 1))))
                     (cmd-flush!))
                   (lambda () (set! in-xr #f)))
                  (js-undefined)))))))
