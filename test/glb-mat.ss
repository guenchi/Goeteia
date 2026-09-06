;; expect: #t
;; (gfx glb) past a base colour: images, samplers, textures and full
;; materials, cameras, more than one skin, and morph targets with
;; normals all go out through new options and come back through the
;; reader's material model -- the round trip is the oracle, as in
;; test/glb.ss.  The old spellings (`color`, a single `skin`) still
;; write the same bytes, and the option pairs that cannot both hold
;; are refused by name.
;;
;; Option shapes (archive/goeteia-p1-design.md, A + r2-7 + r3-2 + r2-8):
;;   images    ((bytevector mime) | (base length mime) ...)
;;   samplers  ((mag min wrap-s wrap-t) ...)        #f = key omitted
;;   textures  ((image . sampler|#f) ...)             the reader's shape
;;   materials ((color (metallic . roughness) emissive
;;               base-tex mr-tex normal-tex emissive-tex occlusion-tex) ...)
;;             each *-tex #f or (texture texcoord factor)
;;   cameras   ((perspective yfov aspect znear zfar) | (orthographic xmag ymag znear zfar) ...)
;;   skins     ((joints ibm-source) ...)
;;   node      (name parent T R S . opts), opts: camera i
;;   prim opts material i | node i | skin i | targets ((pos norm|#f tan|#f) ...) | weights (w ...)
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx gltf) (gfx glb) (web json))
(js-eval "globalThis.__mockcanvas = { width:64, height:64, addEventListener(k,f){}, getContext(kind) { return { createShader(){return {}}, shaderSource(){}, compileShader(){}, getShaderParameter(){return true}, createProgram(){return {}}, attachShader(){}, linkProgram(){}, getProgramParameter(){return true}, bindAttribLocation(){}, getUniformLocation(){return {}}, createBuffer(){return {}}, createVertexArray(){return {}}, createTexture(){return {}}, viewport(){}, enable(){}, clearColor(){}, clear(){} } } }")
(fx-init! (js-get (js-global) "__mockcanvas"))

(define (near? a b) (< (abs (- a b)) 1e-6))
(define (bytes=? a b n)
  (let loop ((i 0))
    (or (= i n)
        (and (= (%mem-u8-ref (+ a i)) (%mem-u8-ref (+ b i))) (loop (+ i 1))))))
(define (rd-u32 at)
  (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))
     (* 65536 (%mem-u8-ref (+ at 2))) (* 16777216 (%mem-u8-ref (+ at 3)))))
;; the JSON chunk of a written GLB, as a document
(define (glb-json loc)
  (let* ((base (car loc)) (jlen (rd-u32 (+ base 12))) (bv (make-bytevector jlen)))
    (let loop ((i 0))
      (when (< i jlen) (bytevector-u8-set! bv i (%mem-u8-ref (+ base 20 i))) (loop (+ i 1))))
    (string->json (utf8->string bv))))

