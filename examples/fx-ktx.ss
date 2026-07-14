;; A compressed texture, decoded by our own transcoder: the .ktx2
;; asset (Basis ETC1S, five mips, 17KB) fetches into staging,
;; (gfx ktx) reconstructs the codebooks and slices in pure Scheme,
;; and ktx-upload! ships whatever this GPU speaks -- ETC1 blocks,
;; BC1 blocks, or RGBA where neither extension exists.  The page
;; title reports which family won and the transcode time.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx ktx))

(fx-init! (get-element-by-id "c"))

(define p (fx-program! mesh-tex-vs mesh-tex-fs))

(define (tex-mesh m)
  (let* ((vbuf (fx-buffer!))
         (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes-uv m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write-uv! m vbase ibase)
    (vector vbuf ibuf vbase ibase
            (mesh-vertex-bytes-uv m) (mesh-index-bytes m)
            (mesh-index-count m))))

(define crate (tex-mesh (mesh-box 2.6 2.6 2.6)))
(define ground (tex-mesh (mesh-plane 14.0 14.0)))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 2.8 7.0) (v3 0.0 0.5 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(define tex #f)

(define (now) (js->number (js-eval "Date.now()")))

(define t0 (now))
(ktx-stream!
 "assets/pattern.ktx2"
 (lambda (slot k phase)
   (set! tex slot)
   (js-set! (js-get (js-global) "document") "title"
            (string-append
             "ktx "
             (case (gl-compressed-family)
               ((2) "ETC1") ((1) "BC1") (else "RGBA"))
             " " (symbol->string phase)
             " at " (number->string (- (now) t0)) "ms"))))

(define (draw! obj model)
  (fx-use! p (vector-ref obj 0))
  (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
  (cmd-bind-index! (vector-ref obj 1))
  (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
  (cmd-bind-texture! 0 tex)
  (fx-uniform! p 'u_tex 0)
  (fx-uniform! p 'u_light (v3-x light) (v3-y light) (v3-z light))
  (fx-uniform! p 'u_ambient 0.3)
  (fx-uniform! p 'u_mvp (m4-mul vp model))
  (fx-uniform! p 'u_model model)
  (fx-uniform! p 'u_color 1.0 1.0 1.0 1.0)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (when tex
     (draw! ground (m4-translate 0.0 -1.4 0.0))
     (draw! crate (m4-mul (m4-translate 0.0 0.6 0.0)
                          (m4-rotate-y (fl* 0.6 t)))))))
