;; A lit 3D scene, raw WebGL: (web mesh) generates the geometry
;; (positions, normals, u16 indices) in pure Scheme, mesh-lit-vs/fs
;; is the ready-made directional-light program, (web mat) does the
;; matrices.  Three meshes, one program, no Three.js.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

(define p (fx-program! mesh-lit-vs mesh-lit-fs))

;; upload a mesh once; keep what each frame's draw needs
(define (scene-mesh m)
  (let* ((vbuf (fx-buffer!))
         (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase
            (mesh-vertex-bytes m) (mesh-index-bytes m)
            (mesh-index-count m))))

(define ground (scene-mesh (mesh-plane 14.0 14.0)))
(define torus (scene-mesh (mesh-torus 1.6 0.55)))
(define ball (scene-mesh (mesh-sphere 1.0)))

(define (draw! obj model r g b)
  (fx-use! p (vector-ref obj 0))
  (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
  (cmd-bind-index! (vector-ref obj 1))
  (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
  (fx-uniform! p 'u_mvp (m4-mul vp model))
  (fx-uniform! p 'u_model model)
  (fx-uniform! p 'u_color r g b 1.0)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6)))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 3.5 9.0) (v3 0.0 0.5 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (cmd-use-program! (fx-program-slot p))
   (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! p 'u_ambient 0.25)
   (draw! ground (m4-translate 0.0 -1.6 0.0) 0.35 0.40 0.50)
   (draw! torus
          (m4-mul (m4-translate -1.8 0.6 0.0)
                  (m4-mul (m4-rotate-y t) (m4-rotate-x (fl* 0.6 t))))
          0.95 0.45 0.35)
   (draw! ball
          (m4-translate 2.2 (fl+ 0.4 (fl* 0.8 (flsin (fl* 1.5 t)))) 0.0)
          0.40 0.70 0.95)))
