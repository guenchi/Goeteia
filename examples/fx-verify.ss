;; End-to-end verification of the compressed-asset pipeline on REAL
;; tool output.  Left: the Khronos Box.glb as-is.  Right: the same box
;; through gltfpack -c (EXT_meshopt_compression + KHR_mesh_quantization
;; -- u16 positions, normalized i8 normals), decoded by (gfx meshopt)
;; and the gltf dequantizer.  The two must look identical.  Behind:
;; a crate wearing a basisu UASTC KTX2, zstd-supercompressed (scheme
;; 2), inflated by (gfx zstd) and unpacked by (gfx uastc).
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx gltf) (gfx ktx))

(fx-init! (get-element-by-id "c"))

(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define texp (fx-program! mesh-tex-vs mesh-tex-fs))

(define crate
  (let* ((m (mesh-box 2.2 2.2 2.2))
         (vbuf (fx-buffer!)) (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes-uv m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write-uv! m vbase ibase)
    (vector vbuf ibuf vbase ibase
            (mesh-vertex-bytes-uv m) (mesh-index-bytes m)
            (mesh-index-count m))))
(define crate-up #f)

(define plain #f)                       ; Box.glb, the reference
(define packed #f)                      ; gltfpack meshopt+quantized
(define tex #f)                         ; UASTC zstd ktx2

(gltf-fetch! "assets/Box.glb" (lambda (g) (set! plain g)))
(gltf-fetch! "assets/Box-mq.glb" (lambda (g) (set! packed g)))
(ktx-fetch! "assets/uastc.ktx2"
            (lambda (kx)
              (set! tex (ktx-upload! kx))
              (js-set! (js-get (js-global) "document") "title"
                       (string-append
                        "uastc " (number->string (ktx-width kx)) "x"
                        (number->string (ktx-height kx))
                        (if (ktx-uastc? kx) " ok" " NOT-UASTC")))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 1.6 4.6) (v3 0.0 0.4 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   ;; the UASTC crate, spinning behind
   (when tex
     (fx-use! texp (vector-ref crate 0))
     (cmd-bind-index! (vector-ref crate 1))
     (unless crate-up
       (cmd-buffer-data! (vector-ref crate 2) (vector-ref crate 4))
       (cmd-index-data! (vector-ref crate 3) (vector-ref crate 5))
       (set! crate-up #t))
     (cmd-bind-texture! 0 tex)
     (fx-uniform! texp 'u_tex 0)
     (fx-uniform! texp 'u_light (v3-x light) (v3-y light) (v3-z light))
     (fx-uniform! texp 'u_ambient 0.35)
     (let ((m (m4-mul (m4-translate 0.0 1.2 -3.0)
                      (m4-rotate-y (fl* 0.4 t)))))
       (fx-uniform! texp 'u_mvp (m4-mul vp m))
       (fx-uniform! texp 'u_model m))
     (fx-uniform! texp 'u_color 1.0 1.0 1.0 1.0)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref crate 6)))
   ;; the two boxes, side by side, spinning in lockstep
   (cmd-use-program! (fx-program-slot lit))
   (fx-uniform! lit 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! lit 'u_ambient 0.3)
   (let ((spin (m4-rotate-y (fl* 0.7 t))))
     (when plain
       (gltf-draw! plain lit vp (m4-mul (m4-translate -1.4 0.3 0.0) spin)))
     (when packed
       (gltf-draw! packed lit vp (m4-mul (m4-translate 1.4 0.3 0.0) spin))))))
