;; T3 -- meshes in three dimensions.  This file IS the browser half:
;; it takes the canvas the page already has and draws into it.  Three
;; lit meshes, one program, indexed draws.
(import (rnrs) (web js) (web dom)
        (gfx gl) (gfx glsl) (gfx fx) (gfx mat) (gfx mesh))

;; fx-init! takes ANY canvas element that already exists -- which id
;; it carries is the host page's business, not the library's -- and
;; from there owns staging memory and every resource slot: allocate
;; through fx-alloc!/fx-buffer!/fx-program!, never with hand-numbered
;; gl-*! calls, or the two numbering schemes collide.
(fx-init! (get-element-by-id "c"))

;; mesh-lit-vs / mesh-lit-fs are ready-made (gfx glsl) FORMS -- one
;; directional light over a solid colour.  fx-program! reads the
;; attribute and uniform declarations back out of them and does all
;; the location/offset/VAO bookkeeping.
(define prog (fx-program! mesh-lit-vs mesh-lit-fs))

;; (gfx mesh) generators.  EVERY size is a full extent, never a half:
;;   (mesh-plane w d)                    on xz, +y normal
;;   (mesh-box w h d)                    edge lengths, centred on 0
;;   (mesh-sphere r [segs 24] [rings 16])          radius
;;   (mesh-cylinder r h [segs 24])       radius, full height
;;   (mesh-torus ring tube [segs 32] [rings 16])   two radii
;;   (mesh-heightmap w d nx nz f)        y = (f x z) per grid point
;; Each produces the 24-byte position+normal interleave mesh-lit-vs
;; declares; fx-mesh! stages one and uploads it lazily in frame one.
(define ball (fx-mesh! (mesh-sphere 0.8 32 24)))
(define cube (fx-mesh! (mesh-box 1.2 1.2 1.2)))
(define ring (fx-mesh! (mesh-torus 0.9 0.3 48 24)))

;; (gfx mat) in full, so nothing here has to be guessed at:
;;   m4-identity m4-translate m4-scale m4-rotate-x m4-rotate-y
;;   m4-rotate-z m4-from-quat m4-perspective m4-ortho m4-look-at
;;   m4-mul m4-inverse m4-transform m4-unproject
;;   v3 v3-x v3-y v3-z v3-add v3-sub v3-scale v3-dot v3-cross
;;   v3-normalize   flsin flcos fltan flasin flacos flatan flatan2
;;
;; The drawing buffer is the canvas WIDTH/HEIGHT attributes (800x600
;; on this page); CSS only stretches the result.  No exponent
;; literals anywhere: the reader has no 1e-3 syntax and reads it as a
;; SYMBOL.  Write constants in full.
(define proj (m4-perspective 0.9 (fl/ 800.0 600.0) 0.1 100.0))
(define light (v3-normalize (v3 0.4 0.8 0.5)))

(define (draw! h vp model r g b)
  (fx-mesh-use! prog h)
  (fx-uniform! prog 'u_mvp (m4-mul vp model))
  (fx-uniform! prog 'u_model model)
  (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
  (fx-uniform! prog 'u_color r g b 1.0)
  (fx-uniform! prog 'u_ambient 0.22)
  (fx-mesh-draw! h))

;; fx-loop! frames each callback with begin/viewport/flush -- ONE
;; bridge call per frame, whatever it drew.  t and dt are seconds.
(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (cmd-clear! 0.03 0.04 0.08 1.0)
   ;; A mat4 is a column-major 16-vector and (m4-mul a b) applies b
   ;; FIRST: a is the parent frame, b the child's own transform.
   ;; Here `spin` is the parent of all three, so the row orbits.
   (let ((vp (m4-mul proj (m4-look-at (v3 0.0 1.6 6.2)
                                      (v3 0.0 0.0 0.0)
                                      (v3 0.0 1.0 0.0))))
         (spin (m4-rotate-y t)))
     (draw! ball vp (m4-mul spin (m4-translate -2.4 0.0 0.0))
            0.92 0.45 0.32)
     (draw! cube vp (m4-mul spin (m4-rotate-x (fl* 1.7 t)))
            0.40 0.68 0.95)
     (draw! ring vp (m4-mul spin (m4-translate 2.4 0.0 0.0))
            0.55 0.85 0.50))))
