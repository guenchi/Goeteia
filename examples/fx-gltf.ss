;; A real 3D asset: the Khronos Box.glb sample (CC0) fetched, parsed
;; by (web gltf) -- the binary chunk lands in staging memory and the
;; accessors read floats straight out of it -- and drawn through the
;; same lit shader as the parametric meshes.  The base color comes
;; from the file's material.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh) (web gltf))

(fx-init! (get-element-by-id "c"))

(define prog (fx-program! mesh-lit-vs mesh-lit-fs))

;; the ground is ours; the box arrives over the network
(define ground
  (let* ((m (mesh-plane 12.0 12.0))
         (vbuf (fx-buffer!))
         (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase
            (mesh-vertex-bytes m) (mesh-index-bytes m)
            (mesh-index-count m))))
(define ground-up #f)

(define model #f)
(gltf-fetch! "assets/Box.glb" (lambda (g) (set! model g)))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 1.6 3.2) (v3 0.0 0.2 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (cmd-use-program! (fx-program-slot prog))
   (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! prog 'u_ambient 0.3)
   ;; the ground plane
   (fx-use! prog (vector-ref ground 0))
   (cmd-bind-index! (vector-ref ground 1))
   (unless ground-up
     (cmd-buffer-data! (vector-ref ground 2) (vector-ref ground 4))
     (cmd-index-data! (vector-ref ground 3) (vector-ref ground 5))
     (set! ground-up #t))
   (let ((m (m4-translate 0.0 -0.55 0.0)))
     (fx-uniform! prog 'u_mvp (m4-mul vp m))
     (fx-uniform! prog 'u_model m)
     (fx-uniform! prog 'u_color 0.35 0.40 0.50 1.0)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref ground 6)))
   ;; the asset, spinning once it has arrived
   (when model
     (gltf-draw! model prog vp
                 (m4-mul (m4-rotate-y t)
                         (m4-rotate-x (fl* 0.4 t)))))))
