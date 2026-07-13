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
;; Untextured primitives come out in mesh-lit-vs's 24-byte layout;
;; primitives with TEXCOORD_0 come out at 32 bytes for mesh-tex-vs,
;; and (gltf-load-textures! g k) decodes the embedded images and
;; hands each one its texture.  Skins and animations are not loaded
;; (yet); a missing NORMAL becomes +y.
;;
;; (gltf-parse base len) works on any GLB bytes already in staging
;; memory, so parsing verifies headlessly; gltf-fetch! is the
;; browser-side loader (fetch -> one bulk copy into staging).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web gltf)
  (export gltf? gltf-prims gltf-images gltf-parse gltf-fetch!
          gltf-load-textures! gltf-draw!
          gltf-anims gltf-animation-names gltf-animate!
          gltf-animate-blend! gltf-weights! gprim-morph
          gltf-joint-matrices gltf-skin-vs
          gprim-vbase gprim-vbytes gprim-ibase gprim-ibytes
          gprim-icount gprim-color gprim-metallic gprim-roughness
          gprim-world gprim-stride gprim-tex)
  (import (rnrs) (web js) (web gl) (web fx) (web mat) (web json))

  (define ($gltf-fl v) (if (flonum? v) v (exact->inexact v)))

  (define-record-type (gltf $make-gltf gltf?)
    (fields (immutable prims gltf-prims)
            ;; per image: (abs-offset byte-length mime), in staging
            (immutable images gltf-images)
            (immutable nodes gltf-nodes)      ; runtime TRS, animatable
            (immutable skins gltf-skins)      ; #(joint-nodes ibms)
            (immutable anims gltf-anims)))    ; #(name channels duration)

  ;; primitives are open records: custom renderers can reach the
  ;; staging offsets and draw with their own shaders
  (define-record-type ($gprim $make-gprim $gprim?)
    (fields (immutable vbase gprim-vbase)
            (immutable vbytes gprim-vbytes)
            (immutable ibase gprim-ibase)
            (immutable ibytes gprim-ibytes)
            (immutable icount gprim-icount)
            (immutable color gprim-color)     ; r g b a flonum vector
            (immutable mr $gprim-mr)          ; (metallic . roughness)
            (immutable world gprim-world)     ; m4
            (immutable stride gprim-stride)   ; 24, or 32 with uvs
            (immutable tex-img $gprim-tex-img); image index | #f
            (immutable skin $gprim-skin)      ; skin index | #f
            ;; #(base-positions target-deltas weights dirty node) | #f
            (mutable morph gprim-morph $gprim-morph!)
            (mutable tex gprim-tex $gprim-tex!)  ; texture slot | #f
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

  (define ($glb-m4 at)                    ; 16 f32s -> an m4
    (let ((m (make-vector 16 0.0)))
      (let loop ((i 0))
        (when (< i 16)
          (vector-set! m i (%mem-f32-ref (+ at (* 4 i))))
          (loop (+ i 1))))
      m))

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

  ;; the metallic-roughness factors, spec defaults of 1.0 when absent
  (define ($material-mr json mi)
    (if (not mi)
        '(1.0 . 1.0)
        (let* ((mat (vector-ref (json-ref json "materials") mi))
               (m (json-ref mat "pbrMetallicRoughness" "metallicFactor"))
               (r (json-ref mat "pbrMetallicRoughness"
                            "roughnessFactor")))
          (cons (if m ($gltf-fl m) 1.0)
                (if r ($gltf-fl r) 1.0)))))
  (define (gprim-metallic p) (car ($gprim-mr p)))
  (define (gprim-roughness p) (cdr ($gprim-mr p)))

  ;; material -> baseColorTexture -> texture -> source image index
  (define ($prim-tex-image json prim)
    (let ((mi (json-ref prim "material")))
      (and mi
           (let* ((mat (vector-ref (json-ref json "materials") mi))
                  (bct (json-ref mat "pbrMetallicRoughness"
                                 "baseColorTexture")))
             (and bct
                  (let ((ti (json-ref bct "index")))
                    (json-ref (vector-ref (json-ref json "textures") ti)
                              "source")))))))

  ;; the embedded images: absolute staging offsets for later decode
  (define ($gltf-image-table json bin)
    (let ((imgs (json-ref json "images")))
      (if (not imgs)
          (vector)
          (let* ((n (vector-length imgs))
                 (out (make-vector n #f)))
            (let loop ((k 0))
              (when (< k n)
                (let* ((img (vector-ref imgs k))
                       (bv (vector-ref (json-ref json "bufferViews")
                                       (json-ref img "bufferView"))))
                  (vector-set! out k
                               (list (+ bin ($or0 (json-ref bv "byteOffset")))
                                     (json-ref bv "byteLength")
                                     (let ((m (json-ref img "mimeType")))
                                       (if m m "image/png")))))
                (loop (+ k 1))))
            out))))

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

  ;; ---- the runtime node tree (what animations drive) ----
  ;; a node is a 12-slot vector: tx ty tz  qx qy qz qw  sx sy sz
  ;; matrix|#f parent
  (define ($gltf-node-table json)
    (let* ((ns (json-ref json "nodes"))
           (n (if ns (vector-length ns) 0))
           (out (make-vector n #f)))
      (let loop ((k 0))
        (when (< k n)
          (let* ((nd (vector-ref ns k))
                 (tr (json-ref nd "translation"))
                 (rq (json-ref nd "rotation"))
                 (sc (json-ref nd "scale"))
                 (mx (json-ref nd "matrix"))
                 (v (make-vector 12 0.0)))
            (when tr
              (vector-set! v 0 ($gltf-fl (vector-ref tr 0)))
              (vector-set! v 1 ($gltf-fl (vector-ref tr 1)))
              (vector-set! v 2 ($gltf-fl (vector-ref tr 2))))
            (if rq
                (begin
                  (vector-set! v 3 ($gltf-fl (vector-ref rq 0)))
                  (vector-set! v 4 ($gltf-fl (vector-ref rq 1)))
                  (vector-set! v 5 ($gltf-fl (vector-ref rq 2)))
                  (vector-set! v 6 ($gltf-fl (vector-ref rq 3))))
                (vector-set! v 6 1.0))
            (if sc
                (begin
                  (vector-set! v 7 ($gltf-fl (vector-ref sc 0)))
                  (vector-set! v 8 ($gltf-fl (vector-ref sc 1)))
                  (vector-set! v 9 ($gltf-fl (vector-ref sc 2))))
                (begin (vector-set! v 7 1.0)
                       (vector-set! v 8 1.0)
                       (vector-set! v 9 1.0)))
            (vector-set! v 10
                         (and mx
                              (let ((m (make-vector 16 0.0)))
                                (let cp ((i 0))
                                  (when (< i 16)
                                    (vector-set! m i ($gltf-fl
                                                      (vector-ref mx i)))
                                    (cp (+ i 1))))
                                m)))
            (vector-set! v 11 -1)
            (vector-set! out k v))
          (loop (+ k 1))))
      ;; children point back at their parents
      (let loop ((k 0))
        (when (< k n)
          (let ((kids (json-ref (vector-ref ns k) "children")))
            (when kids
              (let kid ((i 0))
                (when (< i (vector-length kids))
                  (vector-set! (vector-ref out (vector-ref kids i)) 11 k)
                  (kid (+ i 1))))))
          (loop (+ k 1))))
      out))

  (define ($node-local v)
    (let ((mx (vector-ref v 10)))
      (or mx
          (m4-mul (m4-translate (vector-ref v 0) (vector-ref v 1)
                                (vector-ref v 2))
                  (m4-mul (m4-from-quat (vector-ref v 3) (vector-ref v 4)
                                        (vector-ref v 5) (vector-ref v 6))
                          (m4-scale (vector-ref v 7) (vector-ref v 8)
                                    (vector-ref v 9)))))))

  (define ($node-global g i)
    (let* ((v (vector-ref (gltf-nodes g) i))
           (local ($node-local v))
           (p (vector-ref v 11)))
      (if (< p 0) local (m4-mul ($node-global g p) local))))

  (define ($gltf-skin-table json bin)
    (let* ((sk (json-ref json "skins"))
           (n (if sk (vector-length sk) 0))
           (out (make-vector n #f)))
      (let loop ((k 0))
        (when (< k n)
          (let* ((skin (vector-ref sk k))
                 (js (json-ref skin "joints"))
                 (nj (vector-length js))
                 (joints (make-vector nj 0))
                 (ibms (make-vector nj #f))
                 (ibm-acc (json-ref skin "inverseBindMatrices"))
                 (inf (and ibm-acc ($acc-info json bin ibm-acc 64))))
            (when (> nj 32)
              (error 'gltf "too many joints for the skin shader" nj))
            (let j ((i 0))
              (when (< i nj)
                (vector-set! joints i (vector-ref js i))
                (vector-set! ibms i
                             (if inf
                                 ($glb-m4 (+ (car inf) (* i (cadr inf))))
                                 (m4-identity)))
                (j (+ i 1))))
            (vector-set! out k (vector joints ibms)))
          (loop (+ k 1))))
      out))

  ;; a channel: #(node path times values); values are vec3s (or quat
  ;; 4-vectors for rotation), one per keyframe
  (define ($gltf-anim-table json bin)
    (let* ((as (json-ref json "animations"))
           (n (if as (vector-length as) 0))
           (out (make-vector n #f)))
      (let loop ((k 0))
        (when (< k n)
          (let* ((a (vector-ref as k))
                 (samplers (json-ref a "samplers"))
                 (chans (json-ref a "channels"))
                 (nc (vector-length chans))
                 (cout (make-vector nc #f))
                 (dur 0.0))
            (let ch ((c 0))
              (when (< c nc)
                (let* ((chan (vector-ref chans c))
                       (smp (vector-ref samplers (json-ref chan "sampler")))
                       (path (string->symbol
                              (json-ref chan "target" "path")))
                       (tin ($acc-info json bin (json-ref smp "input") 4))
                       (nk (caddr tin))
                       (vin ($acc-info json bin (json-ref smp "output")
                                       (case path
                                         ((rotation) 16)
                                         ((weights) 4)   ; scalars
                                         (else 12))))
                       ;; weights: the accessor holds nk * n-targets
                       (ncomp (case path
                                ((rotation) 4)
                                ((weights) (if (> nk 0)
                                               (quotient (caddr vin) nk)
                                               0))
                                (else 3)))
                       (kstride (if (eq? path 'weights)
                                    (* ncomp (cadr vin))
                                    (cadr vin)))
                       (times (make-vector nk 0.0))
                       (vals (make-vector nk #f)))
                  (let kf ((i 0))
                    (when (< i nk)
                      (vector-set! times i
                                   (%mem-f32-ref (+ (car tin)
                                                    (* i (cadr tin)))))
                      (let ((vat (+ (car vin) (* i kstride)))
                            (v (make-vector ncomp 0.0)))
                        (let comp ((j 0))
                          (when (< j ncomp)
                            (vector-set! v j (%mem-f32-ref (+ vat (* 4 j))))
                            (comp (+ j 1))))
                        (vector-set! vals i v))
                      (kf (+ i 1))))
                  (when (> nk 0)
                    (let ((last (vector-ref times (- nk 1))))
                      (when (fl<? dur last) (set! dur last))))
                  (vector-set! cout c
                               (vector (json-ref chan "target" "node")
                                       path times vals)))
                (ch (+ c 1))))
            (vector-set! out k
                         (vector (let ((nm (json-ref a "name")))
                                   (if nm nm "anim"))
                                 cout dur)))
          (loop (+ k 1))))
      out))

  ;; shortest-path normalized lerp: indistinguishable from slerp at
  ;; keyframe spacing
  (define ($q-nlerp a b t)
    (let* ((dot (fl+ (fl+ (fl* (vector-ref a 0) (vector-ref b 0))
                          (fl* (vector-ref a 1) (vector-ref b 1)))
                     (fl+ (fl* (vector-ref a 2) (vector-ref b 2))
                          (fl* (vector-ref a 3) (vector-ref b 3)))))
           (sgn (if (fl<? dot 0.0) -1.0 1.0))
           (u (fl- 1.0 t))
           (x (fl+ (fl* u (vector-ref a 0)) (fl* (fl* t sgn) (vector-ref b 0))))
           (y (fl+ (fl* u (vector-ref a 1)) (fl* (fl* t sgn) (vector-ref b 1))))
           (z (fl+ (fl* u (vector-ref a 2)) (fl* (fl* t sgn) (vector-ref b 2))))
           (w (fl+ (fl* u (vector-ref a 3)) (fl* (fl* t sgn) (vector-ref b 3))))
           (n (flsqrt (fl+ (fl+ (fl* x x) (fl* y y))
                           (fl+ (fl* z z) (fl* w w))))))
      (vector (fl/ x n) (fl/ y n) (fl/ z n) (fl/ w n))))

  ;; write channel ch's value at time tw into its node's TRS; w < 1
  ;; blends toward the sampled value from whatever the node already
  ;; holds -- the crossfade primitive
  (define ($chan-sample! g ch tw w)
    (let* ((times (vector-ref ch 2))
           (vals (vector-ref ch 3))
           (n (vector-length times))
           (node (vector-ref (gltf-nodes g) (vector-ref ch 0)))
           (path (vector-ref ch 1)))
      (when (> n 0)
        (let find ((k 0))
          (if (and (< (+ k 1) n)
                   (fl<? (vector-ref times (+ k 1)) tw))
              (find (+ k 1))
              (let* ((k1 (if (< (+ k 1) n) (+ k 1) k))
                     (t0 (vector-ref times k))
                     (t1 (vector-ref times k1))
                     (span (fl- t1 t0))
                     (a (if (fl<? span 0.000001)
                            0.0
                            (fl/ (fl- tw t0) span)))
                     (a (if (fl<? a 0.0) 0.0 (if (fl<? 1.0 a) 1.0 a)))
                     (v0 (vector-ref vals k))
                     (v1 (vector-ref vals k1)))
                (cond
                 ((eq? path 'weights)
                  ;; morph weights: lerp element-wise, route to the
                  ;; node's primitives, mark them dirty
                  (for-each
                   (lambda (pr)
                     (let ((mo (gprim-morph pr)))
                       (when (and mo (= (vector-ref mo 4)
                                        (vector-ref ch 0)))
                         (let ((tw2 (vector-ref mo 2)))
                           (let wj ((j 0))
                             (when (and (< j (vector-length tw2))
                                        (< j (vector-length v0)))
                               (let ((s (fl+ (fl* (fl- 1.0 a)
                                                  (vector-ref v0 j))
                                             (fl* a (vector-ref v1 j)))))
                                 (vector-set!
                                  tw2 j
                                  (if (fl<? w 1.0)
                                      (fl+ (fl* (fl- 1.0 w)
                                                (vector-ref tw2 j))
                                           (fl* w s))
                                      s)))
                               (wj (+ j 1)))))
                         (vector-set! mo 3 #t))))
                   (gltf-prims g)))
                 ((eq? path 'rotation)
                  (let* ((qs ($q-nlerp v0 v1 a))
                         (q (if (fl<? w 1.0)
                                ($q-nlerp (vector (vector-ref node 3)
                                                  (vector-ref node 4)
                                                  (vector-ref node 5)
                                                  (vector-ref node 6))
                                          qs w)
                                qs)))
                    (vector-set! node 3 (vector-ref q 0))
                    (vector-set! node 4 (vector-ref q 1))
                    (vector-set! node 5 (vector-ref q 2))
                    (vector-set! node 6 (vector-ref q 3))))
                 (else
                  (let* ((base (if (eq? path 'translation) 0 7))
                         (u (fl- 1.0 a)))
                    (let comp ((j 0))
                      (when (< j 3)
                        (let ((s (fl+ (fl* u (vector-ref v0 j))
                                      (fl* a (vector-ref v1 j)))))
                          (vector-set!
                           node (+ base j)
                           (if (fl<? w 1.0)
                               (fl+ (fl* (fl- 1.0 w)
                                         (vector-ref node (+ base j)))
                                    (fl* w s))
                               s)))
                        (comp (+ j 1)))))))))))))

  ;; sample animation `ai` at time t (looping over its duration):
  ;; every channel writes its node's TRS
  (define (gltf-animate! g ai t)
    (let* ((anim (vector-ref (gltf-anims g) ai))
           (chans (vector-ref anim 1))
           (dur (vector-ref anim 2))
           (tf ($gltf-fl t))
           (tw (if (fl<? dur 0.000001)
                   0.0
                   (fl- tf (fl* dur (flfloor (fl/ tf dur)))))))
      (let loop ((c 0))
        (when (< c (vector-length chans))
          ($chan-sample! g (vector-ref chans c) tw 1.0)
          (loop (+ c 1))))))

  ;; the crossfade: pose animation ai at ti, then blend animation
  ;; aj's pose at tj over it with weight k (0 = all ai, 1 = all aj)
  (define (gltf-animate-blend! g ai ti aj tj k)
    (gltf-animate! g ai ti)
    (let* ((anim (vector-ref (gltf-anims g) aj))
           (chans (vector-ref anim 1))
           (dur (vector-ref anim 2))
           (kf (let ((kf ($gltf-fl k)))
                 (if (fl<? kf 0.0) 0.0 (if (fl<? 1.0 kf) 1.0 kf))))
           (tf ($gltf-fl tj))
           (tw (if (fl<? dur 0.000001)
                   0.0
                   (fl- tf (fl* dur (flfloor (fl/ tf dur)))))))
      (let loop ((c 0))
        (when (< c (vector-length chans))
          ($chan-sample! g (vector-ref chans c) tw kf)
          (loop (+ c 1))))))

  (define (gltf-animation-names g)
    (let ((as (gltf-anims g)))
      (let loop ((k (- (vector-length as) 1)) (acc '()))
        (if (< k 0)
            acc
            (loop (- k 1) (cons (vector-ref (vector-ref as k) 0) acc))))))

  ;; joint matrices for one skin: global(joint) x inverse-bind
  (define (gltf-joint-matrices g si)
    (let* ((skin (vector-ref (gltf-skins g) si))
           (joints (vector-ref skin 0))
           (ibms (vector-ref skin 1))
           (n (vector-length joints))
           (out (make-vector n #f)))
      (let loop ((k 0))
        (when (< k n)
          (vector-set! out k
                       (m4-mul ($node-global g (vector-ref joints k))
                               (vector-ref ibms k)))
          (loop (+ k 1))))
      out))

  ;; the skinning vertex shader: 4 joints x 4 weights per vertex,
  ;; pair with mesh-tex-fs (or mesh-lit-fs won't match the varyings)
  (define gltf-skin-vs
    '((attribute vec3 a_pos)
      (attribute vec3 a_normal)
      (attribute vec2 a_uv)
      (attribute vec4 a_joints)
      (attribute vec4 a_weights)
      (uniform mat4 u_mvp)
      (uniform (array mat4 32) u_joints)
      (varying vec3 v_normal)
      (varying vec2 v_uv)
      (define (main) void
        (local mat4 skin
               (+ (* a_weights.x (at u_joints (int a_joints.x)))
                  (* a_weights.y (at u_joints (int a_joints.y)))
                  (* a_weights.z (at u_joints (int a_joints.z)))
                  (* a_weights.w (at u_joints (int a_joints.w)))))
        (set! gl_Position (* u_mvp (* skin (vec4 a_pos (fl 1)))))
        (set! v_normal (vec3 (* skin (vec4 a_normal (fl 0)))))
        (set! v_uv a_uv))))

  ;; one primitive: interleave pos+normal (+uv when the asset has
  ;; TEXCOORD_0) and pack u16 index pairs into fresh staging memory
  (define ($build-prim json bin prim world skin nidx mw)
    (let* ((attrs (json-ref prim "attributes"))
           (pos ($acc-info json bin (json-ref attrs "POSITION") 12))
           (nrm (let ((i (json-ref attrs "NORMAL")))
                  (and i ($acc-info json bin i 12))))
           (uv (let ((i (json-ref attrs "TEXCOORD_0")))
                 (and i ($acc-info json bin i 8))))
           (jn (let ((i (json-ref attrs "JOINTS_0")))
                 (and i skin
                      (let ((inf ($acc-info json bin i 0)))
                        ;; tight stride depends on the component type
                        (list (car inf)
                              (if (= (cadr inf) 0)
                                  (if (= (cadddr inf) 5123) 8 4)
                                  (cadr inf))
                              (caddr inf) (cadddr inf))))))
           (wt (and jn
                    (let ((i (json-ref attrs "WEIGHTS_0")))
                      (and i ($acc-info json bin i 16)))))
           (count (caddr pos))
           (stride (cond ((and jn wt) 64) (uv 32) (else 24)))
           (vbytes (* stride count))
           (vbase (fx-alloc! vbytes)))
      (unless (= (cadddr pos) 5126)
        (error 'gltf "positions must be float32" (cadddr pos)))
      (let copy ((v 0))
        (when (< v count)
          (let ((src (+ (car pos) (* v (cadr pos))))
                (dst (+ vbase (* v stride))))
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
                  (%mem-f32-set! (+ dst 20) 0.0)))
            (if uv
                (let ((us (+ (car uv) (* v (cadr uv)))))
                  (%mem-f32-set! (+ dst 24) (%mem-f32-ref us))
                  (%mem-f32-set! (+ dst 28) (%mem-f32-ref (+ us 4))))
                (when (= stride 64)      ; skinned but uv-less: zeros
                  (%mem-f32-set! (+ dst 24) 0.0)
                  (%mem-f32-set! (+ dst 28) 0.0)))
            (when (= stride 64)          ; joints as floats + weights
              (let ((js (+ (car jn) (* v (cadr jn))))
                (u16? (= (cadddr jn) 5123))
                    (ws (+ (car wt) (* v (cadr wt)))))
                (let comp ((c 0))
                  (when (< c 4)
                    (%mem-f32-set!
                     (+ dst 32 (* 4 c))
                     (fixnum->flonum
                      (if u16?
                          ($glb-u16 (+ js (* 2 c)))
                          (%mem-u8-ref (+ js c)))))
                    (%mem-f32-set! (+ dst 48 (* 4 c))
                                   (%mem-f32-ref (+ ws (* 4 c))))
                    (comp (+ c 1)))))))
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
                     ($material-mr json (json-ref prim "material"))
                     world stride ($prim-tex-image json prim)
                     (and jn skin)
                     ;; morph targets: POSITION deltas, CPU-blended
                     (let ((tg (json-ref prim "targets")))
                       (and tg (> (vector-length tg) 0)
                            (let* ((nt (vector-length tg))
                                   (b (make-vector (* count 3) 0.0))
                                   (ds (make-vector nt #f))
                                   (w (make-vector nt 0.0)))
                              (let bv ((v 0))
                                (when (< v count)
                                  (let ((src (+ (car pos)
                                                (* v (cadr pos)))))
                                    (let c2 ((j 0))
                                      (when (< j 3)
                                        (vector-set!
                                         b (+ (* v 3) j)
                                         (%mem-f32-ref (+ src (* 4 j))))
                                        (c2 (+ j 1)))))
                                  (bv (+ v 1))))
                              (let tgt ((k 0))
                                (when (< k nt)
                                  (let* ((acc ($acc-info
                                               json bin
                                               (json-ref
                                                (vector-ref tg k)
                                                "POSITION") 12))
                                         (d (make-vector (* count 3)
                                                         0.0)))
                                    (let dv ((v 0))
                                      (when (< v count)
                                        (let ((src (+ (car acc)
                                                      (* v (cadr acc)))))
                                          (let c3 ((j 0))
                                            (when (< j 3)
                                              (vector-set!
                                               d (+ (* v 3) j)
                                               (%mem-f32-ref
                                                (+ src (* 4 j))))
                                              (c3 (+ j 1)))))
                                        (dv (+ v 1))))
                                    (vector-set! ds k d))
                                  (tgt (+ k 1))))
                              (when mw
                                (let iw ((k 0))
                                  (when (and (< k nt)
                                             (< k (vector-length mw)))
                                    (vector-set!
                                     w k ($gltf-fl (vector-ref mw k)))
                                    (iw (+ k 1)))))
                              (vector b ds w #t nidx))))
                     #f #f #f))))

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
                     (mi (json-ref node "mesh"))
                     (skin (json-ref node "skin")))
                (when mi
                  (let* ((mesh (vector-ref (json-ref json "meshes") mi))
                         (ps (json-ref mesh "primitives"))
                         (mw (json-ref mesh "weights")))
                    (let prim ((k 0))
                      (when (< k (vector-length ps))
                        (set! prims
                              (cons ($build-prim json bin
                                                 (vector-ref ps k) world
                                                 skin idx mw)
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
            ($make-gltf (reverse prims)
                        ($gltf-image-table json bin)
                        ($gltf-node-table json)
                        ($gltf-skin-table json bin)
                        ($gltf-anim-table json bin))))))

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

  ;; decode the embedded images (browser: Blob -> createImageBitmap)
  ;; and give each textured primitive its texture slot; k runs on the
  ;; gltf once every image is up
  (define (gltf-load-textures! g k)
    (js-eval "globalThis.__goeteia_img = (base, len, mime) => createImageBitmap(new Blob([new Uint8Array(globalThis.__goeteia_mem.buffer, base, len)], {type: mime}))")
    (let* ((imgs (gltf-images g))
           (n (vector-length imgs))
           (slots (make-vector (if (= n 0) 1 n) #f))
           (pending n)
           (resolve!
            (lambda ()
              (for-each (lambda (p)
                          (let ((ii ($gprim-tex-img p)))
                            (when ii
                              ($gprim-tex! p (vector-ref slots ii)))))
                        (gltf-prims g))
              (k g))))
      (if (= n 0)
          (k g)
          (let load ((i 0))
            (when (< i n)
              (let ((info (vector-ref imgs i)))
                (js-method
                 (js-call (js-get (js-global) "__goeteia_img")
                          (js-undefined)
                          (car info) (cadr info) (caddr info))
                 "then"
                 (lambda (bmp)
                   (let ((t (fx-texture!)))
                     (gl-texture-upload! t bmp)
                     (vector-set! slots i t))
                   (set! pending (- pending 1))
                   (when (= pending 0) (resolve!))
                   (js-undefined))))
              (load (+ i 1)))))))

  ;; draw every primitive; geometry uploads on its first frame.
  ;; prog is an fx-program over mesh-lit-vs/-fs (or any shader with
  ;; the same a_pos/a_normal layout and u_mvp/u_model/u_color).
  ;; An optional root matrix prefixes every node's world transform --
  ;; spin the whole asset with (m4-rotate-y t) and lighting follows.
  ;; blend base + sum(w_k * delta_k) back into the staging stream
  (define ($morph-apply! p mo)
    (let* ((b (vector-ref mo 0))
           (ds (vector-ref mo 1))
           (w (vector-ref mo 2))
           (nt (vector-length ds))
           (stride (gprim-stride p))
           (vbase (gprim-vbase p))
           (count (quotient (vector-length b) 3)))
      (let v ((i 0))
        (when (< i count)
          (let comp ((j 0))
            (when (< j 3)
              (let acc ((k 0) (s (vector-ref b (+ (* i 3) j))))
                (if (= k nt)
                    (%mem-f32-set! (+ vbase (* i stride) (* 4 j)) s)
                    (acc (+ k 1)
                         (fl+ s (fl* (vector-ref w k)
                                     (vector-ref (vector-ref ds k)
                                                 (+ (* i 3) j)))))))
              (comp (+ j 1))))
          (v (+ i 1))))
      (vector-set! mo 3 #f)))

  ;; set a primitive's morph weights by hand (a list of numbers)
  (define (gltf-weights! p ws)
    (let ((mo (gprim-morph p)))
      (unless mo
        (error 'gltf-weights! "primitive has no morph targets"))
      (let ((w (vector-ref mo 2)))
        (let loop ((k 0) (ws ws))
          (when (and (< k (vector-length w)) (pair? ws))
            (vector-set! w k ($gltf-fl (car ws)))
            (loop (+ k 1) (cdr ws)))))
      (vector-set! mo 3 #t)))

  (define (gltf-draw! g prog vp . root)
    (for-each
     (lambda (p)
       (unless (= (fx-program-stride prog) (gprim-stride p))
         (error 'gltf-draw!
                "program stride does not match the primitive (textured assets need a mesh-tex program)"
                (gprim-stride p)))
       (let ((fresh (not ($gprim-vbuf p))))
         (when fresh
           ($gprim-vbuf! p (fx-buffer!))
           ($gprim-ibuf! p (fx-buffer!)))
         (fx-use! prog ($gprim-vbuf p))
         (cmd-bind-index! ($gprim-ibuf p))
         (let ((tx (gprim-tex p)))
           (when tx
             (cmd-bind-texture! 0 tx)
             (fx-uniform! prog 'u_tex 0)))
         ;; a dirty morph rewrites the staging stream before upload
         (let ((mo (gprim-morph p)))
           (when (and mo (vector-ref mo 3))
             ($morph-apply! p mo)
             (unless fresh
               (cmd-buffer-data! (gprim-vbase p) (gprim-vbytes p)))))
         (when fresh
           (cmd-buffer-data! (gprim-vbase p) (gprim-vbytes p))
           (cmd-index-data! (gprim-ibase p) (gprim-ibytes p)))
         (let ((c (gprim-color p)))
           (if (= (gprim-stride p) 64)
               ;; skinned: the joint matrices carry the pose; the
               ;; optional root still frames the whole asset
               (begin
                 (fx-uniform! prog 'u_joints
                              (gltf-joint-matrices g ($gprim-skin p)))
                 (fx-uniform! prog 'u_mvp
                              (if (null? root) vp (m4-mul vp (car root)))))
               (let ((world (if (null? root)
                                (gprim-world p)
                                (m4-mul (car root) (gprim-world p)))))
                 (fx-uniform! prog 'u_mvp (m4-mul vp world))
                 (fx-uniform! prog 'u_model world)))
           (fx-uniform! prog 'u_color (vector-ref c 0) (vector-ref c 1)
                        (vector-ref c 2) (vector-ref c 3))
           (cmd-draw-elements! GL-TRIANGLES (gprim-icount p)))))
     (gltf-prims g))))
