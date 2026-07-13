;; A textured GLB asset: BoxTextured.glb's embedded PNG decodes with
;; gltf-load-textures! (Blob -> createImageBitmap -> texture), the
;; primitive arrives with uvs at mesh-tex-vs's 32-byte layout, and
;; the same directional light shades the sampled color.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx gltf))

(fx-init! (get-element-by-id "c"))

(define prog (fx-program! mesh-tex-vs mesh-tex-fs))
(define model #f)
(gltf-fetch! "assets/BoxTextured.glb"
             (lambda (g)
               (gltf-load-textures! g
                                    (lambda (g2) (set! model g2)))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 1.4 3.0) (v3 0.0 0.0 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (cmd-use-program! (fx-program-slot prog))
   (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! prog 'u_ambient 0.35)
   (when model
     (gltf-draw! model prog vp
                 (m4-mul (m4-rotate-y t)
                         (m4-rotate-x (fl* 0.35 t)))))))
