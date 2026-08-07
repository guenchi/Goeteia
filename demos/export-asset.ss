;; A parametric asset, authored in the browser and taken home as a
;; file.  Four sliders drive a turned column lamp -- base radius,
;; mast height, head size, facet count -- built out of nothing but
;; (gfx mesh) primitives; every change restages the geometry, and the
;; SAME staged bytes feed the preview's vertex buffers and the .glb
;; the download button hands you.  The result is a standard glTF 2.0
;; binary: Blender, Unreal, three.js and every other glTF reader open
;; it, and no part of the pipeline ever left the page.
;;
;; The three parts are separate glTF primitives with their own base
;; colour factors, so the file arrives with its materials already
;; assigned rather than as one anonymous blob.
(import (rnrs) (web sx) (web js) (web dom) (web reactive)
        (gfx gl) (gfx glsl) (gfx fx) (gfx mat) (gfx mesh) (gfx glb))

;; ---- the page -----------------------------------------------------

(define $ui-row
  "display:flex;align-items:center;gap:0.6em;font:12px/1.6 ui-monospace,monospace;margin:0.15em 0")
(define $ui-name "width:8.5em;color:#8b93a7")
(define $ui-val "width:3.5em;text-align:right;color:#cfd6e6")

;; hundredths as a fixed two-place decimal: the sliders step in
;; integers, so the value shown is exact arithmetic, never a float
;; that prints as 0.6000000000000001
(define (fmt2 n)
  (let ((w (quotient n 100)) (f (remainder n 100)))
    (string-append (number->string w) "."
                   (if (< f 10) "0" "") (number->string f))))

(define base-cx (signal 60))            ; base radius,  x0.01
(define mast-cx (signal 300))           ; mast height,  x0.01
(define head-cx (signal 45))            ; head radius,  x0.01
(define sides-n (signal 8))             ; facets around the turn
(define status (signal "building..."))

(define (on-slide sig)
  (lambda (ev)
    (signal-set! sig (js->number (js-get (js-get ev "target") "value")))))

;; one labelled range input; `show` turns the raw slider integer into
;; the text beside it, so a plain count and a hundredths value share
;; the same control
(define (slider name sig lo hi show)
  (sx (div (@ (style ,$ui-row))
        (span (@ (style ,$ui-name)) ,name)
        (input (@ (type "range") (min ,lo) (max ,hi) (step "1")
                  (style "flex:1")
                  (value ,(signal-ref sig))
                  (on-input ,(on-slide sig))))
        (span (@ (style ,$ui-val)) ,(show (signal-ref sig))))))

(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "400")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px")))
        (div (@ (style "max-width:40em;margin-top:0.8em"))
          ,(slider "base radius" base-cx 20 120 fmt2)
          ,(slider "mast height" mast-cx 60 600 fmt2)
          ,(slider "head size" head-cx 15 90 fmt2)
          ,(slider "facets" sides-n 3 24 number->string)
          (div (@ (style ,$ui-row))
            (button (@ (id "dl")
                       (style "font:12px/1.6 ui-monospace,monospace;padding:0.35em 1em")
                       (on-click ,(lambda (ev) (download!))))
              "Download .glb")
            (span (@ (style "color:#8b93a7;font:12px/1.6 ui-monospace,monospace"))
              ,(signal-ref status)))))))

(fx-init! (get-element-by-id "c"))

;; ---- the preview shader -------------------------------------------
;; positions arrive already placed (see stage-part!), so the model
;; matrix is the identity and one mvp serves every part

(define prog
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (varying vec3 v_n)
     (define (main) void
       (set! v_n a_normal)
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (uniform vec4 u_color)
     (varying vec3 v_n)
     (define (main) void
       (local vec3 n (normalize v_n))
       (local vec3 ld (normalize (vec3 "0.45" "0.80" "0.40")))
       (local float nl (max (dot n ld) (fl 0)))
       ;; a sky/ground ambient keeps the unlit facets readable
       (local float sky (+ (fl 0 50) (* (fl 0 50) n.y)))
       (set! gl_FragColor
             (vec4 (* u_color.rgb (+ (* "0.85" nl) (* "0.30" sky)))
                   u_color.a))))))

