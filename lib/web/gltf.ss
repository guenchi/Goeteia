;; Load real 3D assets: GLB (binary glTF 2.0) static meshes.  The
;; file's JSON chunk parses through (web json); its binary chunk sits
;; in the staging memory and accessors read f32/u16 straight out of
;; it -- no float decoder, the wasm loads ARE the decoder.
;;
;;   (gltf-fetch! "duck.glb"
;;     (lambda (g) (set! duck g)))        ; browser: fetch + parse
;;   ...
;;   (define p (fx-program! mesh-lit-vs mesh-lit-fs))
;;   (fx-loop! (lambda (t dt)
;;     ...
;;     (gltf-draw! g p vp)))              ; all primitives, lit
;;
;; What loads: every primitive's POSITION (+ NORMAL when present),
;; u8/u16/u32 indices (u32 values must still fit u16 -- generators
;; and most assets do), node TRS or matrix transforms accumulated
;; through the scene graph, and the material's baseColorFactor.
;; Primitives come out as the 24-byte pos+normal layout that
;; mesh-lit-vs expects, uploaded on first draw.  Textures, skins and
;; animations are not loaded (yet); a missing NORMAL becomes +y.
;;
;; (gltf-parse base len) works on any GLB bytes already in staging
;; memory, so parsing verifies headlessly; gltf-fetch! is the
;; browser-side loader (fetch -> one bulk copy into staging).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web gltf)
  (export gltf? gltf-prims gltf-parse gltf-fetch! gltf-draw!
          gprim-vbase gprim-vbytes gprim-ibase gprim-ibytes
          gprim-icount gprim-color gprim-world)
  (import (rnrs) (web js) (web gl) (web fx) (web mat) (web json))

  (define ($gltf-fl v) (if (flonum? v) v (exact->inexact v)))

  (define-record-type (gltf $make-gltf gltf?)
    (fields (immutable prims gltf-prims)))

  ;; primitives are open records: custom renderers can reach the
  ;; staging offsets and draw with their own shaders
  (define-record-type ($gprim $make-gprim $gprim?)
    (fields (immutable vbase gprim-vbase)
            (immutable vbytes gprim-vbytes)
            (immutable ibase gprim-ibase)
            (immutable ibytes gprim-ibytes)
            (immutable icount gprim-icount)
            (immutable color gprim-color)     ; r g b a flonum vector
            (immutable world gprim-world)     ; m4
            (mutable vbuf $gprim-vbuf $gprim-vbuf!)
            (mutable ibuf $gprim-ibuf $gprim-ibuf!)))

  ;; ---- raw reads from the staging memory (alignment-safe) ----
  (define ($glb-u16 at)
    (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))))
  (define ($glb-u32 at)
    (+ ($glb-u16 at) (* 65536 ($glb-u16 (+ at 2)))))
  (define ($glb-str at len)               ; the JSON chunk as a string
    (let ((s (%make-string len)))
      (let loop ((i 0))
        (if (= i len)
            s
            (begin
              (string-set! s i (integer->char (%mem-u8-ref (+ at i))))
              (loop (+ i 1)))))))

  ;; ---- the JSON side ----
  (define ($or0 v) (if v v 0))

  ;; accessor index -> (abs-offset stride count comp-type)
  (define ($acc-info json bin idx tight)
    (let* ((acc (vector-ref (json-ref json "accessors") idx))
           (bv (vector-ref (json-ref json "bufferViews")
                           (json-ref acc "bufferView")))
           (stride (let ((s (json-ref bv "byteStride")))
                     (if s s tight))))
      (list (+ bin ($or0 (json-ref bv "byteOffset"))
               ($or0 (json-ref acc "byteOffset")))
            stride
            (json-ref acc "count")
            (json-ref acc "componentType"))))

  (define ($material-color json mi)
    (let ((fallback (vector 0.8 0.8 0.8 1.0)))
      (if (not mi)
          fallback
          (let* ((mat (vector-ref (json-ref json "materials") mi))
                 (f (json-ref mat "pbrMetallicRoughness"
                              "baseColorFactor")))
            (if f
                (vector ($gltf-fl (vector-ref f 0))
                        ($gltf-fl (vector-ref f 1))
                        ($gltf-fl (vector-ref f 2))
                        ($gltf-fl (vector-ref f 3)))
                fallback)))))

  ;; node TRS (or matrix, already column-major in gltf) -> m4
  (define ($node-matrix node)
    (let ((m (json-ref node "matrix")))
      (if m
          (let ((v (make-vector 16 0.0)))
            (let loop ((i 0))
              (when (< i 16)
                (vector-set! v i ($gltf-fl (vector-ref m i)))
                (loop (+ i 1))))
            v)
          (let* ((tr (json-ref node "translation"))
                 (rq (json-ref node "rotation"))
                 (sc (json-ref node "scale"))
                 (t (if tr
                        (m4-translate (vector-ref tr 0) (vector-ref tr 1)
                                      (vector-ref tr 2))
                        (m4-identity)))
                 (r (if rq
                        (m4-from-quat (vector-ref rq 0) (vector-ref rq 1)
                                      (vector-ref rq 2) (vector-ref rq 3))
                        (m4-identity)))
                 (s (if sc
                        (m4-scale (vector-ref sc 0) (vector-ref sc 1)
                                  (vector-ref sc 2))
                        (m4-identity))))
            (m4-mul t (m4-mul r s))))))

  ;; one primitive: interleave pos+normal (24 bytes/vertex) and pack
  ;; u16 index pairs into fresh staging memory
  (define ($build-prim json bin prim world)
    (let* ((attrs (json-ref prim "attributes"))
           (pos ($acc-info json bin (json-ref attrs "POSITION") 12))
           (nrm (let ((i (json-ref attrs "NORMAL")))
                  (and i ($acc-info json bin i 12))))
           (count (caddr pos))
           (vbytes (* 24 count))
           (vbase (fx-alloc! vbytes)))
      (unless (= (cadddr pos) 5126)
        (error 'gltf "positions must be float32" (cadddr pos)))
      (let copy ((v 0))
        (when (< v count)
          (let ((src (+ (car pos) (* v (cadr pos))))
                (dst (+ vbase (* v 24))))
            (%mem-f32-set! dst (%mem-f32-ref src))
            (%mem-f32-set! (+ dst 4) (%mem-f32-ref (+ src 4)))
            (%mem-f32-set! (+ dst 8) (%mem-f32-ref (+ src 8)))
            (if nrm
                (let ((ns (+ (car nrm) (* v (cadr nrm)))))
                  (%mem-f32-set! (+ dst 12) (%mem-f32-ref ns))
                  (%mem-f32-set! (+ dst 16) (%mem-f32-ref (+ ns 4)))
                  (%mem-f32-set! (+ dst 20) (%mem-f32-ref (+ ns 8))))
                (begin
                  (%mem-f32-set! (+ dst 12) 0.0)
                  (%mem-f32-set! (+ dst 16) 1.0)
                  (%mem-f32-set! (+ dst 20) 0.0))))
          (copy (+ v 1))))
      ;; indices: u8/u16/u32 accessor, or none (sequential vertices)
      (let* ((ii (json-ref prim "indices"))
             (inf (and ii ($acc-info json bin ii 0)))
             (icount (if inf (caddr inf) count))
             (idx (if inf
                      (let ((at (car inf)) (ct (cadddr inf)))
                        (lambda (k)
                          (let ((v (cond
                                    ((= ct 5121) (%mem-u8-ref (+ at k)))
                                    ((= ct 5123) ($glb-u16 (+ at (* k 2))))
                                    ((= ct 5125) ($glb-u32 (+ at (* k 4))))
                                    (else (error 'gltf
                                                 "bad index component"
                                                 ct)))))
                            (when (> v 65535)
                              (error 'gltf "index exceeds u16" v))
                            v)))
                      (lambda (k) k)))
             (ibytes (* 4 (quotient (+ icount 1) 2)))
             (ibase (fx-alloc! ibytes)))
        (let pack ((k 0) (at ibase))
          (when (< k icount)
            (%mem-i32-set! at
                           (+ (idx k)
                              (* 65536 (if (< (+ k 1) icount)
                                           (idx (+ k 1))
                                           0))))
            (pack (+ k 2) (+ at 4))))
        ($make-gprim vbase vbytes ibase ibytes icount
                     ($material-color json (json-ref prim "material"))
                     world #f #f))))

  ;; ---- the GLB container, then the scene walk ----
  (define (gltf-parse base len)
    (unless (= ($glb-u32 base) #x46546C67)     ; "glTF"
      (error 'gltf "not a GLB file"))
    (let chunk ((at (+ base 12)) (json-str #f) (bin #f))
      (if (< at (+ base len))
          (let ((clen ($glb-u32 at))
                (ctype ($glb-u32 (+ at 4))))
            (cond
             ((= ctype #x4E4F534A)             ; "JSON"
              (chunk (+ at 8 clen) ($glb-str (+ at 8) clen) bin))
             ((= ctype #x004E4942)             ; "BIN\0"
              (chunk (+ at 8 clen) json-str (+ at 8)))
             (else (chunk (+ at 8 clen) json-str bin))))
          (let ((json (string->json json-str))
                (prims '()))
            (define (walk-node idx parent)
              (let* ((node (vector-ref (json-ref json "nodes") idx))
                     (world (m4-mul parent ($node-matrix node)))
                     (mi (json-ref node "mesh")))
                (when mi
                  (let ((ps (json-ref
                             (vector-ref (json-ref json "meshes") mi)
                             "primitives")))
                    (let prim ((k 0))
                      (when (< k (vector-length ps))
                        (set! prims
                              (cons ($build-prim json bin
                                                 (vector-ref ps k) world)
                                    prims))
                        (prim (+ k 1))))))
                (let ((kids (json-ref node "children")))
                  (when kids
                    (let kid ((k 0))
                      (when (< k (vector-length kids))
                        (walk-node (vector-ref kids k) world)
                        (kid (+ k 1))))))))
            (let* ((roots (json-ref
                           (vector-ref (json-ref json "scenes")
                                       ($or0 (json-ref json "scene")))
                           "nodes")))
              (let root ((k 0))
                (when (< k (vector-length roots))
                  (walk-node (vector-ref roots k) (m4-identity))
                  (root (+ k 1)))))
            ($make-gltf (reverse prims))))))

  ;; browser loader: fetch, one bulk copy into staging, parse, k
  (define (gltf-fetch! url k)
    (js-eval "globalThis.__goeteia_glb = (ab, base) => { new Uint8Array(globalThis.__goeteia_mem.buffer).set(new Uint8Array(ab), base); return 0 }")
    (js-method
     (js-method (js-call (js-get (js-global) "fetch") (js-undefined) url)
                "then"
                (lambda (resp) (js-method resp "arrayBuffer")))
     "then"
     (lambda (ab)
       (let* ((len (js->number (js-get ab "byteLength")))
              (base (fx-alloc! len)))
         (js-call (js-get (js-global) "__goeteia_glb") (js-undefined)
                  ab base)
         (k (gltf-parse base len))
         (js-undefined)))))

  ;; draw every primitive; geometry uploads on its first frame.
  ;; prog is an fx-program over mesh-lit-vs/-fs (or any shader with
  ;; the same a_pos/a_normal layout and u_mvp/u_model/u_color).
  ;; An optional root matrix prefixes every node's world transform --
  ;; spin the whole asset with (m4-rotate-y t) and lighting follows.
  (define (gltf-draw! g prog vp . root)
    (for-each
     (lambda (p)
       (let ((fresh (not ($gprim-vbuf p))))
         (when fresh
           ($gprim-vbuf! p (fx-buffer!))
           ($gprim-ibuf! p (fx-buffer!)))
         (fx-use! prog ($gprim-vbuf p))
         (cmd-bind-index! ($gprim-ibuf p))
         (when fresh
           (cmd-buffer-data! (gprim-vbase p) (gprim-vbytes p))
           (cmd-index-data! (gprim-ibase p) (gprim-ibytes p)))
         (let ((world (if (null? root)
                          (gprim-world p)
                          (m4-mul (car root) (gprim-world p))))
               (c (gprim-color p)))
           (fx-uniform! prog 'u_mvp (m4-mul vp world))
           (fx-uniform! prog 'u_model world)
           (fx-uniform! prog 'u_color (vector-ref c 0) (vector-ref c 1)
                        (vector-ref c 2) (vector-ref c 3))
           (cmd-draw-elements! GL-TRIANGLES (gprim-icount p)))))
     (gltf-prims g))))