;; ---- one triangle, position normal uv, written into staging ----
(define layout '(position normal uv))
(define stride (glb-stride layout))
(define vcount 3)
(define vbase (fx-alloc! (* vcount stride)))
(let v ((i 0))
  (when (< i vcount)
    (let ((a (+ vbase (* i stride))))
      (%mem-f32-set! a (exact->inexact i)) (%mem-f32-set! (+ a 4) 0.0) (%mem-f32-set! (+ a 8) 0.0)
      (%mem-f32-set! (+ a 12) 0.0) (%mem-f32-set! (+ a 16) 1.0) (%mem-f32-set! (+ a 20) 0.0)
      (%mem-f32-set! (+ a 24) 0.5) (%mem-f32-set! (+ a 28) 0.5))
    (v (+ i 1))))
(define ibase (fx-alloc! 8))
(%mem-u8-set! ibase 0) (%mem-u8-set! (+ ibase 1) 0) (%mem-u8-set! (+ ibase 2) 1) (%mem-u8-set! (+ ibase 3) 0)
(%mem-u8-set! (+ ibase 4) 2) (%mem-u8-set! (+ ibase 5) 0)
(define (prim . opts) (append (list layout vbase vcount ibase 3) opts))

;; a tiny fake PNG: the signature and nothing else -- enough for the
;; structural checks a reader makes, and for bytes to survive intact
(define png (bytevector #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A 1 2 3 4))

;; ---- (a) a full material with two textures over one image ----
(define loc-mat
  (glb-write! (list (prim 'material 0))
              'images (list (list png "image/png"))
              'samplers '((9729 9987 10497 10497) (9728 9728 33071 33071))
              'textures '((0 . 0) (0 . 1))
              'materials (list (list (vector 0.5 0.25 1.0 1.0) (cons 0.2 0.7) (vector 0.1 0.2 0.3)
                                     '(0 0 1.0) '(1 0 1.0) '(0 0 0.6) '(0 0 1.0) '(1 1 0.8)))))
(define g-mat (gltf-parse (car loc-mat) (cdr loc-mat)))
(define p-mat (car (gltf-prims g-mat)))
(define (ref-is? r tex img smp uv factor)
  (and r (= (gtexref-texture r) tex) (= (gtexref-image r) img)
       (= (gtexref-sampler r) smp) (= (gtexref-texcoord r) uv) (near? (gtexref-factor r) factor)))
(define mat-ok
  (and (= (vector-length (gltf-images g-mat)) 1)
       (equal? (gltf-textures g-mat) '#((0 . 0) (0 . 1)))
       (= (vector-length (gltf-samplers g-mat)) 2)
       (= (gsampler-mag (vector-ref (gltf-samplers g-mat) 1)) 9728)
       (= (gsampler-wrap-t (vector-ref (gltf-samplers g-mat) 0)) 10497)
       (near? (vector-ref (gprim-color p-mat) 1) 0.25)
       (near? (gprim-metallic p-mat) 0.2) (near? (gprim-roughness p-mat) 0.7)
       (near? (vector-ref (gprim-emissive p-mat) 2) 0.3)
       (ref-is? (gprim-base-tex p-mat) 0 0 0 0 1.0)
       (ref-is? (gprim-mr-tex p-mat) 1 0 1 0 1.0)
       (ref-is? (gprim-normal-tex p-mat) 0 0 0 0 0.6)
       (ref-is? (gprim-emissive-tex p-mat) 0 0 0 0 1.0)
       (ref-is? (gprim-occlusion-tex p-mat) 1 0 1 1 0.8)
       ;; the image bytes came through untouched
       (let ((img (vector-ref (gltf-images g-mat) 0)))
         (and (= (cadr img) 12)
              (= (%mem-u8-ref (car img)) #x89)
              (= (%mem-u8-ref (+ (car img) 11)) 4)))))

;; the JSON says what the reader cannot see: the scalar KEYS
(define mat-json-ok
  (let ((j (glb-json loc-mat)))
    (and (near? (json-ref j "materials" 0 "normalTexture" "scale") 0.6)
         (near? (json-ref j "materials" 0 "occlusionTexture" "strength") 0.8)
         (= (json-ref j "materials" 0 "occlusionTexture" "texCoord") 1)
         (not (json-ref j "materials" 0 "normalTexture" "strength"))
         (= (json-ref j "textures" 1 "sampler") 1)
         (= (json-ref j "samplers" 1 "wrapS") 33071)
         (equal? (json-ref j "images" 0 "mimeType") "image/png"))))

;; a #f sampler key is omitted, not written as null
(define sampler-omit-ok
  (let* ((loc (glb-write! (list (prim 'material 0))
                          'images (list (list png "image/png"))
                          'samplers '((#f #f 33071 #f))
                          'textures '((0 . 0))
                          'materials (list (list (vector 1.0 1.0 1.0 1.0) (cons 1.0 1.0) (vector 0.0 0.0 0.0)
                                                 '(0 0 1.0) #f #f #f #f))))
         (j (glb-json loc)))
    (and (= (json-ref j "samplers" 0 "wrapS") 33071)
         (not (json-ref j "samplers" 0 "magFilter"))
         (not (json-ref j "samplers" 0 "wrapT")))))

;; ---- (b) a camera on a node ----
(define loc-cam
  (glb-write! (list (prim))
              'nodes (list (list "root" -1 (vector 0.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))
                           (list "eye" 0 (vector 0.0 0.0 5.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0) 'camera 0))
              'mesh-node 0
              'cameras '((perspective 0.8 #f 0.1 #f))))
(define g-cam (gltf-parse (car loc-cam) (cdr loc-cam)))
(define camera-ok
  (let ((cs (gltf-cameras g-cam)) (j (glb-json loc-cam)))
    (and (= (vector-length cs) 1)
         (eq? (vector-ref (vector-ref cs 0) 0) 'perspective)
         (near? (vector-ref (vector-ref cs 0) 1) 0.8)
         (not (vector-ref (vector-ref cs 0) 2))
         (near? (vector-ref (vector-ref cs 0) 3) 0.1)
         (= (gltf-node-camera g-cam 1) 0)
         (not (gltf-node-camera g-cam 0))
         (not (json-ref j "cameras" 0 "perspective" "aspectRatio"))
         (not (json-ref j "cameras" 0 "perspective" "zfar")))))

;; ---- (c) two skins, two meshes on two nodes ----
(define slayout '(position normal joints weights))
(define sstride (glb-stride slayout))
(define svbase (fx-alloc! (* 3 sstride)))
(let v ((i 0))
  (when (< i 3)
    (let ((a (+ svbase (* i sstride))))
      (let k ((j 0)) (when (< j 16) (%mem-f32-set! (+ a (* 4 j)) 0.0) (k (+ j 1))))
      (%mem-f32-set! a (exact->inexact i)) (%mem-f32-set! (+ a 16) 1.0)
      (%mem-f32-set! (+ a 40) 1.0))                      ; weight.x = 1
    (v (+ i 1))))
(define (sprim . opts) (append (list slayout svbase 3 ibase 3) opts))
(define identity16 (vector 1.0 0.0 0.0 0.0 0.0 1.0 0.0 0.0 0.0 0.0 1.0 0.0 0.0 0.0 0.0 1.0))
(define nodes4
  (list (list "a" -1 (vector 0.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))
        (list "ja" 0 (vector 0.0 0.0 1.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))
        (list "b" -1 (vector 4.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))
        (list "jb" 2 (vector 0.0 0.0 2.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))))
(define loc-skins
  (glb-write! (list (sprim 'node 0 'skin 0) (sprim 'node 2 'skin 1))
              'nodes nodes4
              'skins (list (list '(1) (vector identity16)) (list '(3) #f))))
(define g-skins (gltf-parse (car loc-skins) (cdr loc-skins)))
(define skins-ok
  (let ((j (glb-json loc-skins)))
    (and (= (vector-length (gltf-skins g-skins)) 2)
         (equal? (vector-ref (vector-ref (gltf-skins g-skins) 0) 0) '#(1))
         (equal? (vector-ref (vector-ref (gltf-skins g-skins) 1) 0) '#(3))
         (= (length (gltf-prims g-skins)) 2)
         (= (gprim-skin (car (gltf-prims g-skins))) 0)
         (= (gprim-skin (cadr (gltf-prims g-skins))) 1)
         (= (gprim-node (car (gltf-prims g-skins))) 0)
         (= (gprim-node (cadr (gltf-prims g-skins))) 2)
         (= (vector-length (json-ref j "meshes")) 2)
         (= (json-ref j "nodes" 0 "mesh") 0) (= (json-ref j "nodes" 0 "skin") 0)
         (= (json-ref j "nodes" 2 "mesh") 1) (= (json-ref j "nodes" 2 "skin") 1)
         ;; the skin without inverse binds writes no accessor for them
         (not (json-ref j "skins" 1 "inverseBindMatrices")))))

;; the old single-skin spelling is the new one with one element: same bytes
(define nodes2 (list (car nodes4) (cadr nodes4)))
(define loc-old (glb-write! (list (sprim)) 'nodes nodes2 'mesh-node 0
                            'skin (list '(1) (vector identity16))))
(define loc-new (glb-write! (list (sprim)) 'nodes nodes2 'mesh-node 0
                            'skins (list (list '(1) (vector identity16)))))
(define skin-compat-ok
  (and (= (cdr loc-old) (cdr loc-new))
       (bytes=? (car loc-old) (car loc-new) (cdr loc-old))))

;; ---- (d) morph targets with normals ----
(define dpos (vector 0.0 0.0 1.0  0.0 0.0 1.0  0.0 0.0 1.0))
(define dnrm (vector 0.1 0.2 0.3  0.1 0.2 0.3  0.1 0.2 0.3))
(define loc-morph
  (glb-write! (list (prim 'targets (list (list dpos dnrm #f) (list dpos #f #f)) 'weights '(0.5 0.25)))))
(define g-morph (gltf-parse (car loc-morph) (cdr loc-morph)))
(define p-morph (car (gltf-prims g-morph)))
(define morph-ok
  (let ((mo (gprim-morph p-morph)) (j (glb-json loc-morph)))
    (and mo
         (= (vector-length (vector-ref mo 1)) 2)
         (near? (vector-ref (vector-ref mo 2) 0) 0.5)
         (near? (vector-ref (vector-ref mo 2) 1) 0.25)
         (near? (vector-ref (vector-ref (vector-ref mo 1) 0) 2) 1.0)
         (let ((dn (gprim-morph-normals p-morph)))
           (and dn (= (vector-length dn) 2)
                (vector-ref dn 0) (near? (vector-ref (vector-ref dn 0) 4) 0.2)
                (not (vector-ref dn 1))))
         (= (vector-length (json-ref j "meshes" 0 "primitives" 0 "targets")) 2)
         (json-ref j "meshes" 0 "primitives" 0 "targets" 0 "NORMAL")
         (not (json-ref j "meshes" 0 "primitives" 0 "targets" 1 "NORMAL"))
         (= (vector-length (json-ref j "meshes" 0 "weights")) 2))))

;; ---- (e) refusals, each by name ----
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
(define refusals-ok
  (and (refused? 'glb-write! (lambda () (glb-write! (list (prim 'color (vector 1.0 1.0 1.0 1.0) 'material 0))
                                                     'materials (list (list (vector 1.0 1.0 1.0 1.0) (cons 1.0 1.0) (vector 0.0 0.0 0.0) #f #f #f #f #f)))))
       (refused? 'glb-write! (lambda () (glb-write! (list (sprim)) 'nodes nodes2 'mesh-node 0
                                                     'skin (list '(1) #f) 'skins (list (list '(1) #f)))))
       (refused? 'glb-write! (lambda () (glb-write! (list (prim 'targets (list (list dpos #f #f)) 'weights '(0.5 0.25))))))
       (refused? 'glb-write! (lambda () (glb-write! (list (sprim 'node 0 'skin 0) (sprim 'node 0 'skin 1))
                                                     'nodes nodes4
                                                     'skins (list (list '(1) #f) (list '(3) #f)))))))

;; ---- (f) an absent base colour stays absent ----
;; gprim-color is the RENDERING value: a material without a
;; baseColorFactor reads as the 0.8 grey every untextured primitive
;; draws with, which is not the spec's [1,1,1,1] and so cannot be
;; undone by a caller.  gprim-base-color-factor is the FILE's value,
;; #f when the key is absent, and a #f colour in a writer material
;; omits the key -- so absence survives a round trip.
(define loc-nocolor
  (glb-write! (list (prim 'material 0))
              'materials (list (list #f (cons 1.0 1.0) (vector 0.0 0.0 0.0) #f #f #f #f #f))))
(define g-nocolor (gltf-parse (car loc-nocolor) (cdr loc-nocolor)))
(define absent-color-ok
  (let ((j (glb-json loc-nocolor)) (p (car (gltf-prims g-nocolor))))
    (and (not (json-ref j "materials" 0 "pbrMetallicRoughness" "baseColorFactor"))
         (not (gprim-base-color-factor p))
         (near? (vector-ref (gprim-color p) 0) 0.8)           ; the rendering fallback is untouched
         (equal? (gprim-base-color-factor p-mat) (vector 0.5 0.25 1.0 1.0)))))   ; and a written one reads back as written

;; ---- (g) a NORMAL-only target: positions may be absent ----
(define loc-nrm-only
  (glb-write! (list (prim 'targets (list (list #f dnrm #f)) 'weights '(1.0)))))
(define g-nrm-only (gltf-parse (car loc-nrm-only) (cdr loc-nrm-only)))
(define normal-only-target-ok
  (let ((j (glb-json loc-nrm-only)) (p (car (gltf-prims g-nrm-only))))
    (and (json-ref j "meshes" 0 "primitives" 0 "targets" 0 "NORMAL")
         (not (json-ref j "meshes" 0 "primitives" 0 "targets" 0 "POSITION"))
         (gprim-morph p)
         (near? (vector-ref (vector-ref (vector-ref (gprim-morph p) 1) 0) 2) 0.0)   ; no position delta
         (near? (vector-ref (vector-ref (gprim-morph-normals p) 0) 1) 0.2))))

;; ---- (h) a target's POSITION accessor carries min/max like any POSITION ----
(define morph-bounds-ok
  (let* ((j (glb-json loc-morph))
         (ai (json-ref j "meshes" 0 "primitives" 0 "targets" 0 "POSITION"))
         (a (json-ref j "accessors" ai)))
    (and (json-ref a "min") (json-ref a "max")
         (near? (exact->inexact (vector-ref (json-ref a "min") 2)) 1.0)
         (near? (exact->inexact (vector-ref (json-ref a "max") 2)) 1.0))))

;; ---- (i) spelling variants of "nothing here" write the same bytes ----
;; An asset read back from a file with no skins and no images hands the
;; writer empty lists; they must mean what omitting the option means.
(define loc-plain (glb-write! (list (prim))))
(define loc-empties (glb-write! (list (prim)) 'skins '() 'images '() 'samplers '() 'textures '() 'materials '() 'cameras '()))
(define empties-ok
  (and (= (cdr loc-plain) (cdr loc-empties))
       (bytes=? (car loc-plain) (car loc-empties) (cdr loc-plain))))
;; a legacy mesh-node written as a flonum index still attaches the mesh
(define loc-mn-int (glb-write! (list (prim)) 'nodes nodes2 'mesh-node 0))
(define loc-mn-fl (glb-write! (list (prim)) 'nodes nodes2 'mesh-node 0.0))
(define loc-pn-int (glb-write! (list (prim 'node 0)) 'nodes nodes2))
(define loc-pn-fl (glb-write! (list (prim 'node 0.0)) 'nodes nodes2))
(define mesh-node-flonum-ok
  (and (= (cdr loc-mn-int) (cdr loc-mn-fl))
       (bytes=? (car loc-mn-int) (car loc-mn-fl) (cdr loc-mn-int))
       (= (json-ref (glb-json loc-mn-fl) "nodes" 0 "mesh") 0)
       ;; and a primitive's own node index, spelled 0.0, still attaches
       (= (cdr loc-pn-int) (cdr loc-pn-fl))
       (bytes=? (car loc-pn-int) (car loc-pn-fl) (cdr loc-pn-int))
       (= (json-ref (glb-json loc-pn-fl) "nodes" 0 "mesh") 0)))

;; ---- (j) one mesh, one weights list: primitives grouped on a node
;; must agree on their targets ----
(define grouped-morph-refusals-ok
  (and (refused? 'glb-write!
                 (lambda () (glb-write! (list (prim 'node 0 'targets (list (list dpos #f #f)) 'weights '(0.5))
                                              (prim 'node 0 'targets (list (list dpos #f #f)) 'weights '(0.25)))
                                        'nodes nodes2)))
       (refused? 'glb-write!
                 (lambda () (glb-write! (list (prim 'node 0 'targets (list (list dpos #f #f)) 'weights '(0.5))
                                              (prim 'node 0 'targets (list (list dpos #f #f) (list dpos #f #f)) 'weights '(0.5 0.5)))
                                        'nodes nodes2)))
       ;; and agreeing ones group: one mesh, two primitives, one weights list
       (let* ((loc (glb-write! (list (prim 'node 0 'targets (list (list dpos #f #f)) 'weights '(0.5))
                                     (prim 'node 0 'targets (list (list dpos #f #f)) 'weights '(0.5)))
                               'nodes nodes2))
              (j (glb-json loc)))
         (and (= (vector-length (json-ref j "meshes")) 1)
              (= (vector-length (json-ref j "meshes" 0 "primitives")) 2)
              (= (vector-length (json-ref j "meshes" 0 "weights")) 1)))))

;; ---- (k) everything at once: the allocation order under load ----
;; An unindexed primitive between two indexed ones, three skins of
;; which the middle has no inverse binds, targets with holes, u16
;; joints and two images: every block must be found where its index
;; says, which the reader's values prove -- a view or accessor off by
;; one reads some other block's bytes.
;; a second skinned triangle whose joints are DISTINCT per vertex (0 1 2),
;; so the decoded values, not only the component type, say the u16
;; block was found
(define svbase2 (fx-alloc! (* 3 sstride)))
(let v ((i 0))
  (when (< i 3)
    (let ((a (+ svbase2 (* i sstride))))
      (let k ((j 0)) (when (< j 16) (%mem-f32-set! (+ a (* 4 j)) 0.0) (k (+ j 1))))
      (%mem-f32-set! a (exact->inexact i)) (%mem-f32-set! (+ a 16) 1.0)
      (%mem-f32-set! (+ a 24) (exact->inexact i))        ; joints.x = i
      (%mem-f32-set! (+ a 40) 1.0))
    (v (+ i 1))))
(define sprim-noidx (list slayout svbase2 3 #f 0 'node 2 'skin 1 'joints-u16? #t))
(define dnrm2 (vector 0.7 0.8 0.9  0.7 0.8 0.9  0.7 0.8 0.9))   ; not the other target's numbers
(define dtan (vector 0.4 0.5 0.6  0.4 0.5 0.6  0.4 0.5 0.6))
(define nodes6
  (append nodes4
          (list (list "c" -1 (vector 8.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))
                (list "jc" 4 (vector 0.0 0.0 3.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0)))))
(define ibm-c (vector 1.0 0.0 0.0 0.0 0.0 1.0 0.0 0.0 0.0 0.0 1.0 0.0 0.0 0.0 -3.0 1.0))
(define loc-all
  (glb-write! (list (sprim 'node 0 'skin 0 'material 0 'targets (list (list dpos dnrm #f) (list #f dnrm2 #f)) 'weights '(0.5 0.25))
                    sprim-noidx
                    (sprim 'node 4 'skin 2))
              'nodes nodes6
              ;; the middle skin has THREE joints so the u16 primitive's 0 1 2 are in range
              'skins (list (list '(1) (vector identity16)) (list '(3 1 5) #f) (list '(5) (vector ibm-c)))
              'anims (list (list "slide" (list (list 1 'translation (vector 0.0 1.0) (vector (vector 0.0 0.0 0.0) (vector 2.0 0.0 0.0)) 2 'linear))))
              'images (list (list png "image/png") (list (bytevector 1 2 3 4 5 6 7 8) "image/png"))
              'samplers '((9729 9729 10497 10497))
              'textures '((0 . 0) (1 . 0))
              'materials (list (list (vector 1.0 1.0 1.0 1.0) (cons 1.0 1.0) (vector 0.0 0.0 0.0) '(1 0 1.0) #f #f #f #f))))
(define g-all (gltf-parse (car loc-all) (cdr loc-all)))
(define all-ok
  (let ((ps (gltf-prims g-all)) (j (glb-json loc-all)))
    (and (= (length ps) 3)
         ;; the unindexed primitive has no indices in the file (the reader
         ;; counts its vertices as its draw count) and its u16 joints read back
         (not (json-ref j "meshes" 1 "primitives" 0 "indices"))
         (= (gprim-icount (cadr ps)) 3)
         (= (json-ref j "accessors" (json-ref j "meshes" 1 "primitives" 0 "attributes" "JOINTS_0") "componentType") 5123)
         ;; skins: the middle one writes no inverseBindMatrices (the reader
         ;; fills identity), the third's one joint matrix carries -3 in its
         ;; translation column
         (= (vector-length (gltf-skins g-all)) 3)
         (not (json-ref j "skins" 1 "inverseBindMatrices"))
         (near? (vector-ref (vector-ref (vector-ref (vector-ref (gltf-skins g-all) 2) 1) 0) 14) -3.0)
         ;; the u16 joints decode to 0 1 2, vertex by vertex -- read at the
         ;; joints slot of the layout the READER built (it pads a uv slot
         ;; in, so the offset is not the writer-side 24)
         (let* ((q (cadr ps)) (off (glb-offset (gprim-layout q) 'joints)) (st (gprim-stride q)))
           (and (near? (%mem-f32-ref (+ (gprim-vbase q) off)) 0.0)
                (near? (%mem-f32-ref (+ (gprim-vbase q) st off)) 1.0)
                (near? (%mem-f32-ref (+ (gprim-vbase q) (* 2 st) off)) 2.0)))
         ;; morph: target 1 has no positions (zero delta); the two targets'
         ;; normals differ, so an aliased accessor would show
         (let ((mo (gprim-morph (car ps))) (dn (gprim-morph-normals (car ps))))
           (and mo (= (vector-length (vector-ref mo 1)) 2)
                (near? (vector-ref (vector-ref (vector-ref mo 1) 1) 2) 0.0)
                (near? (vector-ref (vector-ref dn 0) 4) 0.2)
                (near? (vector-ref (vector-ref dn 1) 4) 0.8)))
         ;; the animation block sits where its indices say: one clip, node 1, x goes 0 -> 2
         (= (vector-length (gltf-anims g-all)) 1)
         (let ((ch (vector-ref (vector-ref (vector-ref (gltf-anims g-all) 0) 1) 0)))
           (and (= (vector-ref ch 0) 1)
                (eq? (vector-ref ch 1) 'translation)
                (near? (vector-ref (vector-ref (vector-ref ch 3) 1) 0) 2.0)))
         ;; images: the second image's bytes are the second image's bytes
         (let ((im (vector-ref (gltf-images g-all) 1)))
           (and (= (cadr im) 8) (= (%mem-u8-ref (car im)) 1) (= (%mem-u8-ref (+ (car im) 7)) 8)))
         ;; the material's base texture reaches image 1
         (= (gtexref-image (gprim-base-tex (car ps))) 1))))

;; ---- (l) a TANGENT delta needs a TANGENT to displace ----
;; glTF: a target may only carry an attribute its primitive has.  On a
;; primitive with tangents the delta round-trips; on one without, the
;; writer refuses by name rather than write a file readers reject.
(define tlayout '(position normal uv tangent))
(define tstride (glb-stride tlayout))
(define tbase (fx-alloc! (* 3 tstride)))
(let v ((i 0))
  (when (< i 3)
    (let ((a (+ tbase (* i tstride))))
      (let k ((j 0)) (when (< j 12) (%mem-f32-set! (+ a (* 4 j)) 0.0) (k (+ j 1))))
      (%mem-f32-set! a (exact->inexact i)) (%mem-f32-set! (+ a 16) 1.0)
      (%mem-f32-set! (+ a 32) 1.0) (%mem-f32-set! (+ a 44) 1.0))          ; tangent (1 0 0 1)
    (v (+ i 1))))
(define (tprim . opts) (append (list tlayout tbase 3 ibase 3) opts))
(define loc-tan (glb-write! (list (tprim 'targets (list (list dpos #f dtan)) 'weights '(1.0)))))
(define g-tan (gltf-parse (car loc-tan) (cdr loc-tan)))
(define tangent-target-ok
  (let ((j (glb-json loc-tan)) (p (car (gltf-prims g-tan))) (dt (gprim-morph-tangents (car (gltf-prims g-tan)))))
    (and (json-ref j "meshes" 0 "primitives" 0 "targets" 0 "TANGENT")
         (json-ref j "meshes" 0 "primitives" 0 "attributes" "TANGENT")
         dt (near? (vector-ref (vector-ref dt 0) 4) 0.5))))
(define tangent-target-needs-base-ok
  (refused? 'glb-write! (lambda () (glb-write! (list (prim 'targets (list (list dpos #f dtan)) 'weights '(1.0)))))))

(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)
(let ((all (list (report "mat" mat-ok) (report "mat-json" mat-json-ok) (report "sampler-omit" sampler-omit-ok)
                 (report "camera" camera-ok) (report "skins" skins-ok) (report "skin-compat" skin-compat-ok)
                 (report "morph" morph-ok) (report "refusals" refusals-ok)
                 (report "absent-color" absent-color-ok)
                 (report "normal-only-target" normal-only-target-ok) (report "morph-bounds" morph-bounds-ok)
                 (report "empties" empties-ok) (report "mesh-node-flonum" mesh-node-flonum-ok)
                 (report "grouped-morph" grouped-morph-refusals-ok) (report "all" all-ok)
                 (report "tangent-target" tangent-target-ok) (report "tangent-target-needs-base" tangent-target-needs-base-ok))))
  (let loop ((l all)) (or (null? l) (and (car l) (loop (cdr l))))))