;; ---- one staged part ----------------------------------------------
;; A part is staged ONCE.  Its bytes are the preview's vertex buffer
;; and the GLB primitive both, so "what you download" and "what you
;; see" are the same array of floats and cannot drift apart.

(define-record-type (part $make-part part?)
  (fields (immutable vbuf part-vbuf)      ; GL slots
          (immutable ibuf part-ibuf)
          (immutable vbase part-vbase)    ; staging
          (immutable vbytes part-vbytes)
          (immutable ibase part-ibase)
          (immutable ibytes part-ibytes)
          (immutable vcount part-vcount)
          (immutable icount part-icount)
          (immutable color part-color)    ; #(r g b a)
          (mutable up part-up part-up!))) ; uploaded to the GPU yet?

;; slide a staged part along +y.  A translation moves positions and
;; leaves normals alone, so exactly one float per vertex changes --
;; and doing it here, in the bytes, is what lets the preview and the
;; export share them.  The interleave is (x y z nx ny nz), 24 bytes.
(define (lift! vbase n dy)
  (let loop ((v 0))
    (when (< v n)
      (let ((at (+ vbase (* v 24) 4)))
        (%mem-f32-set! at (fl+ (%mem-f32-ref at) dy)))
      (loop (+ v 1)))))

(define (stage-part! m dy color)
  (let* ((vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (lift! vbase (mesh-vert-count m) dy)
    ($make-part (fx-buffer!) (fx-buffer!)
                vbase (mesh-vertex-bytes m)
                ibase (mesh-index-bytes m)
                (mesh-vert-count m) (mesh-index-count m)
                color #f)))

;; the (gfx glb) primitive descriptor for a part: a plain list, so
;; nothing here has to know how the writer is built
(define (part->prim p)
  (list '(position normal) (part-vbase p) (part-vcount p)
        (part-ibase p) (part-icount p)
        'color (part-color p)))

;; ---- the asset ----------------------------------------------------

(define-record-type (asset $make-asset asset?)
  (fields (immutable parts asset-parts)
          (immutable base asset-glb-base)   ; the GLB, in staging
          (immutable len asset-glb-len)
          (immutable vcount asset-vcount)
          (immutable height asset-height)))

(define brass '#(0.78 0.62 0.28 1.0))
(define steel '#(0.62 0.65 0.72 1.0))
(define shade '#(0.92 0.86 0.62 1.0))

(define $plinth 0.16)                     ; the base disc is this thick

;; Build EVERYTHING the two consumers need in one step: the parts the
;; preview draws and the GLB the button saves come out of the same
;; call, so a parameter can never reach one and miss the other.
;;
;; Restaging leaks: fx-alloc! is a bump allocator with no free, so
;; every rebuild abandons the previous one's staging bytes (and takes
;; fresh GL buffer slots besides).  That is the documented limit --
;; "Staging memory only grows", docs/limits.md in the main repository
;; -- and it is fine for a demo's worth of slider dragging, since Wasm
;; memory grows on demand; an asset editor meant to run for hours
;; would keep one arena per part and rewrite it in place.
(define (build! br mast hr sides)
  (let* ((ps (list
              (stage-part! (mesh-cylinder br $plinth sides)
                           (fl* 0.5 $plinth) brass)
              (stage-part! (mesh-cylinder (fl* br 0.20) mast sides)
                           (fl+ $plinth (fl* 0.5 mast)) steel)
              (stage-part! (mesh-cylinder hr (fl* hr 0.90) sides)
                           (fl+ $plinth (fl+ mast (fl* hr 0.45))) shade)))
         ;; the writer copies the blocks into its own BIN chunk, so
         ;; this GLB is a snapshot: a later rebuild cannot corrupt it
         (loc (glb-write! (map part->prim ps))))
    ($make-asset ps (car loc) (cdr loc)
                 (fold-left + 0 (map part-vcount ps))
                 (fl+ $plinth (fl+ mast (fl* hr 0.90))))))

(define $asset #f)

;; every slider feeds this one effect: read the four signals, rebuild
(effect
 (lambda ()
   (let ((a (build! (fl/ (fixnum->flonum (signal-ref base-cx)) 100.0)
                    (fl/ (fixnum->flonum (signal-ref mast-cx)) 100.0)
                    (fl/ (fixnum->flonum (signal-ref head-cx)) 100.0)
                    (signal-ref sides-n))))
     (set! $asset a)
     (signal-set! status
                  (string-append (number->string (asset-vcount a))
                                 " verts / "
                                 (number->string (asset-glb-len a))
                                 " B .glb")))))

;; ---- staging bytes -> a file the browser saves ---------------------
;; The whole channel out of wasm, and it is three steps:
;;
;;   1. the module's linear memory answers to `__goeteia_mem` on the
;;      host (rt/jsbridge.mjs resolves that name to the instance's
;;      exported memory), so `new Uint8Array(mem.buffer, base, len)`
;;      is a zero-copy VIEW of the range glb-write! returned -- no
;;      byte-at-a-time bridge traffic for a file of any size;
;;   2. `new Blob([view], {type})` copies that range out.  After this
;;      the bytes belong to the browser, so a later fx-alloc! that
;;      grows -- and therefore DETACHES -- the buffer cannot reach
;;      them;
;;   3. an <a download> pointing at an object URL for the Blob,
;;      clicked, then revoked on the next turn of the event loop.
;;
;; Build the view AFTER the last fx-alloc!: memory growth detaches
;; every ArrayBuffer taken before it, and a detached view is empty.
;; Nothing here is glTF-specific -- any (base . len) leaves this way.
(define (save-bytes! base len name mime)
  (let* ((g (js-global))
         (mem (js-get g "__goeteia_mem"))
         (view (js-new (js-get g "Uint8Array")
                       (js-get mem "buffer") base len))
         (blob-parts (js-eval "[]"))
         (opts (js-eval "({})")))
    (js-method blob-parts "push" view)
    (js-set! opts "type" mime)
    (let* ((blob (js-new (js-get g "Blob") blob-parts opts))
           (url (js-method (js-get g "URL") "createObjectURL" blob))
           (a (create-element "a")))
      (js-set! a "href" url)
      (js-set! a "download" name)
      (js-method a "click")
      ;; click() only QUEUES the save; revoking in the same turn can
      ;; pull the URL out from under it
      (js-method g "setTimeout"
                 (lambda ()
                   (js-method (js-get g "URL") "revokeObjectURL" url)
                   (js-undefined))
                 0))))

(define (download!)
  (when $asset
    (save-bytes! (asset-glb-base $asset) (asset-glb-len $asset)
                 "lamp.glb" "model/gltf-binary")))

;; ---- the preview ---------------------------------------------------

(define proj (m4-perspective 0.9 (fl/ 720.0 400.0) 0.1 100.0))

(define (draw-part! p vp)
  (fx-use! prog (part-vbuf p))
  (cmd-bind-index! (part-ibuf p))
  (unless (part-up p)                   ; upload once, on first sight
    (cmd-buffer-data! (part-vbase p) (part-vbytes p))
    (cmd-index-data! (part-ibase p) (part-ibytes p))
    (part-up! p #t))
  (fx-uniform! prog 'u_mvp vp)
  (let ((c (part-color p)))
    (fx-uniform! prog 'u_color (vector-ref c 0) (vector-ref c 1)
                 (vector-ref c 2) (vector-ref c 3)))
  (cmd-draw-elements! GL-TRIANGLES (part-icount p)))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (cmd-clear! 0.05 0.06 0.09 1.0)
   (let* ((a $asset)
          (h (asset-height a))
          (d (fl+ 1.6 (fl* 1.35 h)))    ; the orbit frames whatever it is
          (ang (fl* 0.45 t))
          (eye (v3 (fl* d (flsin ang)) (fl* 0.62 h) (fl* d (flcos ang))))
          (vp (m4-mul proj (m4-look-at eye
                                       (v3 0.0 (fl* 0.45 h) 0.0)
                                       (v3 0.0 1.0 0.0)))))
     (for-each (lambda (p) (draw-part! p vp)) (asset-parts a)))))
