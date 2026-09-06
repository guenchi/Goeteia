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
;; u8/u16/u32 indices (past 65536 vertices the stream stays 32-bit),
;; node TRS or matrix transforms accumulated through the scene
;; graph, baseColorFactor and the metallic/roughness factors,
;; embedded textures (gltf-load-textures!), skins with their joint
;; matrices, animations (sampled, blended, morph targets), and a
;; missing NORMAL becomes +y.  The interleave derives from the
;; attributes present, in one canonical order --
;;   position normal uv tangent color joints weights
;; -- so untextured primitives come out in mesh-lit-vs's 24-byte
;; layout, textured ones at 32 bytes for mesh-tex-vs, skinned ones
;; at 64 for gltf-skin-vs, and TANGENT/COLOR_0 extend the stride by
;; 16 each.  gprim-layout names the attributes present; gltf-draw!
;; matches them against the program's attribute names and refuses a
;; mismatch (an asset whose TANGENT/COLOR_0 was silently dropped
;; before now needs a shader that declares them -- compose one with
;; gltf-skin-shader or declare a_tangent/a_color yourself).
;;
;; Skinning also runs on the CPU: gltf-skin-positions! and
;; gltf-skin-normals! apply the current pose's joint palette to a
;; skinned primitive and write the result into staging as tightly
;; packed vec3 f32 -- the layout (gfx raster)'s rattr-f32 reads, so
;; a posed skinned mesh rasterizes without a GL context at all.
;;
;; A pose does not have to come from a clip.  gltf-node-translation /
;; -rotation / -scale and their -set! forms name the node table's TRS
;; slots, and writing one IS the pose: gltf-joint-palette! recomposes
;; every global from those slots on every call, so an inverse
;; kinematics solve, a motion-capture retarget or a ragdoll poses the
;; skeleton with no library code involved.  gltf-node-matrix? tells a
;; caller which nodes cannot be posed that way (the setters refuse
;; them), gltf-node-parent walks the chain.
;;
;; Clip time comes in both flavours: gltf-animate! WRAPS t into
;; [0, duration), which is what a playing clip wants and means t =
;; duration reads as the first keyframe; gltf-pose-at! CLAMPS it to
;; [0, duration], which is what scrubbing, seeking and reading a
;; clip's end pose want.
;;
;; (gltf-parse base len) works on any GLB bytes already in staging
;; memory, so parsing verifies headlessly; gltf-fetch! is the
;; browser-side loader (fetch -> one bulk copy into staging).
;;
;; Known deviations, each deliberate:
;;   * LINEAR rotation interpolates by shortest-path NLERP where the
;;     spec SHOULDs slerp.  Same great arc, different angular rate,
;;     unobservable at keyframe spacing -- and the language runtime
;;     has no inverse trigonometry to do slerp exactly.
;;     test/gltf-anim.ss locks the choice down.
;;   * A material's texture references collapse to an image index:
;;     texCoord (only TEXCOORD_0 loads), normal scale, occlusion
;;     strength and sampler identity are dropped, and there is no
;;     metallicRoughnessTexture slot -- the factors are per
;;     primitive.  Two textures over one image with different
;;     samplers therefore read as one.
;;   * Skinning transforms normals by the skin matrix itself, not by
;;     its inverse transpose, and keeps a_tangent.w regardless of
;;     determinant sign: joints with non-uniform scale or mirroring
;;     light incorrectly.
;;   * A clip poses the nodes it touches (wholesale, at bind for the
;;     paths it does not drive); nodes outside the clip keep their
;;     values, so clips over disjoint body parts compose.
;;   * A clip's loop phase is t - dur*floor(t/dur).  When dur is
;;     many orders of magnitude below the elapsed time the quotient
;;     is huge and the phase loses its significance -- a clip a
;;     microsecond long is not usefully playable minutes in.
;;   * anim-machine carries ONE transition.  Interrupting a live
;;     fade releases the clip being faded out of (its nodes return
;;     to bind) and starts the new fade from the incoming clip's own
;;     pose, so the pose jumps rather than easing from what is on
;;     screen.  Blending from the displayed pose would need the
;;     machine to hold an arbitrary number of weighted clips.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx gltf)
  (export gltf? gltf-prims gltf-images gltf-parse gltf-fetch!
          gltf-load-textures! gltf-draw!
          gltf-anims gltf-nodes gltf-skins
          gltf-node-translation gltf-node-rotation gltf-node-scale
          gltf-node-translation-set! gltf-node-rotation-set!
          gltf-node-scale-set!
          gltf-node-count gltf-node-parent gltf-node-matrix?
          gltf-animation-names gltf-animation-duration
          gltf-animate! gltf-pose-at!
          gltf-animate-blend! gltf-weights! gprim-morph
          anim-machine anim-machine? anim-state anim-goto! anim-update!
          gltf-joint-matrices gltf-joint-palette! gltf-joint-count
          gltf-skin-positions! gltf-skin-normals! gprim-vcount
          gltf-skin-vs gltf-skin-shader
          gltf-skin-vs3 gltf-skin-shader3 gltf-skin-program3!
          gltf-skin-binding gltf-skin-block-joints
          gltf-skin-uniform-joints
          gprim-vbase gprim-vbytes gprim-ibase gprim-ibytes
          gprim-icount gprim-index-u32? gprim-color
          gprim-metallic gprim-roughness
          gprim-world gltf-prim-world
          gprim-stride gprim-layout gprim-tex gprim-textured?
          gprim-normal-img gprim-emissive-img gprim-occlusion-img
          gprim-emissive gprim-ntex gprim-etex gprim-otex)
  (import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
          (gfx mesh) (web json) (gfx meshopt))

  (define ($gltf-fl v) (if (flonum? v) v (exact->inexact v)))

  (define-record-type (gltf $make-gltf gltf?)
    (fields (immutable prims gltf-prims)
            ;; per image: (abs-offset byte-length mime), in staging
            (immutable images gltf-images)
            (immutable nodes gltf-nodes)      ; runtime TRS, animatable
            (immutable skins gltf-skins)      ; #(joint-nodes ibms)
            ;; #(name channels duration touched-nodes)
            (immutable anims gltf-anims)
            ;; the pose arena: #(binds scratch marks).  binds holds
            ;; each node's immutable TRS, so a clip can be sampled as
            ;; a COMPLETE pose -- channels it does not drive fall
            ;; back to bind instead of keeping the previous clip's
            ;; value.  scratch and marks let a crossfade pose both
            ;; clips independently and then blend.
            (immutable arena $gltf-arena)
            ;; the resident joint arena, #f when there are no skins:
            ;; #(globals-base scratch-base topo-order per-skin) where
            ;; per-skin[k] = #(ibms-base palette-base njoints) -- the
            ;; whole palette composes and uploads without a boxed
            ;; matrix anywhere
            (immutable pal $gltf-pal)
            ;; the uniform buffer the big-palette draw path uploads
            ;; through, or #f until one is needed.  It cannot be
            ;; allocated at parse time: buffer slots are fx's to
            ;; hand out and fx-init! resets them, while parsing runs
            ;; wherever the caller likes
            (mutable ubo $gltf-ubo $gltf-ubo!)))

  ;; primitives are open records: custom renderers can reach the
  ;; staging offsets and draw with their own shaders
  (define-record-type ($gprim $make-gprim $gprim?)
    (fields (immutable vbase gprim-vbase)
            (immutable vbytes gprim-vbytes)
            (immutable ibase gprim-ibase)
            (immutable ibytes gprim-ibytes)
            (immutable icount gprim-icount)
            (immutable iu32 gprim-index-u32?) ; 32-bit indices?
            (immutable color gprim-color)     ; r g b a flonum vector
            (immutable mr $gprim-mr)          ; (metallic . roughness)
            (immutable world gprim-world)     ; m4, the bind pose
            (immutable node $gprim-node)      ; source node index
            (immutable stride gprim-stride)   ; total per-vertex bytes
            ;; the attributes present, in interleave order -- the
            ;; exact contract a matching shader must declare
            (immutable layout gprim-layout)
            (immutable tex-img $gprim-tex-img); image index | #f
            (immutable nrm-img gprim-normal-img)   ; image index | #f
            (immutable emi-img gprim-emissive-img) ; image index | #f
            (immutable occ-img gprim-occlusion-img); image index | #f
            (immutable emissive gprim-emissive)    ; r g b factor
            (immutable skin $gprim-skin)      ; skin index | #f
            ;; #(base-positions target-deltas weights dirty node) | #f
            (mutable morph gprim-morph $gprim-morph!)
            (mutable tex gprim-tex $gprim-tex!)  ; texture slot | #f
            (mutable ntex gprim-ntex $gprim-ntex!)
            (mutable etex gprim-etex $gprim-etex!)
            (mutable otex gprim-otex $gprim-otex!)
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

  ;; EXT_meshopt_compression: a compressed bufferView's bytes decode
  ;; once into fresh staging, and accessors read the decoded data.
  ;; $mo-bases[bvidx] = decoded staging base, or #f (uncompressed)
  (define $mo-bases (list #f))          ; boxed so parse can set it

  (define ($mo-mode m)
    (cond ((string=? m "ATTRIBUTES") 'attr)
          ((string=? m "TRIANGLES") 'tri)
          ((string=? m "INDICES") 'seq)
          (else (error 'gltf "meshopt mode" m))))

  (define ($gltf-meshopt! json bin)
    (let* ((bvs (json-ref json "bufferViews"))
           (n (if bvs (vector-length bvs) 0))
           (bases (make-vector n #f)))
      (let bv ((i 0))
        (when (< i n)
          (let ((ext (json-ref (vector-ref bvs i)
                               "extensions" "EXT_meshopt_compression")))
            (when ext
              (let* ((count (json-ref ext "count"))
                     (stride (json-ref ext "byteStride"))
                     (mode ($mo-mode (json-ref ext "mode")))
                     (filt (let ((f (json-ref ext "filter"))) (if f f "NONE")))
                     (src (+ bin ($or0 (json-ref ext "byteOffset"))))
                     (slen (json-ref ext "byteLength"))
                     (dst (fx-alloc! (* count stride))))
                (case mode
                  ((attr) (meshopt-vertex! src slen dst count stride))
                  ((tri) (meshopt-index! src slen dst count stride))
                  ((seq) (meshopt-index-sequence! src slen dst count
                                                  stride)))
                (cond
                 ((string=? filt "OCTAHEDRAL")
                  (meshopt-filter-oct! dst count stride))
                 ((string=? filt "QUATERNION")
                  (meshopt-filter-quat! dst count stride))
                 ((string=? filt "EXPONENTIAL")
                  (meshopt-filter-exp! dst count stride)))
                (vector-set! bases i dst))))
          (bv (+ i 1))))
      (set-car! $mo-bases bases)))

  ;; the staging base of bufferView bvidx: decoded when compressed
  (define ($mo-base bvidx)
    (let ((b (car $mo-bases)))
      (and b (< bvidx (vector-length b)) (vector-ref b bvidx))))

  ;; accessor index -> (abs-offset stride count comp-type)
  (define ($acc-info json bin idx tight)
    (let* ((acc (vector-ref (json-ref json "accessors") idx))
           (bvidx (json-ref acc "bufferView"))
           (bv (vector-ref (json-ref json "bufferViews") bvidx))
           (stride (let ((s (json-ref bv "byteStride")))
                     (if s s tight)))
           (mob ($mo-base bvidx)))
      (list (if mob
                (+ mob ($or0 (json-ref acc "byteOffset")))
                (+ bin ($or0 (json-ref bv "byteOffset"))
                   ($or0 (json-ref acc "byteOffset"))))
            stride
            (json-ref acc "count")
            (json-ref acc "componentType")
            (and (json-ref acc "normalized") #t))))

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

  ;; a material's root-level texture slot (normalTexture,
  ;; emissiveTexture, occlusionTexture), as an image index
  (define ($prim-mat-tex json prim key)
    (let ((mi (json-ref prim "material")))
      (and mi
           (let* ((mat (vector-ref (json-ref json "materials") mi))
                  (t (json-ref mat key)))
             (and t
                  (let ((ti (json-ref t "index")))
                    (json-ref (vector-ref (json-ref json "textures") ti)
                              "source")))))))

  ;; emissiveFactor, spec default (0,0,0)
  (define ($material-emissive json mi)
    (if (not mi)
        (vector 0.0 0.0 0.0)
        (let* ((mat (vector-ref (json-ref json "materials") mi))
               (f (json-ref mat "emissiveFactor")))
          (if f
              (vector ($gltf-fl (vector-ref f 0))
                      ($gltf-fl (vector-ref f 1))
                      ($gltf-fl (vector-ref f 2)))
              (vector 0.0 0.0 0.0)))))

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

  ;; ---- named access to one node's local transform ----
  ;; The table `gltf-nodes' hands out is raw: twelve slots per node,
  ;; 0..2 translation, 3..6 rotation as (x y z w), 7..9 scale, 10 the
  ;; matrix form or #f, 11 the parent index.  These name that layout,
  ;; so a caller posing a skeleton itself never writes a slot number
  ;; and a change to the layout is one edit, here.
  ;;
  ;; WRITING A LOCAL IS THE POSE.  gltf-joint-palette! recomposes
  ;; every node's global from exactly these slots on EVERY call, and
  ;; gltf-draw!, gltf-skin-positions! and gltf-skin-normals! all call
  ;; it, so a write shows in the very next draw: no global is cached
  ;; and there is nothing to invalidate.  What does overwrite a hand
  ;; write is a clip: gltf-animate! / gltf-pose-at! /
  ;; gltf-animate-blend! reset the nodes their clip touches to bind
  ;; and then write these same slots.  Pose by hand AFTER sampling a
  ;; clip, or on nodes no clip touches.
  ;;
  ;;   (gltf-node-rotation-set! g 5 (gltf-node-rotation g 3))
  ;;   (gltf-node-translation-set! g 5 0.0 1.5 0.0)   ; loose is equal
  ;;   (gltf-joint-palette! g 0)                      ; already current
  ;;
  ;; A node carrying the matrix form ignores its TRS slots entirely --
  ;; $node-local and the palette both read slot 10 in preference -- so
  ;; the setters REFUSE such a node by name rather than write slots
  ;; that pose nothing.  gltf-node-matrix? asks ahead of time; an
  ;; importer that wants the TRS path can decompose slot 10 itself and
  ;; clear it.
  ;;
  ;; Each of these boxes a small vector, which an inner optimizer loop
  ;; writing one lane per step may not want; gltf-nodes stays exported
  ;; and the paragraph above is the definition of what its slots mean,
  ;; so the raw path remains legitimate.  Check gltf-node-matrix? once
  ;; at load if you take it -- that check is the one the raw path
  ;; loses, and losing it poses nothing, silently.
  (define ($gltf-node who g i)
    (let ((nodes (gltf-nodes g)))
      (unless (and (fixnum? i) (>= i 0) (< i (vector-length nodes)))
        (error who "node index out of range" i))
      (vector-ref nodes i)))

  ;; how many nodes the table holds -- the bound every index above is
  ;; checked against, and the loop bound a caller walking the whole
  ;; skeleton needs without reaching for the raw table
  (define (gltf-node-count g) (vector-length (gltf-nodes g)))

  (define (gltf-node-parent g i)
    (vector-ref ($gltf-node 'gltf-node-parent g i) 11))   ; -1 at a root

  (define (gltf-node-matrix? g i)
    (if (vector-ref ($gltf-node 'gltf-node-matrix? g i) 10) #t #f))

  ;; the getters copy: what one hands back must not be a second,
  ;; unchecked way to write the slots the setters guard
  (define (gltf-node-translation g i)
    (let ((v ($gltf-node 'gltf-node-translation g i)))
      (vector (vector-ref v 0) (vector-ref v 1) (vector-ref v 2))))

  (define (gltf-node-rotation g i)
    (let ((v ($gltf-node 'gltf-node-rotation g i)))
      (vector (vector-ref v 3) (vector-ref v 4)
              (vector-ref v 5) (vector-ref v 6))))

  (define (gltf-node-scale g i)
    (let ((v ($gltf-node 'gltf-node-scale g i)))
      (vector (vector-ref v 7) (vector-ref v 8) (vector-ref v 9))))

  ;; the components loose, or one vector or list of them: a getter's
  ;; result feeds the matching setter unchanged, and so does whatever
  ;; shape the caller's own quaternion code already produces
  (define ($trs-in who n rest)
    (let ((v (if (and (pair? rest) (null? (cdr rest)))
                 (let ((a (car rest)))
                   (cond ((vector? a) a)
                         ((or (pair? a) (null? a)) (list->vector a))
                         (else (error who "not a transform" a))))
                 (list->vector rest))))
      (unless (= (vector-length v) n)
        (error who "wrong component count" (vector-length v)))
      v))

  ;; the refusal is checked before any slot is written, so a rejected
  ;; call leaves the node exactly as it found it
  (define ($trs-set! who g i base n rest)
    (let ((node ($gltf-node who g i))
          (v ($trs-in who n rest)))
      (when (vector-ref node 10)
        (error who "node carries a matrix transform, not TRS" i))
      (let cp ((j 0))
        (when (< j n)
          (vector-set! node (+ base j) ($gltf-fl (vector-ref v j)))
          (cp (+ j 1))))))

  ;; the values widen: a pose read out of JSON carries an exact 0 in
  ;; any lane that is exactly zero, and every TRS slot is flonum only
  (define (gltf-node-translation-set! g i . rest)
    ($trs-set! 'gltf-node-translation-set! g i 0 3 rest))

  ;; the quaternion is NOT renormalized here -- a caller composing
  ;; several rotations wants to normalize once, at the end, and a
  ;; silent normalize would hide a drifting product
  (define (gltf-node-rotation-set! g i . rest)
    ($trs-set! 'gltf-node-rotation-set! g i 3 4 rest))

  (define (gltf-node-scale-set! g i . rest)
    ($trs-set! 'gltf-node-scale-set! g i 7 3 rest))

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
            ;; the ceiling is the BIG palette's, not the small one's:
            ;; a skin past 32 is still loadable, it just has to draw
            ;; through the uniform-block path (gltf-skin-shader3).
            ;; Refusing it here would make the loader decide a
            ;; question that belongs to the program.
            (when (> nj gltf-skin-block-joints)
              (error 'gltf "too many joints for the skin shader"
                     nj gltf-skin-block-joints))
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
                       ;; STEP holds the left key; CUBICSPLINE stores
                       ;; in-tangent/value/out-tangent triples per key
                       (interp (let ((s (json-ref smp "interpolation")))
                                 (cond ((not s) 'linear)
                                       ((string=? s "STEP") 'step)
                                       ((string=? s "CUBICSPLINE") 'cubic)
                                       (else 'linear))))
                       (tin ($acc-info json bin (json-ref smp "input") 4))
                       (nk (caddr tin))
                       (vin ($acc-info json bin (json-ref smp "output")
                                       (case path
                                         ((rotation) 16)
                                         ((weights) 4)   ; scalars
                                         (else 12))))
                       ;; weights: the accessor holds nk * n-targets
                       ;; elements (times three under CUBICSPLINE)
                       (ncomp (case path
                                ((rotation) 4)
                                ((weights)
                                 (if (> nk 0)
                                     (quotient (caddr vin)
                                               (if (eq? interp 'cubic)
                                                   (* 3 nk)
                                                   nk))
                                     0))
                                (else 3)))
                       ;; a weights key is ncomp separate SCALAR
                       ;; elements, so both the key step and the
                       ;; component step are the accessor's stride
                       (cstride (if (eq? path 'weights) (cadr vin) 4))
                       (kstride (if (eq? path 'weights)
                                    (* ncomp (cadr vin))
                                    (cadr vin)))
                       (times (make-vector nk 0.0))
                       (vals (make-vector nk #f))
                       (intan (and (eq? interp 'cubic)
                                   (make-vector nk #f)))
                       (outtan (and (eq? interp 'cubic)
                                    (make-vector nk #f))))
                  (let kf ((i 0))
                    (when (< i nk)
                      (vector-set! times i
                                   (%mem-f32-ref (+ (car tin)
                                                    (* i (cadr tin)))))
                      ;; element e of the output stream, as ncomp f32s
                      (let ((rd (lambda (e)
                                  (let ((vat (+ (car vin) (* e kstride)))
                                        (v (make-vector ncomp 0.0)))
                                    (let comp ((j 0))
                                      (when (< j ncomp)
                                        (vector-set!
                                         v j (%mem-f32-ref
                                              (+ vat (* cstride j))))
                                        (comp (+ j 1))))
                                    v))))
                        (if (eq? interp 'cubic)
                            (begin
                              (vector-set! intan i (rd (* 3 i)))
                              (vector-set! vals i (rd (+ (* 3 i) 1)))
                              (vector-set! outtan i (rd (+ (* 3 i) 2))))
                            (vector-set! vals i (rd i))))
                      (kf (+ i 1))))
                  (when (> nk 0)
                    (let ((last (vector-ref times (- nk 1))))
                      (when (fl<? dur last) (set! dur last))))
                  (vector-set! cout c
                               ;; slot 4: the play cursor -- the last
                               ;; keyframe span this channel sampled
                               (vector (json-ref chan "target" "node")
                                       path times vals 0
                                       interp intan outtan)))
                (ch (+ c 1))))
            (vector-set! out k
                         (vector (let ((nm (json-ref a "name")))
                                   (if nm nm "anim"))
                                 cout dur
                                 ;; the nodes this clip touches
                                 (let tn ((c 0) (acc '()))
                                   (if (= c nc)
                                       acc
                                       (let ((ni (vector-ref
                                                  (vector-ref cout c)
                                                  0)))
                                         (tn (+ c 1)
                                             (if (memv ni acc)
                                                 acc
                                                 (cons ni acc)))))))))
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

  ;; cubic hermite between two keyframe values (glTF CUBICSPLINE):
  ;; m0 = the left key's out-tangent, m1 = the right key's in-tangent,
  ;; both stored per second and scaled by the keyframe span
  (define ($hermite v0 v1 m0 m1 a span)
    (let* ((t2 (fl* a a))
           (t3 (fl* t2 a))
           (h00 (fl+ (fl- (fl* 2.0 t3) (fl* 3.0 t2)) 1.0))
           (h10 (fl* span (fl+ (fl- t3 (fl* 2.0 t2)) a)))
           (h01 (fl- (fl* 3.0 t2) (fl* 2.0 t3)))
           (h11 (fl* span (fl- t3 t2)))
           (nc (vector-length v0))
           (out (make-vector nc 0.0)))
      (let j ((i 0))
        (when (< i nc)
          (vector-set! out i
                       (fl+ (fl+ (fl* h00 (vector-ref v0 i))
                                 (fl* h10 (vector-ref m0 i)))
                            (fl+ (fl* h01 (vector-ref v1 i))
                                 (fl* h11 (vector-ref m1 i)))))
          (j (+ i 1))))
      out))

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
        ;; the span: k = largest index with times[k] < tw (0 when tw
        ;; precedes the track).  Playback advances one span a frame,
        ;; so the cached cursor (or its successor) usually answers;
        ;; a wrap or scrub falls back to binary search
        (let* ((ok? (lambda (k)
                      (and (or (= k 0)
                               (fl<? (vector-ref times k) tw))
                           (or (= k (- n 1))
                               (not (fl<? (vector-ref times (+ k 1))
                                          tw))))))
               (k0 (vector-ref ch 4))
               (k (cond
                   ((ok? k0) k0)
                   ((and (< (+ k0 1) n) (ok? (+ k0 1))) (+ k0 1))
                   (else
                    (let bs ((lo 1) (hi n))
                      (if (= lo hi)
                          (- lo 1)
                          (let ((mid (quotient (+ lo hi) 2)))
                            (if (fl<? (vector-ref times mid) tw)
                                (bs (+ mid 1) hi)
                                (bs lo mid)))))))))
          (vector-set! ch 4 k)
          (begin
            (let* ((k1 (if (< (+ k 1) n) (+ k 1) k))
                     (t0 (vector-ref times k))
                     (t1 (vector-ref times k1))
                     (span (fl- t1 t0))
                     ;; a zero span holds the left key: that covers
                     ;; both the cursor sitting on the last key and a
                     ;; duplicated timestamp (a validator error, but
                     ;; a common exporter artifact -- dividing by it
                     ;; would put a NaN in the node TRS, and every
                     ;; descendant inherits it).  The test is on the
                     ;; span itself, not an epsilon, so legal
                     ;; sub-microsecond spans still interpolate.
                     (a (if (fl<? 0.0 span)
                            (fl/ (fl- tw t0) span)
                            0.0))
                     (a (if (fl<? a 0.0) 0.0 (if (fl<? 1.0 a) 1.0 a)))
                     (v0 (vector-ref vals k))
                     (v1 (vector-ref vals k1))
                     (interp (vector-ref ch 5))
                     ;; STEP holds the left key; CUBICSPLINE samples
                     ;; the hermite once, then both reduce to a = 0
                     ;; and flow through the same write paths below
                     ;; (the rotation path renormalizes either way)
                     (a (if (eq? interp 'step)
                            (if (fl<? a 1.0) 0.0 1.0)
                            a))
                     (v0 (if (and (eq? interp 'cubic) (not (= k k1)))
                             ($hermite v0 v1
                                       (vector-ref (vector-ref ch 7) k)
                                       (vector-ref (vector-ref ch 6) k1)
                                       a span)
                             v0))
                     (v1 (if (eq? interp 'cubic) v0 v1))
                     (a (if (eq? interp 'cubic) 0.0 a)))
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
                  (if (fl<? w 1.0)
                      (let ((q ($q-nlerp
                                (vector (vector-ref node 3)
                                        (vector-ref node 4)
                                        (vector-ref node 5)
                                        (vector-ref node 6))
                                ($q-nlerp v0 v1 a) w)))
                        (vector-set! node 3 (vector-ref q 0))
                        (vector-set! node 4 (vector-ref q 1))
                        (vector-set! node 5 (vector-ref q 2))
                        (vector-set! node 6 (vector-ref q 3)))
                      ;; the every-frame path: nlerp straight into
                      ;; the node fields, no quaternion boxes
                      (let* ((dot (fl+ (fl+ (fl* (vector-ref v0 0)
                                                 (vector-ref v1 0))
                                            (fl* (vector-ref v0 1)
                                                 (vector-ref v1 1)))
                                       (fl+ (fl* (vector-ref v0 2)
                                                 (vector-ref v1 2))
                                            (fl* (vector-ref v0 3)
                                                 (vector-ref v1 3)))))
                             (u (fl- 1.0 a))
                             (ts (if (fl<? dot 0.0) (fl- 0.0 a) a))
                             (x (fl+ (fl* u (vector-ref v0 0))
                                     (fl* ts (vector-ref v1 0))))
                             (y (fl+ (fl* u (vector-ref v0 1))
                                     (fl* ts (vector-ref v1 1))))
                             (z (fl+ (fl* u (vector-ref v0 2))
                                     (fl* ts (vector-ref v1 2))))
                             (qw (fl+ (fl* u (vector-ref v0 3))
                                      (fl* ts (vector-ref v1 3))))
                             (norm (flsqrt
                                    (fl+ (fl+ (fl* x x) (fl* y y))
                                         (fl+ (fl* z z)
                                              (fl* qw qw))))))
                        (vector-set! node 3 (fl/ x norm))
                        (vector-set! node 4 (fl/ y norm))
                        (vector-set! node 5 (fl/ z norm))
                        (vector-set! node 6 (fl/ qw norm)))))
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

  ;; the clip's own clock: t wrapped into [0, duration)
  (define ($anim-time anim t)
    (let ((dur (vector-ref anim 2))
          (tf ($gltf-fl t)))
      ;; only a genuinely zero duration is a constant track
      (if (fl<? 0.0 dur)
          (fl- tf (fl* dur (flfloor (fl/ tf dur))))
          0.0)))

  ;; the same clock CLAMPED instead of wrapped: [0, duration], both
  ;; ends included.  Negative t reads as 0 -- the clock's start, at
  ;; which every channel holds its own first key (a track whose first
  ;; key sits past 0 still reads that key, because $chan-sample!
  ;; clamps its interpolant before the track begins).  A clip's
  ;; duration is its LARGEST timestamp, not the span of its
  ;; timestamps, so keys at negative times are as unreachable through
  ;; this clock as they are through $anim-time's wrap: the domain is
  ;; the same either way, and only the mapping onto it differs.
  (define ($anim-time-held anim t)
    (let ((dur (vector-ref anim 2))
          (tf ($gltf-fl t)))
      (if (fl<? tf 0.0) 0.0 (if (fl<? dur tf) dur tf))))

  ;; return every channel this clip drives to its bind value, so the
  ;; sample that follows produces a COMPLETE pose: a channel the
  ;; clip lacks must read as bind, never as whatever ran before.
  ;; A node this clip touches is reset WHOLESALE, not only on the
  ;; paths the clip drives: a clip that animates rotation alone still
  ;; poses translation and scale, at bind.  (Nodes the clip does not
  ;; touch keep their values, so clips driving disjoint body parts
  ;; still compose.)
  (define ($anim-reset! g anim)
    (let ((binds (vector-ref ($gltf-arena g) 0))
          (nodes (gltf-nodes g)))
      (for-each
       (lambda (ni)
         (let ((node (vector-ref nodes ni))
               (bind (vector-ref binds ni)))
           (let cp ((j 0))
             (when (< j 10)
               (vector-set! node j (vector-ref bind j))
               (cp (+ j 1)))))
         (for-each
          (lambda (p)
            (let ((mo (gprim-morph p)))
              (when (and mo (= (vector-ref mo 4) ni))
                (let ((w (vector-ref mo 2))
                      (b (vector-ref mo 5)))
                  (let wi ((j 0))
                    (when (< j (vector-length w))
                      (vector-set! w j (vector-ref b j))
                      (wi (+ j 1)))))
                (vector-set! mo 3 #t))))
          (gltf-prims g)))
       (vector-ref anim 3))))

  ;; every channel of the clip written at ONE already-resolved clock
  ;; reading -- the wrapping and the clamping entry points differ in
  ;; nothing but which reading they hand in
  (define ($anim-sample-at! g anim tw)
    (let ((chans (vector-ref anim 1)))
      (let loop ((c 0))
        (when (< c (vector-length chans))
          ($chan-sample! g (vector-ref chans c) tw 1.0)
          (loop (+ c 1))))))

  (define ($anim-sample! g anim t)
    ($anim-sample-at! g anim ($anim-time anim t)))

  ;; run proc over the union of two clips' touched nodes, once each
  (define ($union-nodes! g a b proc)
    (let ((marks (vector-ref ($gltf-arena g) 2)))
      (for-each (lambda (i) (vector-set! marks i #f)) (vector-ref a 3))
      (for-each (lambda (i) (vector-set! marks i #f)) (vector-ref b 3))
      (for-each (lambda (i)
                  (unless (vector-ref marks i)
                    (vector-set! marks i #t)
                    (proc i)))
                (append (vector-ref a 3) (vector-ref b 3)))))

  ;; sample animation `ai` at time t: every channel this clip drives
  ;; writes its node's TRS, and every channel it does not drive
  ;; returns to the bind pose.
  ;;
  ;; t LOOPS, and that is a contract, not an implementation detail:
  ;; the clock is t - dur*floor(t/dur), so it lives in [0, dur) with
  ;; the RIGHT end open.  t = dur is therefore t = 0, the FIRST
  ;; keyframe -- not the last.  A clip that turns a joint through most
  ;; of a circle reads at its own end as if nothing had happened yet,
  ;; and a caller stepping a clip once through its length lands on the
  ;; start rather than the finish.  Negative t wraps too (floor, not
  ;; truncation, so -0.25 of a one-second clip reads 0.75).
  ;; gltf-pose-at! is the same sampling with the clock CLAMPED, which
  ;; is what a caller scrubbing, seeking or measuring an end pose
  ;; wants; this one is what a playing clip wants.
  (define (gltf-animate! g ai t)
    (let ((anim (vector-ref (gltf-anims g) ai)))
      ($anim-reset! g anim)
      ($anim-sample! g anim t)))

  ;; sample animation `ai` at time t with the clock HELD at both ends
  ;; instead of wrapped: t past the clip's duration poses its last
  ;; keyframe and stays there, negative t poses its first.  Identical
  ;; to gltf-animate! everywhere strictly inside [0, duration) -- the
  ;; same reset, the same channels, the same interpolation -- so the
  ;; two are interchangeable for a playing clip and differ exactly at
  ;; and past the end.
  ;;
  ;;   (gltf-pose-at! g ai (gltf-animation-duration g ai))  ; the END
  ;;   (gltf-animate! g ai (gltf-animation-duration g ai))  ; the START
  ;;
  ;; Use this to read a clip's final pose, to scrub a timeline, to
  ;; sample a clip at N+1 evenly spaced times inclusive of both ends,
  ;; and to hold the last frame of a one-shot instead of restarting it.
  (define (gltf-pose-at! g ai t)
    (let ((anim (vector-ref (gltf-anims g) ai)))
      ($anim-reset! g anim)
      ($anim-sample-at! g anim ($anim-time-held anim t))))

  ;; the crossfade: pose ai at ti and aj at tj INDEPENDENTLY, each
  ;; as a complete pose, then blend with weight k (0 = all ai,
  ;; 1 = all aj).  Posing them independently is what lets clips with
  ;; different channel sets crossfade correctly -- a channel absent
  ;; from one clip blends toward that clip's bind value instead of
  ;; sticking at the other's.
  (define (gltf-animate-blend! g ai ti aj tj k)
    (let* ((a (vector-ref (gltf-anims g) ai))
           (b (vector-ref (gltf-anims g) aj))
           (arena ($gltf-arena g))
           (scratch (vector-ref arena 1))
           (nodes (gltf-nodes g))
           (kf (let ((kf ($gltf-fl k)))
                 (if (fl<? kf 0.0) 0.0 (if (fl<? 1.0 kf) 1.0 kf)))))
      ;; pose A on a clean slate and stash it
      ($anim-reset! g a) ($anim-reset! g b)
      ($anim-sample! g a ti)
      ($union-nodes! g a b
                     (lambda (i)
                       (let ((node (vector-ref nodes i))
                             (s (vector-ref scratch i)))
                         (let cp ((j 0))
                           (when (< j 10)
                             (vector-set! s j (vector-ref node j))
                             (cp (+ j 1)))))))
      (let ((wa ($morph-save! g a b)))
        ;; pose B on a clean slate, then blend A back under it
        ($anim-reset! g a) ($anim-reset! g b)
        ($anim-sample! g b tj)
        ($union-nodes!
         g a b
         (lambda (i)
           (let ((node (vector-ref nodes i))
                 (s (vector-ref scratch i))
                 (u (fl- 1.0 kf)))
             ;; translation and scale lerp componentwise
             (let cp ((j 0))
               (when (< j 10)
                 (when (or (< j 3) (>= j 7))
                   (vector-set! node j
                                (fl+ (fl* u (vector-ref s j))
                                     (fl* kf (vector-ref node j)))))
                 (cp (+ j 1))))
             ;; rotation blends as a quaternion
             (let ((q ($q-nlerp
                       (vector (vector-ref s 3) (vector-ref s 4)
                               (vector-ref s 5) (vector-ref s 6))
                       (vector (vector-ref node 3) (vector-ref node 4)
                               (vector-ref node 5) (vector-ref node 6))
                       kf)))
               (vector-set! node 3 (vector-ref q 0))
               (vector-set! node 4 (vector-ref q 1))
               (vector-set! node 5 (vector-ref q 2))
               (vector-set! node 6 (vector-ref q 3))))))
        ($morph-blend! g wa kf))))

  ;; morph weights ride the same two-pose scheme: snapshot A's
  ;; weights per primitive, then lerp them back under B's
  (define ($morph-save! g a b)
    (map (lambda (p)
           (let ((mo (gprim-morph p)))
             (and mo
                  (let* ((w (vector-ref mo 2))
                         (n (vector-length w))
                         (s (make-vector n 0.0)))
                    (let cp ((j 0))
                      (when (< j n)
                        (vector-set! s j (vector-ref w j))
                        (cp (+ j 1))))
                    (cons p s)))))
         (gltf-prims g)))

  (define ($morph-blend! g saved kf)
    (for-each
     (lambda (e)
       (when e
         (let* ((p (car e)) (s (cdr e))
                (mo (gprim-morph p))
                (w (vector-ref mo 2))
                (u (fl- 1.0 kf)))
           (let cp ((j 0))
             (when (< j (vector-length w))
               (vector-set! w j (fl+ (fl* u (vector-ref s j))
                                     (fl* kf (vector-ref w j))))
               (cp (+ j 1))))
           (vector-set! mo 3 #t))))
     saved))

  (define (gltf-animation-names g)
    (let ((as (gltf-anims g)))
      (let loop ((k (- (vector-length as) 1)) (acc '()))
        (if (< k 0)
            acc
            (loop (- k 1) (cons (vector-ref (vector-ref as k) 0) acc))))))

  ;; clip `ai`'s length in seconds -- the largest timestamp over its
  ;; channels, the period gltf-animate! wraps its clock into.  A
  ;; clip whose keyframes all sit at t = 0 measures 0.0 -- that is
  ;; the constant pose gltf-animate! reads as one, so a caller
  ;; dividing by this has to say what it means by zero length
  (define (gltf-animation-duration g ai)
    (vector-ref (vector-ref (gltf-anims g) ai) 2))

  ;; ---- the animation state machine ----
  ;; The pattern every animated character repeats, packaged: named
  ;; states over clip indices, transitions that crossfade over a
  ;; fade time, and clip clocks that keep running under the fade so
  ;; feet do not freeze mid-stride.
  ;;
  ;;   (define m (anim-machine g '((walk . 1) (survey . 0) (run . 2))
  ;;                           0.3))          ; starts in the first state
  ;;   (anim-goto! m 'run)                    ; crossfade over 0.3s
  ;;   (anim-goto! m 'walk 0.1)               ; ... or this one's own fade
  ;;   (anim-update! m dt)                    ; each frame: clocks + pose
  ;;   (anim-state m)                         ; -> the current name
  (define-record-type ($anim-machine $am-make anim-machine?)
    (fields (immutable g $am-g)
            (immutable states $am-states)     ; ((name . clip) ...)
            (immutable fade $am-fade)         ; default seconds
            (mutable cur $am-cur $am-cur!)
            (mutable prev $am-prev $am-prev!) ; #f when settled
            (mutable tcur $am-tcur $am-tcur!)
            (mutable tprev $am-tprev $am-tprev!)
            (mutable k $am-k $am-k!)          ; fade seconds elapsed
            (mutable len $am-len $am-len!)))  ; this transition's fade

  (define (anim-machine g states . fade)
    ($am-make g states
              (if (pair? fade) ($gltf-fl (car fade)) 0.25)
              (car (car states)) #f 0.0 0.0 0.0 0.0))

  (define (anim-state m) ($am-cur m))

  ;; Interrupting a live transition drops the clip it was fading
  ;; out of; release that clip's nodes here, or nothing ever touches
  ;; them again and they hold the last blended value for the rest of
  ;; the run.  (The pose does jump: the machine carries one
  ;; transition, so the new fade starts from the incoming clip's own
  ;; pose rather than from what is on screen.)
  (define (anim-goto! m name . fade)
    (unless (assq name ($am-states m))
      (error 'anim-goto! "unknown state" name))
    (unless (eq? name ($am-cur m))
      (when ($am-prev m)
        ($anim-reset! ($am-g m)
                      (vector-ref (gltf-anims ($am-g m))
                                  (cdr (assq ($am-prev m)
                                             ($am-states m))))))
      ($am-prev! m ($am-cur m))
      ($am-tprev! m ($am-tcur m))
      ($am-cur! m name)
      ($am-tcur! m 0.0)
      ($am-k! m 0.0)
      ($am-len! m (if (pair? fade) ($gltf-fl (car fade)) ($am-fade m)))))

  (define (anim-update! m dt)
    (let* ((dt ($gltf-fl dt))
           (g ($am-g m))
           (ci (cdr (assq ($am-cur m) ($am-states m)))))
      ($am-tcur! m (fl+ ($am-tcur m) dt))
      ;; the transition is live whenever prev is set: an instant
      ;; (or negative) fade must still reach the completion branch,
      ;; which is the only place the outgoing clip is released
      (if ($am-prev m)
          (begin
            ($am-tprev! m (fl+ ($am-tprev m) dt))
            ($am-k! m (fl+ ($am-k m) dt))
            ;; only a zero or negative fade settles at once; any
            ;; positive length interpolates, however short
            (let ((w (if (fl<? 0.0 ($am-len m))
                         (fl/ ($am-k m) ($am-len m))
                         1.0))
                  (pi (cdr (assq ($am-prev m) ($am-states m)))))
              (if (fl<? w 1.0)
                  (gltf-animate-blend! g pi ($am-tprev m) ci ($am-tcur m) w)
                  ;; the fade is over: the outgoing clip's nodes go
                  ;; back to bind before the incoming clip poses, or
                  ;; a node only IT drove keeps the last blended
                  ;; value for the rest of the run
                  (begin ($am-prev! m #f)
                         ($anim-reset! g (vector-ref (gltf-anims g) pi))
                         (gltf-animate! g ci ($am-tcur m))))))
          (gltf-animate! g ci ($am-tcur m)))))

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

  ;; ---- the resident palette: the same matrices, zero boxes ----
  ;; built at parse time when the asset has skins: staging room for
  ;; every node's global matrix, a local-matrix scratch, the
  ;; inverse-bind matrices (written once), and each skin's palette;
  ;; plus a topological order so globals fill parents-first with no
  ;; recursion.  The last 80 bytes are the CPU skinning kernel's
  ;; scratch (one blended matrix plus one vec4), allocated here so
  ;; it shares the asset's lifetime -- a lazily grabbed static would
  ;; outlive an fx-release! and hand the kernel somebody else's
  ;; bytes.
  (define ($gltf-pal-arena nodes skins)
    (and (> (vector-length skins) 0)
         (let* ((nn (vector-length nodes))
                (globals (fx-alloc! (* nn 64)))
                (scratch (fx-alloc! 64))
                (cpu (fx-alloc! 80))
                (order (make-vector nn 0))
                (done (make-vector nn #f)))
           ;; parents before children; roots (parent -1) lead
           (let fill ((emitted 0))
             (when (< emitted nn)
               (let scan ((i 0) (now emitted))
                 (if (= i nn)
                     (if (= now emitted)
                         (error 'gltf "node parent cycle")
                         (fill now))
                     (let ((p (vector-ref (vector-ref nodes i) 11)))
                       (if (and (not (vector-ref done i))
                                (or (< p 0) (vector-ref done p)))
                           (begin (vector-set! order now i)
                                  (vector-set! done i #t)
                                  (scan (+ i 1) (+ now 1)))
                           (scan (+ i 1) now)))))))
           (vector
            globals scratch order
            (let ((per (make-vector (vector-length skins) #f)))
              (let skin ((k 0))
                (when (< k (vector-length skins))
                  (let* ((joints (vector-ref (vector-ref skins k) 0))
                         (ibms (vector-ref (vector-ref skins k) 1))
                         (n (vector-length joints))
                         (ib (fx-alloc! (* n 64)))
                         (pb (fx-alloc! (* n 64))))
                    (let put ((i 0))    ; inverse binds ship once
                      (when (< i n)
                        (m4s-write! (+ ib (* i 64)) (vector-ref ibms i))
                        (put (+ i 1))))
                    (vector-set! per k (vector ib pb n)))
                  (skin (+ k 1))))
              per)
            cpu))))

  (define (gltf-joint-count g si)
    (vector-length (vector-ref (vector-ref (gltf-skins g) si) 0)))

  ;; refresh every node's global matrix (locals in closed form from
  ;; the animated TRS fields, chains in SIMD, parents first), then
  ;; compose one skin's palette: palette[k] = global(joint k) x ibm.
  ;; Returns the palette's staging address --
  ;;   (fx-uniform! p 'u_joints (gltf-joint-palette! g 0)
  ;;                            (gltf-joint-count g 0))
  ;; uploads the whole skeleton in three command words
  (define (gltf-joint-palette! g si)
    (let* ((pal ($gltf-pal g))
           (nodes (gltf-nodes g))
           (nn (vector-length nodes))
           (globals (vector-ref pal 0))
           (scratch (vector-ref pal 1))
           (order (vector-ref pal 2)))
      (let each ((j 0))
        (when (< j nn)
          (let* ((i (vector-ref order j))
                 (v (vector-ref nodes i))
                 (p (vector-ref v 11))
                 (dst (+ globals (* i 64)))
                 (mx (vector-ref v 10)))
            (if (< p 0)
                (if mx
                    (m4s-write! dst mx)
                    (m4s-tqs! dst (vector-ref v 0) (vector-ref v 1)
                              (vector-ref v 2) (vector-ref v 3)
                              (vector-ref v 4) (vector-ref v 5)
                              (vector-ref v 6) (vector-ref v 7)
                              (vector-ref v 8) (vector-ref v 9)))
                (begin
                  (if mx
                      (m4s-write! scratch mx)
                      (m4s-tqs! scratch (vector-ref v 0) (vector-ref v 1)
                                (vector-ref v 2) (vector-ref v 3)
                                (vector-ref v 4) (vector-ref v 5)
                                (vector-ref v 6) (vector-ref v 7)
                                (vector-ref v 8) (vector-ref v 9)))
                  (m4s-mul! dst (+ globals (* p 64)) scratch))))
          (each (+ j 1))))
      (let* ((per (vector-ref (vector-ref pal 3) si))
             (ib (vector-ref per 0))
             (pb (vector-ref per 1))
             (n (vector-ref per 2))
             (joints (vector-ref (vector-ref (gltf-skins g) si) 0)))
        (let comp ((k 0))
          (when (< k n)
            (m4s-mul! (+ pb (* k 64))
                      (+ globals (* (vector-ref joints k) 64))
                      (+ ib (* k 64)))
            (comp (+ k 1))))
        pb)))

  ;; ---- CPU skinning: the same pose, with no GL context ----
  ;; The palette poses vertices on the GPU, inside the vertex
  ;; shader, so the posed geometry never exists on this side.  A
  ;; caller that needs the geometry ITSELF -- the software
  ;; rasterizer, a silhouette fit, a collision proxy, a screenshot
  ;; oracle -- has to run the same blend here.  These two write the
  ;; result into staging as tightly packed vec3 f32, which is
  ;; exactly what (gfx raster)'s rattr-f32 reads:
  ;;
  ;;   (define dst (fx-alloc! (* 12 (gprim-vcount p))))
  ;;   (gltf-animate! g 0 t)
  ;;   (gltf-skin-positions! g p dst)
  ;;   (rattr-f32 dst 12 0 (gprim-vcount p) 3)
  ;;
  ;; The blend is the shader's, matrix first:
  ;;   S = w.x*P[j.x] + w.y*P[j.y] + w.z*P[j.z] + w.w*P[j.w]
  ;;   position = S * (pos, 1)     normal = normalize(S * (nrm, 0))
  ;; -- ONE matrix built per vertex and then applied, not four
  ;; transforms summed.  The two agree in exact arithmetic, but the
  ;; first is what gltf-skin-vs computes, and it runs here through
  ;; the same f32 lane kernels in the same order, so the CPU pose is
  ;; the GPU pose rather than something merely near it.
  ;;
  ;; Weights ride through exactly as the stream carries them.  glTF
  ;; requires them to sum to one and the shader does not
  ;; renormalize; renormalizing here would put the two paths on
  ;; different geometry for precisely the assets where it mattered.
  ;;
  ;; Normals get the blended matrix, not its inverse transpose --
  ;; the same deliberate deviation the shader makes, for the same
  ;; reason, so a non-uniformly scaled joint is wrong identically on
  ;; both sides instead of wrong in two different ways.

  ;; how many vertices a primitive's interleave carries.  Callers
  ;; size their own destination with it, so it is part of the API
  ;; rather than a derivation each of them repeats.
  (define (gprim-vcount p)
    (quotient (gprim-vbytes p) (gprim-stride p)))

  ;; one influence's palette matrix address.  An index outside the
  ;; skin is a broken asset: reading it would silently blend some
  ;; other allocation's bytes into the pose, so it is named here.
  (define ($skin-pal-at pb nj s jo c who)
    (let ((j (%fl->fx (%mem-f32-ref (+ s jo (* 4 c))))))
      (when (or (< j 0) (>= j nj))
        (error who "joint index outside the skin's palette" j nj))
      (+ pb (* j 64))))

  ;; the shared kernel.  `src' names the interleaved attribute to
  ;; transform, `point?' says whether the homogeneous coordinate is
  ;; 1 (a position, translation applies) or 0 (a direction), and
  ;; `unit?' asks for the result to come back renormalized.
  (define ($skin-blend! g p dst who src point? unit?)
    (let ((si ($gprim-skin p)))
      (unless si
        (error who "primitive is not skinned" (gprim-layout p)))
      (let* ((layout (gprim-layout p))
             (so ($layout-offset layout src))
             (jo ($layout-offset layout 'joints))
             (wo ($layout-offset layout 'weights)))
        ;; before the palette composes, not after: a layout that
        ;; cannot be blended is the caller's mistake to hear about
        (unless (and so jo wo)
          (error who "primitive layout carries no such attribute"
                 src layout))
        (let* ((stride (gprim-stride p))
               (count (gprim-vcount p))
               (vbase (gprim-vbase p))
               (nj (gltf-joint-count g si))
               ;; the CURRENT animation state's palette, refreshed
               ;; here -- posing is what the caller asked for.  Both
               ;; entry points refresh, so a caller wanting positions
               ;; AND normals from one pose pays for the skeleton
               ;; twice; the skeleton is joints, the mesh is
               ;; thousands of vertices, and keeping them independent
               ;; is worth that.
               (pb (gltf-joint-palette! g si))
               (sk (vector-ref ($gltf-pal g) 4))
               (rv (+ sk 64)))
          (let vert ((v 0) (s vbase) (d dst))
            (when (< v count)
              ;; S, one column of four lanes at a time
              (let ((a0 ($skin-pal-at pb nj s jo 0 who))
                    (a1 ($skin-pal-at pb nj s jo 1 who))
                    (a2 ($skin-pal-at pb nj s jo 2 who))
                    (a3 ($skin-pal-at pb nj s jo 3 who))
                    (w0 (%mem-f32-ref (+ s wo)))
                    (w1 (%mem-f32-ref (+ s wo 4)))
                    (w2 (%mem-f32-ref (+ s wo 8)))
                    (w3 (%mem-f32-ref (+ s wo 12))))
                (let col ((c 0))
                  (when (< c 4)
                    (let ((o (* c 16)))
                      (%f32x4-scale! (+ sk o) (+ a0 o) w0)
                      (%f32x4-axpy! (+ sk o) (+ sk o) (+ a1 o) w1)
                      (%f32x4-axpy! (+ sk o) (+ sk o) (+ a2 o) w2)
                      (%f32x4-axpy! (+ sk o) (+ sk o) (+ a3 o) w3))
                    (col (+ c 1)))))
              ;; S * (attr, 1) for a point, S * (attr, 0) for a
              ;; direction -- still in lanes
              (let ((x (%mem-f32-ref (+ s so)))
                    (y (%mem-f32-ref (+ s so 4)))
                    (z (%mem-f32-ref (+ s so 8))))
                (%f32x4-scale! rv sk x)
                (%f32x4-axpy! rv rv (+ sk 16) y)
                (%f32x4-axpy! rv rv (+ sk 32) z)
                (when point?
                  (%f32x4-axpy! rv rv (+ sk 48) 1.0)))
              (let ((ox (%mem-f32-ref rv))
                    (oy (%mem-f32-ref (+ rv 4)))
                    (oz (%mem-f32-ref (+ rv 8))))
                (if unit?
                    ;; a degenerate result (every influence weighted
                    ;; zero, or a collapsed joint) has no direction
                    ;; to report -- it goes out as it came rather
                    ;; than becoming a division by zero
                    (let ((n (flsqrt (fl+ (fl+ (fl* ox ox) (fl* oy oy))
                                          (fl* oz oz)))))
                      (if (fl<? 0.0 n)
                          (begin
                            (%mem-f32-set! d (fl/ ox n))
                            (%mem-f32-set! (+ d 4) (fl/ oy n))
                            (%mem-f32-set! (+ d 8) (fl/ oz n)))
                          (begin
                            (%mem-f32-set! d ox)
                            (%mem-f32-set! (+ d 4) oy)
                            (%mem-f32-set! (+ d 8) oz))))
                    (begin
                      (%mem-f32-set! d ox)
                      (%mem-f32-set! (+ d 4) oy)
                      (%mem-f32-set! (+ d 8) oz))))
              (vert (+ v 1) (+ s stride) (+ d 12))))
          count))))

  ;; pose one skinned primitive's positions into `dst' (12 bytes a
  ;; vertex, tightly packed); returns the vertex count
  (define (gltf-skin-positions! g p dst)
    ($skin-blend! g p dst 'gltf-skin-positions! 'position #t #f))

  ;; the same for normals, renormalized.  A separate pass by design:
  ;; a silhouette fit wants positions alone and should not pay for
  ;; normals it throws away.
  (define (gltf-skin-normals! g p dst)
    ($skin-blend! g p dst 'gltf-skin-normals! 'normal #f #t))

  ;; the skinning vertex shader: 4 joints x 4 weights per vertex,
  ;; pair with mesh-tex-fs (or mesh-lit-fs won't match the varyings)
  ;; The built-in skinned program is DERIVED, not hand written: it is
  ;; exactly mesh-tex-vs run through the combinator below.  The two
  ;; used to be separate, and the copy drifted -- it never declared
  ;; u_model, so gltf-draw!'s optional root rotated the geometry
  ;; while the normals stayed put.  Defined after gltf-skin-shader
  ;; because it calls it.
  (define gltf-skin-vs #f)
  ;; its big-palette twin, from the same combinator family
  (define gltf-skin-vs3 #f)

  ;; ---- the two palette carriers ----
  ;; A skin's matrices reach the vertex shader one of two ways, and
  ;; the choice is the PROGRAM's, not the asset's:
  ;;
  ;;   uniform mat4 u_joints[32]   -- ESSL 1.00, no extensions, the
  ;;                                  original path, unchanged
  ;;   layout(std140) uniform Skin { mat4 u_joints[256]; }
  ;;                               -- ESSL 3.00 + WebGL 2, the size
  ;;                                  a humanoid rig with fingers
  ;;                                  and a face actually needs
  ;;
  ;; 256 is what a conforming WebGL 2 context guarantees:
  ;; MAX_UNIFORM_BLOCK_SIZE is at least 16384 bytes and std140 gives
  ;; a mat4 array a 64-byte stride, so 16384 / 64 = 256 matrices fit
  ;; with nothing to spare.  The stride being exactly 64 is why the
  ;; resident palette uploads with no repacking: the block's memory
  ;; image IS the run of matrices gltf-joint-palette! composed.
  (define gltf-skin-uniform-joints 32)  ; the ESSL 1.00 array's size
  (define gltf-skin-block-joints 256)   ; the std140 block's size
  ;; the binding point the Skin block wants.  0 belongs to the frame
  ;; globals block (gfx scene) so that a skinned program can carry
  ;; both without either party knowing about the other
  (define gltf-skin-binding 1)
  (define $gltf-skin-block-name 'Skin)
  (define $gltf-skin-block
    (list 'uniform-block $gltf-skin-block-name
          (list (list 'array 'mat4 gltf-skin-block-joints) 'u_joints)))
  (define $gltf-skin-uniform
    (list 'uniform (list 'array 'mat4 gltf-skin-uniform-joints)
          'u_joints))

  ;; ---- the skin combinator: any static vertex shader, skinned ----
  ;; Skinning is one orthogonal dimension, not a family of
  ;; hand-written variants: (gltf-skin-shader vs) appends
  ;; a_joints/a_weights AFTER the static attributes -- exactly where
  ;; the loader's canonical interleave puts them -- adds the u_joints
  ;; palette, and rewrites every reference to a_pos / a_normal /
  ;; a_tangent (swizzles included) inside the shader's defines to
  ;; read the skin-transformed locals.  Varyings and uniforms are
  ;; untouched, so the result pairs with the same fragment shader
  ;; the static program used: (fx-program! (gltf-skin-shader
  ;; mesh-normal-vs) mesh-normal-fs) is the normal-mapped skinned
  ;; program.  The names g_skin/g_pos/g_normal/g_tangent are
  ;; reserved in the input.

  (define ($sym-prefix? s pre)          ; s = pre, or pre.swizzle
    (let* ((ss (symbol->string s)) (ps (symbol->string pre))
           (sl (string-length ss)) (pl (string-length ps)))
      (and (>= sl pl)
           (string=? (substring ss 0 pl) ps)
           (or (= sl pl) (char=? (string-ref ss pl) #\.)))))

  (define ($sym-swap s from to)         ; new prefix, same swizzle
    (let ((ss (symbol->string s)) (ps (symbol->string from)))
      (string->symbol
       (string-append (symbol->string to)
                      (substring ss (string-length ps)
                                 (string-length ss))))))

  (define ($skin-subst form pairs)
    (cond
     ((symbol? form)
      (let loop ((ps pairs))
        (cond ((null? ps) form)
              (($sym-prefix? form (caar ps))
               ($sym-swap form (caar ps) (cdar ps)))
              (else (loop (cdr ps))))))
     ((pair? form)
      (cons ($skin-subst (car form) pairs)
            ($skin-subst (cdr form) pairs)))
     (else form)))

  ;; does the form reference any of the rewritten attributes?
  (define ($skin-refs? form pairs)
    (cond
     ((symbol? form)
      (let loop ((ps pairs))
        (cond ((null? ps) #f)
              (($sym-prefix? form (caar ps)) #t)
              (else (loop (cdr ps))))))
     ((pair? form)
      (or ($skin-refs? (car form) pairs)
          ($skin-refs? (cdr form) pairs)))
     (else #f)))

  ;; Both variants are ONE combinator: they differ only in the form
  ;; that declares the palette (and, for the block flavour, in the
  ;; block name it additionally reserves).  Everything else -- the
  ;; attribute padding, the interleave-order check, the rewrite of
  ;; a_pos/a_normal/a_tangent, every diagnostic -- is shared, so the
  ;; small and large paths cannot drift apart the way the
  ;; hand-written skin shader once drifted from its combinator.
  (define (gltf-skin-shader vs)
    ($skin-shader vs $gltf-skin-uniform #f))

  ;; the big-palette flavour: up to 256 joints out of a std140
  ;; uniform block.  ESSL 3.00 only -- render it with fx-program3!
  ;; (fx-program! rejects a uniform-block form outright), and wire
  ;; the block to gltf-skin-binding, which gltf-skin-program3! does
  ;; for you.  The ACCESS syntax is identical, so a shader body
  ;; written against either reads the same.
  (define (gltf-skin-shader3 vs)
    ($skin-shader vs $gltf-skin-block $gltf-skin-block-name))

  ;; the whole big-palette program in one call: skin the vertex
  ;; shader, build it as ESSL 3.00, and wire the Skin block to its
  ;; binding point.  Doing the wiring here is what keeps the binding
  ;; number out of the caller's hands -- gltf-draw! binds the same
  ;; one, and neither has to trust the other to remember it.
  (define (gltf-skin-program3! vs-forms fs-forms)
    (let ((p (fx-program3! (gltf-skin-shader3 vs-forms) fs-forms)))
      (gl-uniform-block! (fx-program-slot p)
                         (symbol->string $gltf-skin-block-name)
                         gltf-skin-binding)
      p))

  (define ($skin-shader vs palette block-name)
    (let* ((names (map car (glsl-attributes vs)))
           (has? (lambda (n) (and (memq n names) #t)))
           (subst
            (append '((a_pos . g_pos))
                    (if (has? 'a_normal) '((a_normal . g_normal)) '())
                    (if (has? 'a_tangent)
                        '((a_tangent . g_tangent))
                        '())))
           (locals
            (append
             (list '(local mat4 g_skin
                           (+ (* a_weights.x
                                 (at u_joints (int a_joints.x)))
                              (* a_weights.y
                                 (at u_joints (int a_joints.y)))
                              (* a_weights.z
                                 (at u_joints (int a_joints.z)))
                              (* a_weights.w
                                 (at u_joints (int a_joints.w)))))
                   '(local vec3 g_pos
                           (vec3 (* g_skin (vec4 a_pos (fl 1))))))
             (if (has? 'a_normal)
                 (list '(local vec3 g_normal
                               (vec3 (* g_skin
                                        (vec4 a_normal (fl 0))))))
                 '())
             (if (has? 'a_tangent)
                 (list '(local vec4 g_tangent
                               (vec4 (vec3 (* g_skin
                                              (vec4 a_tangent.xyz
                                                    (fl 0))))
                                     a_tangent.w)))
                 '()))))
      (unless (memq 'a_pos names)
        (error 'gltf-skin-shader
               "vertex shader declares no a_pos attribute" names))
      ;; block names live in their own namespace, so this is a
      ;; separate check from the variable one below -- but a second
      ;; block called Skin is just as fatal, and only the block
      ;; flavour injects one
      (when block-name
        (for-each
         (lambda (b)
           (when (eq? (car b) block-name)
             (error 'gltf-skin-shader
                    "input already declares the injected uniform block"
                    block-name)))
         (glsl-uniform-blocks vs)))
      ;; every name this injects must be free in the input.  GLSL
      ;; shares one top-level namespace across storage classes, so
      ;; check attributes, uniforms and varyings together -- a
      ;; uniform named a_uv blocks the attribute just as an
      ;; attribute named u_joints blocks the uniform.
      (let ((taken (append names
                           (map car (glsl-uniforms vs))
                           (glsl-varyings vs)
                           ;; function names share the namespace, and
                           ;; so do the members of an anonymous
                           ;; uniform block -- they land in global
                           ;; scope exactly like a plain uniform
                           (let fn ((fs vs) (acc '()))
                             (cond
                              ((null? fs) acc)
                              ((not (pair? (car fs))) (fn (cdr fs) acc))
                              ((and (eq? (caar fs) 'define)
                                    (pair? (cadr (car fs))))
                               (fn (cdr fs)
                                   (cons (car (cadr (car fs))) acc)))
                              ((eq? (caar fs) 'uniform-block)
                               (fn (cdr fs)
                                   (append (map cadr (cddr (car fs)))
                                           acc)))
                              (else (fn (cdr fs) acc)))))))
        (for-each
         (lambda (n)
           (when (memq n taken)
             (error 'gltf-skin-shader
                    "input already declares an injected name" n)))
         (append '(a_joints a_weights u_joints)
                 ;; the padding slots, only where they get injected
                 (if (memq 'a_normal names) '() '(a_normal))
                 (if (memq 'a_uv names) '() '(a_uv)))))
      ;; The loader's interleave is a fixed order, so a shader that
      ;; declares the recognized attributes in another one can never
      ;; match a primitive.  Say so here rather than handing back a
      ;; program that only fails when something tries to draw.
      (let* ((canon '(a_pos a_normal a_uv a_tangent a_color
                      a_joints a_weights))
             ;; attributes outside the canonical set are the
             ;; caller's own -- a program fed from somewhere else
             ;; may legitimately carry them -- so this checks the
             ;; RELATIVE order of the ones the loader fills and
             ;; leaves the rest to gltf-draw!'s name check
             (known (let keep ((ns names) (acc '()))
                      (cond ((null? ns) (reverse acc))
                            ((memq (car ns) canon)
                             (keep (cdr ns) (cons (car ns) acc)))
                            (else (keep (cdr ns) acc)))))
             (want (let keep ((cs canon) (acc '()))
                     (cond ((null? cs) (reverse acc))
                           ((memq (car cs) known)
                            (keep (cdr cs) (cons (car cs) acc)))
                           (else (keep (cdr cs) acc))))))
        (unless (equal? known want)
          (error 'gltf-skin-shader
                 "attributes are not in the loader's interleave order"
                 known want)))
      ;; the g_* locals go into main's body, so they must be free
      ;; anywhere in the input -- a local of the same name would be
      ;; a redeclaration in the same scope
      (when ($skin-refs? vs '((g_skin . g_skin) (g_pos . g_pos)
                              (g_normal . g_normal)
                              (g_tangent . g_tangent)))
        (error 'gltf-skin-shader
               "input uses a name reserved for the skin locals (g_*)"))
      ;; the LAST attribute form, wherever it sits -- declarations
      ;; need not be contiguous -- and the position the uv padding
      ;; belongs at: the interleave puts uv right after normal, so
      ;; appending it at the end would misplace it for a shader that
      ;; declares tangent or color
      (let* ((attr-at
              (lambda (name)
                (let scan ((fs vs) (i 0) (found -1))
                  (if (null? fs)
                      found
                      (scan (cdr fs) (+ i 1)
                            (if (and (pair? (car fs))
                                     (eq? (caar fs) 'attribute)
                                     (eq? (caddr (car fs)) name))
                                i
                                found))))))
             ;; the last attribute BEFORE main: the injected globals
             ;; go there, because main's body references them and
             ;; GLSL wants a declaration first.  Helper functions
             ;; may sit anywhere -- only main bounds the insertion.
             (main-at
              (let scan ((fs vs) (i 0))
                (cond ((null? fs) i)
                      ((and (pair? (car fs))
                            (eq? (caar fs) 'define)
                            (equal? (cadr (car fs)) '(main)))
                       i)
                      (else (scan (cdr fs) (+ i 1))))))
             (last-attr
              (let scan ((fs vs) (i 0) (last -1))
                (if (null? fs)
                    last
                    (scan (cdr fs) (+ i 1)
                          (if (and (pair? (car fs))
                                   (eq? (caar fs) 'attribute)
                                   (< i main-at))
                              i
                              last)))))
             ;; the canonical prefix is position normal uv; whatever
             ;; of it the input omits gets padded in, right after
             ;; the last piece it does declare
             (pad-after (let ((n (attr-at 'a_normal)))
                          (if (< n 0) (attr-at 'a_pos) n))))
        ;; A CANONICAL attribute has to precede main: main's injected
        ;; body reads a_pos/a_normal/a_tangent, and the padding lands
        ;; beside whichever of them the input declares -- so one
        ;; declared after main puts a declaration below its use.  An
        ;; attribute of the caller's own is fed from elsewhere and
        ;; read by nothing this injects, so where it sits is the
        ;; caller's business.  (Helper functions may sit anywhere.)
        (let scan ((fs vs) (i 0))
          (cond ((null? fs) #t)
                ((and (pair? (car fs))
                      (eq? (caar fs) 'attribute)
                      (memq (caddr (car fs))
                            '(a_pos a_normal a_uv a_tangent a_color
                              a_joints a_weights))
                      (> i main-at))
                 (error 'gltf-skin-shader
                        "attribute declared after main"
                        (caddr (car fs))))
                (else (scan (cdr fs) (+ i 1)))))
        ;; The loader's interleave fixes each canonical attribute's
        ;; width -- COLOR_0 always occupies 16 bytes even when the
        ;; accessor was VEC3 (alpha fills with 1).  A shader
        ;; declaring vec3 a_color computes a stride 4 bytes short and
        ;; misreads every vertex past the first, and comparing names
        ;; alone would never catch it.
        (let ((want '((a_pos . vec3) (a_normal . vec3) (a_uv . vec2)
                      (a_tangent . vec4) (a_color . vec4)
                      (a_joints . vec4) (a_weights . vec4))))
          (for-each
           (lambda (a)
             (let ((spec (assq (car a) want)))
               (when (and spec (not (eq? (cadr a) (cdr spec))))
                 (error 'gltf-skin-shader
                        "attribute has the wrong width for the interleave"
                        (car a) (cadr a) (cdr spec)))))
           (glsl-attributes vs)))
        (when (< last-attr 0)
          (error 'gltf-skin-shader
                 "attributes must be declared before main"))
        (let loop ((fs vs) (i 0) (out '()))
          (if (null? fs)
              (reverse out)
              (let* ((f (car fs))
                     (out
                      (cond
                       ((and (pair? f) (eq? (car f) 'define))
                        (if (equal? (cadr f) '(main))
                            ;; main: the locals, then the rewritten
                            ;; body
                            (cons (append (list 'define (cadr f)
                                                (caddr f))
                                          locals
                                          ($skin-subst (cdddr f)
                                                       subst))
                                  out)
                            ;; a helper cannot see main's g_*
                            ;; locals: refuse a rewrite that would
                            ;; miscompile
                            (begin
                              (when ($skin-refs? (cdddr f) subst)
                                (error 'gltf-skin-shader
                                       "attribute referenced outside main; pass the skinned value as a parameter"
                                       (cadr f)))
                              (cons f out))))
                       (else (cons f out))))
                     ;; the loader writes a +y normal even for an
                     ;; asset with none, and carries a uv slot once
                     ;; anything past position+normal is present --
                     ;; and the skin inputs are exactly that.  So a
                     ;; shader missing either gets the padding, in
                     ;; the interleave's order.
                     (out (if (= i pad-after)
                              (let* ((o out)
                                     (o (if (memq 'a_normal names)
                                            o
                                            (cons '(attribute vec3
                                                              a_normal)
                                                  o)))
                                     (o (if (memq 'a_uv names)
                                            o
                                            (cons '(attribute vec2 a_uv)
                                                  o))))
                                o)
                              out))
                     (out (if (= i last-attr)
                              (append
                               (list
                                palette
                                '(attribute vec4 a_weights)
                                '(attribute vec4 a_joints))
                               out)
                              out)))
                (loop (cdr fs) (+ i 1) out)))))))

  (set! gltf-skin-vs (gltf-skin-shader mesh-tex-vs))
  (set! gltf-skin-vs3 (gltf-skin-shader3 mesh-tex-vs))

  ;; KHR_mesh_quantization: read component c of a vertex as a flonum,
  ;; dequantizing by componentType + normalized.  Positions ride the
  ;; node's tiny scale/offset (applied as the model matrix at draw), so
  ;; they come through as unnormalized integers; normals/uvs normalize.
  (define ($s8 at) (let ((u (%mem-u8-ref at))) (if (>= u 128) (- u 256) u)))
  (define ($s16 at) (let ((u ($glb-u16 at))) (if (>= u 32768) (- u 65536) u)))
  (define ($clamp-1 x) (if (fl<? x -1.0) -1.0 x))
  (define ($deq base c ct norm)
    (cond
     ((= ct 5126) (%mem-f32-ref (+ base (* 4 c))))
     ((= ct 5123) (let ((v (fixnum->flonum ($glb-u16 (+ base (* 2 c))))))
                    (if norm (fl/ v 65535.0) v)))
     ((= ct 5122) (let ((v (fixnum->flonum ($s16 (+ base (* 2 c))))))
                    (if norm ($clamp-1 (fl/ v 32767.0)) v)))
     ((= ct 5121) (let ((v (fixnum->flonum (%mem-u8-ref (+ base c)))))
                    (if norm (fl/ v 255.0) v)))
     ((= ct 5120) (let ((v (fixnum->flonum ($s8 (+ base c)))))
                    (if norm ($clamp-1 (fl/ v 127.0)) v)))
     (else (error 'gltf "bad vertex component type" ct))))

  ;; accessor type string ("VEC3"/"VEC4"/...)
  (define ($acc-type json i)
    (json-ref (vector-ref (json-ref json "accessors") i) "type"))

  ;; like $acc-info, but with the tight stride derived from the
  ;; component type when the bufferView declares none
  (define ($attr-info json bin i ncomp)
    (let ((inf ($acc-info json bin i 0)))
      (list (car inf)
            (if (= (cadr inf) 0)
                (* ncomp (case (cadddr inf)
                           ((5126) 4)
                           ((5123 5122) 2)
                           (else 1)))
                (cadr inf))
            (caddr inf) (cadddr inf) (list-ref inf 4))))

  ;; one primitive: interleave the attributes present in canonical
  ;; order -- position normal uv tangent color joints weights -- and
  ;; pack u16 index pairs into fresh staging memory.  The uv slot
  ;; rides along (zeroed) whenever anything beyond position+normal
  ;; is present, so every layout past 24 bytes starts pos/nrm/uv.
  (define ($build-prim json bin prim world skin nidx mw)
    (let* ((attrs (json-ref prim "attributes"))
           ;; every attribute's tight stride follows its component
           ;; type: quantized POSITION/NORMAL/TEXCOORD_0 pack to
           ;; 6/3/4 bytes, not to float sizes
           (pos ($attr-info json bin (json-ref attrs "POSITION") 3))
           (nrm (let ((i (json-ref attrs "NORMAL")))
                  (and i ($attr-info json bin i 3))))
           (uv (let ((i (json-ref attrs "TEXCOORD_0")))
                 (and i ($attr-info json bin i 2))))
           (jn0 (let ((i (json-ref attrs "JOINTS_0")))
                  (and i skin ($attr-info json bin i 4))))
           (wt (and jn0
                    (let ((i (json-ref attrs "WEIGHTS_0")))
                      (and i ($attr-info json bin i 4)))))
           (jn (and wt jn0))
           (tan (let ((i (json-ref attrs "TANGENT")))
                  (and i ($attr-info json bin i 4))))
           (col-n (let ((i (json-ref attrs "COLOR_0")))
                    (and i (if (string=? ($acc-type json i) "VEC3")
                               3
                               4))))
           (col (let ((i (json-ref attrs "COLOR_0")))
                  (and i ($attr-info json bin i col-n))))
           (count (caddr pos))
           (uv-slot (and (or uv tan col jn) #t))
           (o-tan (and tan 32))
           (o-col (and col (+ 32 (if tan 16 0))))
           (o-jn (and jn (+ 32 (if tan 16 0) (if col 16 0))))
           (stride (+ 24 (if uv-slot 8 0) (if tan 16 0)
                      (if col 16 0) (if jn 32 0)))
           (layout (append '(position normal)
                           (if uv-slot '(uv) '())
                           (if tan '(tangent) '())
                           (if col '(color) '())
                           (if jn '(joints weights) '())))
           (vbytes (* stride count))
           (vbase (fx-alloc! vbytes))
           ;; componentType + normalized per attribute (5126 float =
           ;; the plain path; anything else is KHR_mesh_quantization)
           (pct (cadddr pos)) (pn (list-ref pos 4))
           (nct (and nrm (cadddr nrm))) (nn (and nrm (list-ref nrm 4)))
           (uct (and uv (cadddr uv))) (un (and uv (list-ref uv 4))))
      (let copy ((v 0))
        (when (< v count)
          (let ((src (+ (car pos) (* v (cadr pos))))
                (dst (+ vbase (* v stride))))
            (%mem-f32-set! dst ($deq src 0 pct pn))
            (%mem-f32-set! (+ dst 4) ($deq src 1 pct pn))
            (%mem-f32-set! (+ dst 8) ($deq src 2 pct pn))
            (if nrm
                (let ((ns (+ (car nrm) (* v (cadr nrm)))))
                  (%mem-f32-set! (+ dst 12) ($deq ns 0 nct nn))
                  (%mem-f32-set! (+ dst 16) ($deq ns 1 nct nn))
                  (%mem-f32-set! (+ dst 20) ($deq ns 2 nct nn)))
                (begin
                  (%mem-f32-set! (+ dst 12) 0.0)
                  (%mem-f32-set! (+ dst 16) 1.0)
                  (%mem-f32-set! (+ dst 20) 0.0)))
            (if uv
                (let ((us (+ (car uv) (* v (cadr uv)))))
                  (%mem-f32-set! (+ dst 24) ($deq us 0 uct un))
                  (%mem-f32-set! (+ dst 28) ($deq us 1 uct un)))
                (when uv-slot            ; slot present, no data: zeros
                  (%mem-f32-set! (+ dst 24) 0.0)
                  (%mem-f32-set! (+ dst 28) 0.0)))
            (when tan
              (let ((ts (+ (car tan) (* v (cadr tan))))
                    (tct (cadddr tan)) (tn (list-ref tan 4)))
                (let comp ((c 0))
                  (when (< c 4)
                    (%mem-f32-set! (+ dst o-tan (* 4 c))
                                   ($deq ts c tct tn))
                    (comp (+ c 1))))))
            (when col                    ; VEC3 colors: alpha fills 1
              (let ((cs (+ (car col) (* v (cadr col))))
                    (cct (cadddr col)) (cn (list-ref col 4)))
                (let comp ((c 0))
                  (when (< c 4)
                    (%mem-f32-set! (+ dst o-col (* 4 c))
                                   (if (< c col-n)
                                       ($deq cs c cct cn)
                                       1.0))
                    (comp (+ c 1))))))
            (when jn                     ; joints as floats + weights
              (let ((js (+ (car jn) (* v (cadr jn))))
                (u16? (= (cadddr jn) 5123))
                    (ws (+ (car wt) (* v (cadr wt)))))
                (let comp ((c 0))
                  (when (< c 4)
                    (%mem-f32-set!
                     (+ dst o-jn (* 4 c))
                     (fixnum->flonum
                      (if u16?
                          ($glb-u16 (+ js (* 2 c)))
                          (%mem-u8-ref (+ js c)))))
                    (%mem-f32-set! (+ dst o-jn 16 (* 4 c))
                                   ($deq ws c (cadddr wt)
                                         (list-ref wt 4)))
                    (comp (+ c 1)))))))
          (copy (+ v 1))))
      ;; indices: u8/u16/u32 accessor, or none (sequential vertices).
      ;; primitives past 65536 vertices keep 32-bit indices (webgl2);
      ;; everything else packs u16 pairs
      (let* ((ii (json-ref prim "indices"))
             (inf (and ii ($acc-info json bin ii 0)))
             (icount (if inf (caddr inf) count))
             (u32? (> count 65536))
             (idx (if inf
                      (let ((at (car inf)) (ct (cadddr inf)))
                        (lambda (k)
                          (cond
                           ((= ct 5121) (%mem-u8-ref (+ at k)))
                           ((= ct 5123) ($glb-u16 (+ at (* k 2))))
                           ((= ct 5125) ($glb-u32 (+ at (* k 4))))
                           (else (error 'gltf "bad index component"
                                        ct)))))
                      (lambda (k) k)))
             (ibytes (if u32?
                         (* 4 icount)
                         (* 4 (quotient (+ icount 1) 2))))
             (ibase (fx-alloc! ibytes)))
        (if u32?
            (let pack ((k 0) (at ibase))
              (when (< k icount)
                (%mem-i32-set! at (idx k))
                (pack (+ k 1) (+ at 4))))
            ;; two u16 halves, stored bytewise: the packed i32 value
            ;; itself would pass 2^29 once the odd-position index
            ;; reaches 8192, which is past the fixnum range -- the
            ;; store must never materialise it as one number
            (let pack ((k 0) (at ibase))
              (when (< k icount)
                (let ((lo (idx k))
                      (hi (if (< (+ k 1) icount) (idx (+ k 1)) 0)))
                  (%mem-u8-set! at (bitwise-and lo 255))
                  (%mem-u8-set! (+ at 1)
                                (bitwise-arithmetic-shift-right lo 8))
                  (%mem-u8-set! (+ at 2) (bitwise-and hi 255))
                  (%mem-u8-set! (+ at 3)
                                (bitwise-arithmetic-shift-right hi 8)))
                (pack (+ k 2) (+ at 4)))))
        ($make-gprim vbase vbytes ibase ibytes icount u32?
                     ($material-color json (json-ref prim "material"))
                     ($material-mr json (json-ref prim "material"))
                     world nidx stride layout
                     ($prim-tex-image json prim)
                     ($prim-mat-tex json prim "normalTexture")
                     ($prim-mat-tex json prim "emissiveTexture")
                     ($prim-mat-tex json prim "occlusionTexture")
                     ($material-emissive json (json-ref prim "material"))
                     (and jn skin)
                     ;; morph targets: POSITION deltas, CPU-blended
                     (let ((tg (json-ref prim "targets")))
                       (and tg (> (vector-length tg) 0)
                            (let* ((nt (vector-length tg))
                                   (b (make-vector (* count 3) 0.0))
                                   (ds (make-vector nt #f))
                                   (w (make-vector nt 0.0)))
                              ;; the base comes from the canonical
                              ;; interleave, already dequantized --
                              ;; re-reading the source accessor as
                              ;; f32 would misread quantized data
                              (let bv ((v 0))
                                (when (< v count)
                                  (let ((src (+ vbase (* v stride))))
                                    (let c2 ((j 0))
                                      (when (< j 3)
                                        (vector-set!
                                         b (+ (* v 3) j)
                                         (%mem-f32-ref (+ src (* 4 j))))
                                        (c2 (+ j 1)))))
                                  (bv (+ v 1))))
                              (let tgt ((k 0))
                                (when (< k nt)
                                  (let* ((acc ($attr-info
                                               json bin
                                               (json-ref
                                                (vector-ref tg k)
                                                "POSITION") 3))
                                         (act (cadddr acc))
                                         (an (list-ref acc 4))
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
                                               ($deq src j act an))
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
                              ;; slot 5: the bind weights, so a clip
                              ;; that does not drive them can return
                              ;; here instead of keeping the last
                              ;; clip's pose
                              (let ((bw (make-vector nt 0.0)))
                                (let cw ((k 0))
                                  (when (< k nt)
                                    (vector-set! bw k (vector-ref w k))
                                    (cw (+ k 1))))
                                (vector b ds w #t nidx bw)))))
                     #f #f #f #f #f #f))))

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
                         ;; node.weights overrides mesh.weights, so
                         ;; two nodes can instance one mesh at
                         ;; different morph poses
                         (mw (let ((nw (json-ref node "weights")))
                               (if nw nw (json-ref mesh "weights")))))
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
            ;; decode any EXT_meshopt_compression bufferViews first,
            ;; so every accessor read below finds decoded data
            ($gltf-meshopt! json bin)
            (let* ((roots (json-ref
                           (vector-ref (json-ref json "scenes")
                                       ($or0 (json-ref json "scene")))
                           "nodes")))
              (let root ((k 0))
                (when (< k (vector-length roots))
                  (walk-node (vector-ref roots k) (m4-identity))
                  (root (+ k 1)))))
            (let* ((nodes ($gltf-node-table json))
                   (skins ($gltf-skin-table json bin)))
              ($make-gltf (reverse prims)
                          ($gltf-image-table json bin)
                          nodes skins
                          ($gltf-anim-table json bin)
                          ($gltf-pose-arena nodes)
                          ($gltf-pal-arena nodes skins)
                          #f))))))

  ;; the pose arena: immutable bind TRS per node, plus the scratch
  ;; and marks a crossfade needs (preallocated -- a fade runs every
  ;; frame of a transition)
  (define ($gltf-pose-arena nodes)
    (let* ((n (vector-length nodes))
           (binds (make-vector n #f))
           (scratch (make-vector n #f)))
      (let loop ((i 0))
        (when (< i n)
          ;; only the TRS slots: nothing ever writes slot 10 (the
          ;; matrix form) after parse, so copying it back would be a
          ;; no-op that aliases the live matrix vector rather than
          ;; protecting it.  A matrix node keeps its transform
          ;; because $node-local reads slot 10 in preference to TRS.
          (let ((src (vector-ref nodes i))
                (b (make-vector 10 0.0)))
            (let cp ((j 0))
              (when (< j 10)
                (vector-set! b j (vector-ref src j))
                (cp (+ j 1))))
            (vector-set! binds i b)
            (vector-set! scratch i (make-vector 10 0.0)))
          (loop (+ i 1))))
      (vector binds scratch (make-vector n #f))))

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
              ;; 1x1 fallbacks so every primitive OWNS a value for
              ;; the optional slots: a program declaring u_nmap must
              ;; never sample whatever the previous primitive left
              ;; on the unit (or unit 0's base color)
              (let* ((mk (lambda (r gr b)
                           (let ((t (fx-texture!))
                                 (px (fx-alloc! 4)))
                             (%mem-u8-set! px r)
                             (%mem-u8-set! (+ px 1) gr)
                             (%mem-u8-set! (+ px 2) b)
                             (%mem-u8-set! (+ px 3) 255)
                             (gl-texture-data! t px 1 1)
                             t)))
                     (flat (mk 128 128 255))   ; tangent-space +z
                     (white (mk 255 255 255))) ; base/emissive, AO 1
                (for-each
                 (lambda (p)
                   (let ((set (lambda (img put! dflt)
                                (put! p (if img
                                            (vector-ref slots img)
                                            dflt)))))
                     ;; base color too: an untextured primitive must
                     ;; not inherit unit 0 from the textured one
                     ;; drawn before it
                     (set ($gprim-tex-img p) $gprim-tex! white)
                     (set (gprim-normal-img p) $gprim-ntex! flat)
                     (set (gprim-emissive-img p) $gprim-etex! white)
                     (set (gprim-occlusion-img p) $gprim-otex!
                          white)))
                 (gltf-prims g)))
              (k g))))
      (if (= n 0)
          (resolve!)
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

  ;; Does this primitive have a base color IMAGE to sample?  After
  ;; gltf-load-textures! every primitive owns a bindable slot in
  ;; gprim-tex -- a 1x1 white one when it has no image -- so
  ;; gprim-tex answers "what do I bind", not "what does the asset
  ;; have"; this answers the latter.
  ;;
  ;; It is NOT the way to choose a program: the uv slot follows
  ;; TEXCOORD_0, not the material, so a material with a base color
  ;; image on a mesh without uvs reads #t while gprim-layout carries
  ;; no uv (and the reverse happens too).  gprim-layout is the
  ;; contract a program must match; use this to decide whether the
  ;; sample is worth taking.
  (define (gprim-textured? p) (and ($gprim-tex-img p) #t))

  ;; A primitive's CURRENT model matrix -- what gltf-draw! feeds
  ;; u_model, so a renderer driving its own shaders wants this one
  ;; rather than gprim-world (the bind pose captured at parse time,
  ;; which does not follow animation).  For a SKINNED primitive this
  ;; is the identity: glTF says a skinned mesh ignores its node's
  ;; transform, and the joint palette already carries the pose --
  ;; returning the node's global here would transform twice.  The
  ;; optional root gltf-draw! takes is the caller's to apply.
  (define (gltf-prim-world g p)
    (if ($gprim-skin p)
        (m4-identity)
        ($node-global g ($gprim-node p))))

  ;; the shader attributes a layout demands: (name . components), in
  ;; order.  Widths are part of the contract, not a detail -- wrong
  ;; ones can cancel out in the total (vec2 + vec4 spans the same 24
  ;; bytes as vec3 + vec3) and then every offset past the first is
  ;; wrong while the stride looks right.
  ;; one interleaved attribute's shader name and component count --
  ;; the single place the widths are written down, so the shader
  ;; contract below and the byte offsets above cannot disagree
  (define ($layout-attr a)
    (case a
      ((position) '(a_pos . 3))
      ((normal) '(a_normal . 3))
      ((uv) '(a_uv . 2))
      ((tangent) '(a_tangent . 4))
      ((color) '(a_color . 4))
      ((joints) '(a_joints . 4))
      ((weights) '(a_weights . 4))
      (else (cons a 0))))

  (define ($layout-attr-schema layout) (map $layout-attr layout))

  ;; where one attribute starts inside a vertex, or #f when the
  ;; layout does not carry it: the canonical order IS the byte
  ;; order, so the offset is the widths before it
  (define ($layout-offset layout a)
    (let scan ((l layout) (off 0))
      (cond ((null? l) #f)
            ((eq? (car l) a) off)
            (else (scan (cdr l)
                        (+ off (* 4 (cdr ($layout-attr (car l))))))))))

  ;; draw every primitive; geometry uploads on its first frame.
  ;; prog is an fx-program over mesh-lit-vs/-fs (or any shader with
  ;; the same a_pos/a_normal layout and u_mvp; u_model, u_color and
  ;; the texture samplers upload only where the program declares
  ;; them).
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

  ;; the uniform buffer behind the big palette, made on first use.
  ;; It is sized for the FULL block (256 mat4) rather than for this
  ;; asset's joint count: GL wants the bound buffer to cover the
  ;; block a program declares, and the block's size is the shader's
  ;; property, not the asset's.  One per gltf is enough -- upload,
  ;; bind and draw are consecutive in the command stream, so two
  ;; skins never share a buffer across a draw boundary.
  (define ($gltf-skin-ubo! g)
    (or ($gltf-ubo g)
        (let ((s (fx-ubo! (* 64 gltf-skin-block-joints))))
          ($gltf-ubo! g s)
          s)))

  ;; Which palette carrier does this program use?  The two are
  ;; mutually exclusive by construction -- a block member has no
  ;; uniform location of its own, so u_joints is in exactly one of
  ;; the two tables -- which is what lets the choice be made from
  ;; the program alone, with no registration order to consult.  A
  ;; small asset therefore draws fine through a big-palette program
  ;; (the block just carries fewer matrices than it can hold); the
  ;; reverse is the one combination that cannot work, and it is
  ;; refused by name below.
  (define ($skin-upload! g prog si)
    (let ((n (gltf-joint-count g si)))
      (cond
       ((fx-uniform? prog 'u_joints)
        (when (> n gltf-skin-uniform-joints)
          (error 'gltf-draw!
                 "skin has more joints than the uniform-array palette holds; build the program with gltf-skin-shader3"
                 n gltf-skin-uniform-joints))
        (fx-uniform! prog 'u_joints (gltf-joint-palette! g si) n))
       ((memq $gltf-skin-block-name (fx-program-blocks prog))
        (let ((ubo ($gltf-skin-ubo! g)))
          ;; the palette is already the block's memory image -- the
          ;; std140 stride for a mat4 array is 64 bytes, exactly
          ;; what gltf-joint-palette! composed, so this is a
          ;; straight copy of n matrices with no repacking
          (cmd-ubo-data! ubo (gltf-joint-palette! g si) (* n 64))
          (cmd-bind-ubo! gltf-skin-binding ubo)))
       (else
        (error 'gltf-draw!
               "program carries no joint palette: no u_joints uniform and no Skin block"
               (fx-program-blocks prog))))))

  (define (gltf-draw! g prog vp . root)
    (for-each
     (lambda (p)
       ;; Strides collide across layouts (tangent and color are both
       ;; vec4) and wrong widths can cancel out in the total, so the
       ;; contract is per attribute: name AND component count.  A
       ;; mismatch would silently feed one attribute's bytes to
       ;; another -- refuse it instead.
       (let ((want ($layout-attr-schema (gprim-layout p)))
             (have (fx-program-attribute-schema prog)))
         (unless (equal? want have)
           (error 'gltf-draw!
                  "program attributes do not match the primitive layout"
                  have want)))
       ;; a program carrying per-instance attributes needs an
       ;; instance buffer this entry point never binds; the shader
       ;; would read zeros for them
       (unless (= 0 (fx-program-istride prog))
         (error 'gltf-draw!
                "program declares per-instance attributes (i_*)"
                (fx-program-istride prog)))
       (let ((fresh (not ($gprim-vbuf p))))
         (when fresh
           ($gprim-vbuf! p (fx-buffer!))
           ($gprim-ibuf! p (fx-buffer!)))
         (fx-use! prog ($gprim-vbuf p))
         (cmd-bind-index! ($gprim-ibuf p))
         (let ((tx (gprim-tex p)))
           (when (and tx (fx-uniform? prog 'u_tex))
             (cmd-bind-texture! 0 tx)
             (fx-uniform! prog 'u_tex 0)))
         ;; material texture slots beyond base color bind only when
         ;; the program declares their samplers
         (let ((bind (lambda (tx unit name)
                       (when (and tx (fx-uniform? prog name))
                         (cmd-bind-texture! unit tx)
                         (fx-uniform! prog name unit)))))
           (bind (gprim-ntex p) 1 'u_nmap)
           (bind (gprim-etex p) 2 'u_emap)
           (bind (gprim-otex p) 3 'u_omap))
         (when (fx-uniform? prog 'u_emissive)
           (let ((e (gprim-emissive p)))
             (fx-uniform! prog 'u_emissive (vector-ref e 0)
                          (vector-ref e 1) (vector-ref e 2))))
         ;; a dirty morph rewrites the staging stream before upload
         (let ((mo (gprim-morph p)))
           (when (and mo (vector-ref mo 3))
             ($morph-apply! p mo)
             (unless fresh
               (cmd-buffer-data! (gprim-vbase p) (gprim-vbytes p)))))
         (when fresh
           (cmd-buffer-data! (gprim-vbase p) (gprim-vbytes p))
           (if (gprim-index-u32? p)
               (cmd-index-data32! (gprim-ibase p) (gprim-ibytes p))
               (cmd-index-data! (gprim-ibase p) (gprim-ibytes p))))
         (let ((c (gprim-color p)))
           (if ($gprim-skin p)
               ;; skinned: the resident palette carries the pose --
               ;; composed in SIMD, uploaded in a handful of command
               ;; words through whichever carrier the program
               ;; declares; the optional root still frames the asset
               (begin
                 ($skin-upload! g prog ($gprim-skin p))
                 (fx-uniform! prog 'u_mvp
                              (if (null? root) vp (m4-mul vp (car root))))
                 ;; skinned variants of world-space shaders read
                 ;; u_model for their normals; the root frames it
                 (when (fx-uniform? prog 'u_model)
                   (fx-uniform! prog 'u_model
                                (if (null? root)
                                    (m4-identity)
                                    (car root)))))
               ;; the world matrix comes from the RUNTIME node tree,
               ;; so animating an unskinned node moves what draws
               (let* ((w0 ($node-global g ($gprim-node p)))
                      (world (if (null? root)
                                 w0
                                 (m4-mul (car root) w0))))
                 (fx-uniform! prog 'u_mvp (m4-mul vp world))
                 (when (fx-uniform? prog 'u_model)
                   (fx-uniform! prog 'u_model world))))
           ;; optional like u_model: a flat user shader may omit it
           (when (fx-uniform? prog 'u_color)
             (fx-uniform! prog 'u_color (vector-ref c 0) (vector-ref c 1)
                          (vector-ref c 2) (vector-ref c 3)))
           (if (gprim-index-u32? p)
               (cmd-draw-elements32! GL-TRIANGLES (gprim-icount p))
               (cmd-draw-elements! GL-TRIANGLES (gprim-icount p))))))
     (gltf-prims g))))
