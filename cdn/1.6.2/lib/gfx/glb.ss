;; Write standard glTF 2.0 GLB bytes: the inverse of (gfx gltf).
;;
;; A mesh built or edited in staging memory leaves as a file any
;; glTF tool reads.  The writer takes what is already there -- an
;; interleaved vertex block and an index block -- and wraps them in
;; a container, so nothing is repacked:
;;
;;   (define loc (glb-write!
;;                 (list (list '(position normal) vbase vcount ibase icount
;;                             'color (vector 1.0 0.0 0.0 1.0)))))
;;   (car loc)  ; staging base of the GLB
;;   (cdr loc)  ; its byte length -- feed the pair straight to
;;              ; (gltf-parse (car loc) (cdr loc)), or copy the range
;;              ; out to a Blob and download it
;;
;; A primitive is described by a plain list, not by a record only
;; this library can build:
;;
;;   (layout vbase vcount ibase icount . options)
;;
;; layout names the attributes present, in the order they occupy the
;; interleave: position normal uv tangent color joints weights uv1,
;; each float32 (12/12/8/16/16/16/16/8 bytes).  A second UV set sits
;; at the END, so a layout that gains one moves nothing before it.
;; vbase points at vertex 0;
;; the stride is the sum of the layout's attribute sizes unless an
;; option overrides it.  ibase points at a tight u16 (or u32) index
;; array; icount 0 -- or ibase #f -- writes a non-indexed primitive.
;;
;; Options are a key/value tail, so a later revision can add one
;; without disturbing a caller:
;;   color       #(r g b a) or (r g b a) -> a baseColorFactor
;;                 material; absent means no material at all
;;   index-u32?  index element width; defaults to #t past 65536
;;                 vertices, which is where (gfx gltf) switches too
;;   stride      an explicit byte stride, for a padded interleave;
;;                 must be a multiple of 4 and at least the layout's
;;                 own size
;;   joints-u16? JOINTS_0 element width; defaults to #t once a joint
;;                 index passes 255
;;   material    an index into the file's own materials array;
;;                 refused together with color, which ASKS for one
;;   node        which node carries this primitive's mesh --
;;                 primitives sharing a node share one mesh
;;   skin        which skin poses it; every primitive on one node
;;                 must name the same one
;;   targets     ((position normal tangent) ...), each entry a
;;                 source of vcount VEC3 deltas or #f -- a target
;;                 may displace any one, two or three of them
;;   weights     one per target, the mesh's own morph weights
;;
;; glb-write! itself takes a key/value tail as well, for everything
;; that is not one primitive's vertices:
;;
;;   (glb-write! prims 'nodes ns 'mesh-node k 'skins sks 'anims as
;;               'images ims 'samplers ss 'textures ts
;;               'materials ms 'cameras cs)
;;
;;   nodes      the whole node array, in file order:
;;                (name parent translation rotation scale) or
;;                (name parent . options) with the same three keys.
;;                parent is an index, or -1/#f for a root; a node's
;;                children and the scene's roots are derived from it.
;;                Absent means one node, which carries the mesh --
;;                exactly what this writer emitted before nodes
;;                existed.
;;   mesh-node  which node carries the mesh (default 0)
;;   skin       (joint-node-indices inverse-bind-matrices), the
;;                second element a staging base of njoints tight
;;                mat4s, a sequence of 16-number matrices, or #f for
;;                identity binds
;;   anims      a list of clips, each (name channels), each channel
;;                (node path times values count interpolation) --
;;                path one of translation/rotation/scale/weights,
;;                interpolation one of linear/step/cubic (or the
;;                glTF spellings), defaulting to linear.  times and
;;                values are sources: a staging base of tightly
;;                packed f32, or a sequence.  Under CUBICSPLINE the
;;                values source holds the spec's in-tangent/value/
;;                out-tangent triples, 3*count elements.  A morph
;;                weights channel takes 'components for the number
;;                of targets a key carries.
;;
;; Sources are deliberately wider than staging memory: (gfx gltf)
;; hands a parsed clip back as Scheme vectors, and those go straight
;; back out with no staging round trip.  See docs/graphics.md for
;; the re-export recipe.
;;
;; What comes out: one buffer (the BIN chunk), a bufferView per
;; vertex block (with a byteStride), per index block, and per joint
;; block, one accessor per attribute plus one per index array, a
;; mesh per node that carries primitives (one mesh holding all of
;; them when none names a node), the node array, one scene, and --
;; when asked for -- the skins, the animations, the materials with
;; their textures and samplers, the images, the cameras and the
;; morph targets.  POSITION carries the min and max the
;; specification requires, computed from the data; so does every
;; animation input.
;;
;; Blocks are numbered in one fixed order, and every category added
;; since goes at the END of it, so a file written before them keeps
;; the view and accessor numbers it had:
;;   bufferViews  per primitive [vertex, index?, joints?], then the
;;                inverse binds, the animation samplers, the morph
;;                deltas, and last the images
;;   accessors    the same, minus the images -- an image is bytes,
;;                not numbers, and has a view but no accessor
;;
;; JOINTS_0 is the one attribute that does not stay in place.  glTF
;; stores joint indices as unsigned bytes or shorts while the
;; interleave (gfx gltf) builds carries them as floats, so they are
;; narrowed into a block of their own and the interleave's own 16
;; bytes go unreferenced.  Every other attribute, including
;; WEIGHTS_0, is described where it already lies.
;;
;; Round trip: for a layout in the canonical interleave order
;; (position normal, then uv, then tangent, then color, then joints
;; and weights, then uv1) gltf-parse reproduces the vertex bytes
;; exactly.
;; Other layouts are written faithfully but come back canonicalized
;; -- the loader always gives a primitive a normal (+y when the file
;; has none) and always carries a uv slot once anything past normal
;; is present, so (position uv) is written as POSITION+TEXCOORD_0
;; and read back as position normal uv.
;;
;; Not written, each for its own reason:
;;   * images behind a `uri` -- this writer embeds, so an external
;;     file would have to be fetched and inlined, which is a
;;     decision about I/O rather than about the format;
;;   * names on materials, meshes, skins and cameras.  Nodes and
;;     animation clips DO carry theirs; the rest are not read back
;;     by (gfx gltf), so writing them would be inventing content;
;;   * `extras` of any kind, which is where a tool puts a morph
;;     target's names -- an asset's targetNames do not survive;
;;   * alphaMode, alphaCutoff, doubleSided and the KHR_materials_*
;;     extensions -- (gfx gltf) does not read them either, so a
;;     round trip has nothing to preserve;
;;   * one mesh instanced by SEVERAL nodes.  The reader flattens a
;;     mesh into its primitives per node, so the sharing is gone by
;;     the time a re-export sees it: two nodes on one mesh come back
;;     out as two meshes with the same contents.  The file is
;;     correct and one bufferView larger.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx glb)
  (export glb-write! glb-stride glb-offset)
  (import (rnrs) (web json) (gfx fx))

  ;; ---- the attribute vocabulary ----------------------------------
  ;; (symbol glTF-name components bytes accessor-type).  Every
  ;; attribute occupies float32s in the interleave (componentType
  ;; 5126): that is the form (gfx gltf) rebuilds into, so the pair
  ;; round-trips without a conversion on either side.  JOINTS_0 is
  ;; the exception on the way OUT -- see $joints-write! -- but its
  ;; interleave slot is float32 like the rest.
  (define $attr-table
    '((position "POSITION"   3 12 "VEC3")
      (normal   "NORMAL"     3 12 "VEC3")
      (uv       "TEXCOORD_0" 2  8 "VEC2")
      (uv1      "TEXCOORD_1" 2  8 "VEC2")
      (tangent  "TANGENT"    4 16 "VEC4")
      (color    "COLOR_0"    4 16 "VEC4")
      (joints   "JOINTS_0"   4 16 "VEC4")
      (weights  "WEIGHTS_0"  4 16 "VEC4")))

  (define ($attr who sym)
    (let ((e (assq sym $attr-table)))
      (if e e (error who "unknown vertex attribute" sym))))

  (define ($attr-name e) (cadr e))
  (define ($attr-bytes e) (cadddr e))
  (define ($attr-type e) (list-ref e 4))

  ;; the byte stride a layout packs into, tightly
  (define (glb-stride layout)
    (let loop ((l layout) (n 0))
      (if (null? l)
          n
          (loop (cdr l) (+ n ($attr-bytes ($attr 'glb-stride (car l))))))))

  ;; where an attribute sits inside that stride, or #f when the
  ;; layout does not carry it
  (define (glb-offset layout sym)
    (let loop ((l layout) (n 0))
      (cond ((null? l) #f)
            ((eq? (car l) sym) n)
            (else
             (loop (cdr l)
                   (+ n ($attr-bytes ($attr 'glb-offset (car l)))))))))

  ;; ---- little-endian scalars into staging ------------------------
  (define ($u32! at v)
    (%mem-u8-set! at (remainder v 256))
    (%mem-u8-set! (+ at 1) (remainder (quotient v 256) 256))
    (%mem-u8-set! (+ at 2) (remainder (quotient v 65536) 256))
    (%mem-u8-set! (+ at 3) (remainder (quotient v 16777216) 256)))

  (define ($u16! at v)
    (%mem-u8-set! at (remainder v 256))
    (%mem-u8-set! (+ at 1) (remainder (quotient v 256) 256)))

  (define ($copy! dst src n)
    (let loop ((i 0))
      (when (< i n)
        (%mem-u8-set! (+ dst i) (%mem-u8-ref (+ src i)))
        (loop (+ i 1)))))

  (define ($fill0! at n)
    (let loop ((i 0))
      (when (< i n)
        (%mem-u8-set! (+ at i) 0)
        (loop (+ i 1)))))

  ;; one index, read from the caller's array in its own width
  (define ($idx-ref base k u32?)
    (if u32?
        (let ((a (+ base (* 4 k))))
          (+ (%mem-u8-ref a)
             (* 256 (%mem-u8-ref (+ a 1)))
             (* 65536 (%mem-u8-ref (+ a 2)))
             (* 16777216 (%mem-u8-ref (+ a 3)))))
        (let ((a (+ base (* 2 k))))
          (+ (%mem-u8-ref a) (* 256 (%mem-u8-ref (+ a 1)))))))

  (define ($align4 n)
    (let ((r (remainder n 4))) (if (= r 0) n (+ n (- 4 r)))))

  (define ($fl v) (if (flonum? v) v (exact->inexact v)))

  (define ($num who v)
    (if (number? v) ($fl v) (error who "expected a number" v)))

  ;; POSITION's per-component bounds, which the specification makes
  ;; mandatory -- a viewer culls and frames the scene with them, so
  ;; they are read out of the data rather than guessed
  (define ($pos-bounds vbase vcount stride off)
    (let ((mn (make-vector 3 0.0))
          (mx (make-vector 3 0.0)))
      (let seed ((c 0))
        (when (< c 3)
          (let ((v (%mem-f32-ref (+ vbase off (* 4 c)))))
            (vector-set! mn c v)
            (vector-set! mx c v))
          (seed (+ c 1))))
      (let vert ((v 1))
        (when (< v vcount)
          (let ((row (+ vbase (* v stride) off)))
            (let comp ((c 0))
              (when (< c 3)
                (let ((x (%mem-f32-ref (+ row (* 4 c)))))
                  (when (fl<? x (vector-ref mn c)) (vector-set! mn c x))
                  (when (fl<? (vector-ref mx c) x) (vector-set! mx c x)))
                (comp (+ c 1)))))
          (vert (+ v 1))))
      (cons mn mx)))

  ;; ---- key/value option tails ------------------------------------
  ;; The same two procedures serve the primitive descriptor, the
  ;; node descriptor, the channel descriptor and glb-write!'s own
  ;; tail: one rule for "an option is a key and a value, and the key
  ;; is one this level knows".
  (define ($option opts key default)
    (cond ((null? opts) default)
          ((eq? (car opts) key) (cadr opts))
          (else ($option (cddr opts) key default))))

  (define ($check-options who keys opts)
    (cond ((null? opts) #t)
          ((null? (cdr opts))
           (error who "option without a value" (car opts)))
          ((not (memq (car opts) keys))
           (error who "unknown option" (car opts)))
          (else ($check-options who keys (cddr opts)))))

  (define ($rgba who c)
    (let ((v (cond ((vector? c) c)
                   ((list? c) (list->vector c))
                   (else (error who "color must be four numbers" c)))))
      (unless (= (vector-length v) 4)
        (error who "color must be four numbers" c))
      (vector ($fl (vector-ref v 0)) ($fl (vector-ref v 1))
              ($fl (vector-ref v 2)) ($fl (vector-ref v 3)))))

  ;; ---- sources: staging memory, or a sequence --------------------
  ;; Every block the writer emits beyond the vertex and index blocks
  ;; -- inverse binds, keyframe times, keyframe values -- reads
  ;; through one protocol, so a caller holding f32s in staging and a
  ;; caller holding the vectors (gfx gltf) parsed feed the same
  ;; code.  A source is either a staging base (tightly packed f32s,
  ;; element-major) or a sequence of elements, each element a
  ;; sequence of ncomp numbers -- or a bare number when ncomp is 1.
  (define ($seq x)
    (cond ((vector? x) x)
          ((and (pair? x) (list? x)) (list->vector x))
          ((null? x) (vector))
          (else #f)))

  (define ($seq-list x)
    (cond ((vector? x) (vector->list x))
          ((and (pair? x) (list? x)) x)
          ((null? x) '())
          (else (error 'glb-write! "expected a sequence of numbers" x))))

  (define ($src who x)
    (if (and (integer? x) (exact? x) (>= x 0))
        x
        (let ((v ($seq x)))
          (if v
              v
              (error who "expected a staging base or a sequence" x)))))

  (define ($elem-len el)
    (cond ((vector? el) (vector-length el))
          ((and (pair? el) (list? el)) (length el))
          (else #f)))

  (define ($elem-ref who el c)
    (cond ((vector? el) ($num who (vector-ref el c)))
          ((and (pair? el) (list? el)) ($num who (list-ref el c)))
          (else ($num who el))))

  ;; every length and width checked once, at plan time, so a short
  ;; source is named at the call rather than trapping deep inside
  ;; the byte writer
  ;; A sequence may be given element by element -- #(#(x y z) ...) --
  ;; or flat, #(x y z x y z ...), the way the reader hands morph
  ;; deltas back and the way staging memory already holds them.  The
  ;; two are told apart by what the first entry IS, not by length: a
  ;; number there can only be the flat form.
  (define ($flat? x ncomp)
    (and (vector? x) (> ncomp 1) (> (vector-length x) 0)
         (number? (vector-ref x 0))))

  (define ($src-check who x elems ncomp)
    (when ($flat? x ncomp)
      (unless (>= (vector-length x) (* elems ncomp))
        (error who "the source holds fewer numbers than the count"
               (vector-length x) (* elems ncomp))))
    (when (and (vector? x) (not ($flat? x ncomp)))
      (unless (>= (vector-length x) elems)
        (error who "the source holds fewer elements than the count"
               (vector-length x) elems))
      (let loop ((i 0))
        (when (< i elems)
          (let* ((el (vector-ref x i))
                 (n ($elem-len el)))
            (cond (n (unless (>= n ncomp)
                       (error who "a source element is short" el ncomp)))
                  ((number? el)
                   (unless (= ncomp 1)
                     (error who "a source element needs its components"
                            el ncomp)))
                  (else (error who "a source element is not numbers" el))))
          (loop (+ i 1))))))

  (define ($src-ref who x e c ncomp)
    (cond (($flat? x ncomp)
           ($num who (vector-ref x (+ (* e ncomp) c))))
          ((vector? x) ($elem-ref who (vector-ref x e) c))
          (else (%mem-f32-ref (+ x (* 4 (+ (* e ncomp) c)))))))

  ;; ---- the primitive descriptor ----------------------------------
  (define $option-keys '(color index-u32? stride joints-u16?
                         material node skin targets weights))

  ;; A plan is the descriptor with everything derived and checked:
  ;;   (layout vbase vcount stride ibase icount u32? color voff ioff
  ;;    joff ju16?)
  ;; voff/ioff/joff are byte offsets inside the BIN chunk; joff is
  ;; #f unless the layout carries joints.
  (define ($plan-layout p) (car p))
  (define ($plan-vbase p) (cadr p))
  (define ($plan-vcount p) (caddr p))
  (define ($plan-stride p) (cadddr p))
  (define ($plan-ibase p) (list-ref p 4))
  (define ($plan-icount p) (list-ref p 5))
  (define ($plan-u32? p) (list-ref p 6))
  (define ($plan-color p) (list-ref p 7))
  (define ($plan-voff p) (list-ref p 8))
  (define ($plan-ioff p) (list-ref p 9))
  (define ($plan-joff p) (list-ref p 10))
  (define ($plan-ju16? p) (list-ref p 11))
  ;; the material this primitive names, or #f -- an index into the
  ;; file's materials array, where `color` instead ASKS for one
  (define ($plan-material p) (list-ref p 12))
  ;; which node carries this primitive's mesh (#f = the mesh-node
  ;; option, which is what every caller before meshes could be split
  ;; meant), and which skin poses it
  (define ($plan-node p) (list-ref p 13))
  (define ($plan-skin p) (list-ref p 14))
  ;; morph targets: a list of #(pos norm|#f tan|#f), each a source of
  ;; vcount VEC3 elements, and the mesh weights that go with them
  (define ($plan-targets p) (list-ref p 15))
  (define ($plan-weights p) (list-ref p 16))

  (define ($plan-vbytes p) (* ($plan-vcount p) ($plan-stride p)))
  (define ($plan-ibytes p)
    (* ($plan-icount p) (if ($plan-u32? p) 4 2)))
  (define ($plan-jbytes p)
    (* ($plan-vcount p) (if ($plan-ju16? p) 8 4)))

  ;; A descriptor and a LIST of descriptors both start with a list,
  ;; so a caller who forgets the outer list would otherwise reach
  ;; memq on a symbol and trap: demand the shape here.  And a layout
  ;; may not repeat an attribute -- two accessors over one byte range
  ;; is a file that reads back as something else.
  (define ($check-layout layout)
    (unless (and (pair? layout) (list? layout) (symbol? (car layout)))
      (error 'glb-write!
             "a primitive is (layout vbase vcount ibase icount . options)"
             layout))
    (unless (memq 'position layout)
      (error 'glb-write! "a primitive needs POSITION" layout))
    (let loop ((l layout))
      (unless (null? l)
        ($attr 'glb-write! (car l))
        (when (memq (car l) (cdr l))
          (error 'glb-write! "attribute repeated in layout" (car l)))
        (loop (cdr l)))))

  ;; every index must name a vertex this primitive owns; a stale
  ;; index draws garbage in a viewer that never reports why
  (define ($check-indices ibase icount u32? vcount)
    (let loop ((k 0))
      (when (< k icount)
        (let ((i ($idx-ref ibase k u32?)))
          (unless (< i vcount)
            (error 'glb-write! "index past the vertex count" i)))
        (loop (+ k 1)))))

  ;; the largest joint index the interleave names, having checked
  ;; that every one of them is a whole number the skin owns.  A
  ;; fractional or out-of-range joint is a pose no reader can
  ;; reproduce, and narrowing it to a byte would hide that.
  (define ($joint-max who vbase vcount stride off njoints)
    (let vert ((v 0) (mx 0))
      (if (= v vcount)
          mx
          (let comp ((c 0) (mx mx))
            (if (= c 4)
                (vert (+ v 1) mx)
                (let ((f (%mem-f32-ref (+ vbase (* v stride) off (* 4 c)))))
                  (when (fl<? f 0.0)
                    (error who "a joint index must not be negative" f))
                  (unless (fl=? f (flfloor f))
                    (error who "a joint index must be a whole number" f))
                  (let ((i (%fl->fx f)))
                    (unless (< i njoints)
                      (error who "joint index past the skin's joints"
                             i njoints))
                    (comp (+ c 1) (if (> i mx) i mx)))))))))

  ;; one morph target: #(pos norm|#f tan|#f), each a source of vcount
  ;; VEC3 elements.  glTF's morph deltas are VEC3 even for TANGENT --
  ;; a target displaces the tangent's xyz and never its handedness --
  ;; so the layout vocabulary is deliberately NOT reused here.
  (define ($target-plan t vcount layout)
    (unless (and (list? t) (= (length t) 3))
      (error 'glb-write!
             "a morph target is (position normal tangent), #f for none" t))
    ;; glTF lets a target displace only attributes the primitive
    ;; ITSELF carries -- a NORMAL delta on a mesh with no normals
    ;; displaces nothing that exists.  The rule is per attribute
    ;; rather than "tangent needs tangent", because the same thing
    ;; is true of every one of them; POSITION is safe by
    ;; construction, since $check-layout already demands it.
    (let ((need (lambda (i sym name)
                  (when (and (list-ref t i) (not (memq sym layout)))
                    (error 'glb-write!
                           "a morph target displaces an attribute the primitive lacks"
                           name layout)))))
      (need 1 'normal "NORMAL")
      (need 2 'tangent "TANGENT"))
    (let ((one (lambda (x)
                 (and x
                      (let ((src ($src 'glb-write! x)))
                        ($src-check 'glb-write! src vcount 3)
                        src)))))
      ;; any one of the three may be #f -- glTF lets a target
      ;; displace only the normals, or only the tangents -- but a
      ;; target that displaces nothing is not a target
      (unless (or (car t) (cadr t) (caddr t))
        (error 'glb-write! "a morph target displaces nothing" t))
      (vector (one (car t)) (one (cadr t)) (one (caddr t)))))

  (define ($targets-plan ts vcount layout)
    (cond ((not ts) '())
          ((null? ts) '())
          ((and (pair? ts) (list? ts))
           (map (lambda (t) ($target-plan t vcount layout)) ts))
          (else (error 'glb-write! "'targets is a list of targets" ts))))

  (define ($index v)
    (if (and (number? v) (integer? v) (inexact? v))
        (inexact->exact v)
        v))

  (define ($plan desc at skins mesh-node nnodes)
    (unless (and (list? desc) (>= (length desc) 5))
      (error 'glb-write!
             "a primitive is (layout vbase vcount ibase icount . options)"
             desc))
    (let* ((layout (car desc))
           (vbase (cadr desc))
           (vcount (caddr desc))
           (ibase0 (cadddr desc))
           (icount0 (list-ref desc 4))
           (opts (list-tail desc 5)))
      ($check-layout layout)
      ($check-options 'glb-write! $option-keys opts)
      (unless (and (integer? vcount) (> vcount 0))
        (error 'glb-write! "a primitive needs at least one vertex" vcount))
      (let* ((tight (glb-stride layout))
             (stride ($option opts 'stride tight))
             (u32? (and ($option opts 'index-u32? (> vcount 65536)) #t))
             (indexed (and ibase0 (> icount0 0)))
             (icount (if indexed icount0 0))
             (ibase (if indexed ibase0 0))
             (jofs (glb-offset layout 'joints))
             (wofs (glb-offset layout 'weights))
             (color (let ((c ($option opts 'color #f)))
                      (and c ($rgba 'glb-write! c))))
           ;; every index has to be EXACT to be looked up or written:
           ;; 0.0 passes integer? and then misses every eqv? on 0 --
           ;; the node lookup that grouped meshes silently found
           ;; nothing -- and reaches the JSON as 0.0, which is not an
           ;; index at all.  One normaliser, so no index option can
           ;; be the one that was forgotten.
           (material ($index ($option opts 'material #f)))
           (node ($index ($option opts 'node #f)))
           (skin-i ($index ($option opts 'skin #f)))
           (targets ($targets-plan ($option opts 'targets #f)
                                   vcount layout))
           (weights ($option opts 'weights #f))
           ;; the joint count comes from the skin this primitive
           ;; names; without one it is the file's first skin, which
           ;; is what a single-skin file always meant
           (njoints (and (> (vector-length skins) 0)
                         (vector-length
                          (vector-ref (vector-ref skins (or skin-i 0)) 0)))))
        ;; a colour ASKS for a material and an index NAMES one: given
        ;; both, there is no answer to which the primitive wears
        (when (and color material)
          (error 'glb-write!
                 "a primitive gives both 'color and 'material" desc))
        (when material
          (unless (and (integer? material) (>= material 0))
            (error 'glb-write! "'material is an index" material)))
        (when node
          (unless (and (integer? node) (>= node 0) (< node nnodes))
            (error 'glb-write! "'node names a node the file lacks" node)))
        (when skin-i
          (unless (and (integer? skin-i) (>= skin-i 0)
                       (< skin-i (vector-length skins)))
            (error 'glb-write! "'skin names a skin the file lacks" skin-i)))
        (when (and weights
                   (not (= (length ($seq-list weights))
                           (length targets))))
          (error 'glb-write!
                 "'weights is one per morph target"
                 (length ($seq-list weights)) (length targets)))
        (unless (and (integer? stride) (>= stride tight))
          (error 'glb-write! "stride is smaller than the layout" stride))
        (unless (= (remainder stride 4) 0)
          (error 'glb-write! "stride must be a multiple of 4" stride))
        ;; JOINTS_0 and WEIGHTS_0 are one attribute in two halves: a
        ;; reader given only one of them has no pose at all
        (when (and jofs (not wofs))
          (error 'glb-write! "a layout with joints needs weights" layout))
        (when (and wofs (not jofs))
          (error 'glb-write! "a layout with weights needs joints" layout))
        (when (and jofs (not njoints))
          (error 'glb-write!
                 "a skinned layout needs the 'skin option" layout))
        (when indexed ($check-indices ibase icount u32? vcount))
        (let* ((ju16?
                (and jofs
                     (and ($option opts 'joints-u16?
                                   (> ($joint-max 'glb-write! vbase vcount
                                                  stride jofs njoints)
                                      255))
                          #t)))
               (voff at)
               (ioff ($align4 (+ voff (* vcount stride))))
               (jend ($align4 (+ ioff (* icount (if u32? 4 2)))))
               (joff (and jofs jend))
               (end (if joff
                        ($align4 (+ joff (* vcount (if ju16? 8 4))))
                        jend))
               (plan (list layout vbase vcount stride ibase icount
                           u32? color voff ioff joff ju16?
                           material node skin-i targets
                           (and weights
                                (map $fl ($seq-list weights))))))
          (cons plan end)))))

  ;; ---- the node array --------------------------------------------
  ;; A node plan is #(name parent translation rotation scale), the
  ;; three transforms #f when the node does not give them (glTF's
  ;; own defaults then apply, which is also what (gfx gltf) reads).
  (define $node-keys '(translation rotation scale camera))

  (define ($nums who v n)
    (let ((x (cond ((vector? v) v)
                   ((and (pair? v) (list? v)) (list->vector v))
                   (else (error who "expected numbers" v)))))
      (unless (= (vector-length x) n)
        (error who "wrong number of components" v n))
      (let ((out (make-vector n 0.0)))
        (let loop ((i 0))
          (if (= i n)
              out
              (begin (vector-set! out i ($num who (vector-ref x i)))
                     (loop (+ i 1))))))))

  (define ($name who nm)
    (cond ((not nm) #f)
          ((string? nm) nm)
          ((symbol? nm) (symbol->string nm))
          (else (error who "a name is a string" nm))))

  ;; (name parent translation rotation scale), or the same three as
  ;; a key/value tail.  A transform is a vector or list of numbers
  ;; and an option key is a symbol, so the two forms never overlap.
  (define ($node-plan nd)
    (unless (and (list? nd) (>= (length nd) 2))
      (error 'glb-write! "a node is (name parent . transforms)" nd))
    (let* ((name ($name 'glb-write! (car nd)))
           (p0 (cadr nd))
           (parent (cond ((not p0) -1)
                         ((integer? p0) p0)
                         (else (error 'glb-write!
                                      "a node parent is an index" p0))))
           (rest (cddr nd))
           ;; the transforms may be written positionally, by key, or
           ;; positionally with a key tail after them: the first
           ;; symbol starts the tail, and nothing before it is a key
           (split (let cut ((l rest) (acc '()))
                    (cond ((null? l) (cons (reverse acc) '()))
                          ((symbol? (car l)) (cons (reverse acc) l))
                          (else (cut (cdr l) (cons (car l) acc))))))
           (pos (car split))
           (kv (cdr split)))
      ($check-options 'glb-write! $node-keys kv)
      (unless (<= (length pos) 3)
        (error 'glb-write!
               "a node is (name parent translation rotation scale . options)"
               nd))
      (let ((pick (lambda (key k)
                    (if (> (length pos) k)
                        (list-ref pos k)
                        ($option kv key #f)))))
        (let ((t (pick 'translation 0))
              (r (pick 'rotation 1))
              (s (pick 'scale 2))
              (cam ($option kv 'camera #f)))
          (set! cam ($index cam))
          (when (and cam (not (and (integer? cam) (exact? cam)
                                   (>= cam 0))))
            (error 'glb-write! "a node camera is an index" cam))
          (vector name (if (< parent 0) -1 parent)
                  (and t ($nums 'glb-write! t 3))
                  (and r ($nums 'glb-write! r 4))
                  (and s ($nums 'glb-write! s 3))
                  cam)))))

  ;; the one node this writer emitted before nodes were describable
  (define ($default-nodes) (vector (vector #f -1 #f #f #f #f)))

  (define ($nodes-plan ns)
    (if (not ns)
        ($default-nodes)
        (let ((l (cond ((and (pair? ns) (list? ns)) ns)
                       ((vector? ns) (vector->list ns))
                       (else (error 'glb-write!
                                    "'nodes takes a list of nodes" ns)))))
          (when (null? l)
            (error 'glb-write! "'nodes may not be empty" ns))
          (list->vector (map $node-plan l)))))

  ;; a parent index out of range, or a parent chain that closes on
  ;; itself, is a scene no walker terminates on -- caught here, not
  ;; in the reader
  (define ($check-nodes nds)
    (let ((n (vector-length nds)))
      (let loop ((i 0))
        (when (< i n)
          (let ((p (vector-ref (vector-ref nds i) 1)))
            (unless (and (integer? p) (>= p -1) (< p n))
              (error 'glb-write! "a node names a parent the file lacks" p))
            (when (= p i)
              (error 'glb-write! "a node is its own parent" i))
            ;; walking up cannot take more steps than there are
            ;; nodes unless the chain is a ring
            (let up ((k p) (steps 0))
              (when (>= k 0)
                (when (> steps n)
                  (error 'glb-write! "node parents form a cycle" i))
                (up (vector-ref (vector-ref nds k) 1) (+ steps 1)))))
          (loop (+ i 1))))))

  (define ($children nds)
    (let* ((n (vector-length nds))
           (kids (make-vector n '())))
      (let loop ((i (- n 1)))
        (when (>= i 0)
          (let ((p (vector-ref (vector-ref nds i) 1)))
            (when (>= p 0)
              (vector-set! kids p (cons i (vector-ref kids p)))))
          (loop (- i 1))))
      kids))

  (define ($roots nds)
    (let loop ((i (- (vector-length nds) 1)) (acc '()))
      (if (< i 0)
          (list->vector acc)
          (loop (- i 1)
                (if (< (vector-ref (vector-ref nds i) 1) 0)
                    (cons i acc)
                    acc)))))

  (define ($nodes-json nds mesh-of skin-of)
    (let ((kids ($children nds))
          (n (vector-length nds)))
      (let loop ((i 0) (acc '()))
        (if (= i n)
            (list->vector (reverse acc))
            (let* ((nd (vector-ref nds i))
                   (nm (vector-ref nd 0))
                   (t (vector-ref nd 2))
                   (r (vector-ref nd 3))
                   (s (vector-ref nd 4))
                   (ks (vector-ref kids i))
                   (o (append
                       (if nm (list (cons "name" nm)) '())
                       (if t (list (cons "translation" t)) '())
                       (if r (list (cons "rotation" r)) '())
                       (if s (list (cons "scale" s)) '())
                       (if (null? ks)
                           '()
                           (list (cons "children" (list->vector ks))))
                       (let ((m (assv i mesh-of)))
                         (if m (list (cons "mesh" (cdr m))) '()))
                       (let ((sk (assv i skin-of)))
                         (if sk (list (cons "skin" (cdr sk))) '()))
                       (let ((c (vector-ref nd 5)))
                         (if c (list (cons "camera" c)) '())))))
              (loop (+ i 1) (cons o acc)))))))

  ;; ---- the skin ---------------------------------------------------
  ;; A skin plan is #(joint-node-indices ibm-source).
  (define ($skin-plan sk nnodes)
    (and sk
         (begin
           (unless (and (list? sk) (>= (length sk) 1))
             (error 'glb-write!
                    "'skin is (joint-node-indices inverse-bind-matrices)"
                    sk))
           (let* ((js (let ((j (car sk)))
                        (cond ((vector? j) j)
                              ((and (pair? j) (list? j)) (list->vector j))
                              (else (error 'glb-write!
                                           "a skin needs joint node indices"
                                           j)))))
                  (nj (vector-length js))
                  (ibm (and (>= (length sk) 2)
                            (cadr sk)
                            ($src 'glb-write! (cadr sk)))))
             ($check-options 'glb-write! '()
                             (list-tail sk (min 2 (length sk))))
             (when (= nj 0)
               (error 'glb-write! "a skin needs at least one joint" sk))
             (let check ((i 0))
               (when (< i nj)
                 (let ((v (vector-ref js i)))
                   (unless (and (integer? v) (>= v 0) (< v nnodes))
                     (error 'glb-write!
                            "a skin names a node the file lacks" v)))
                 (check (+ i 1))))
             (when ibm ($src-check 'glb-write! ibm nj 16))
             (vector js ibm)))))

  (define ($skin-json skin ibm-acc)
    (append (list (cons "joints" (vector-ref skin 0)))
            (if ibm-acc (list (cons "inverseBindMatrices" ibm-acc)) '())))

  ;; ---- animations -------------------------------------------------
  ;; A channel plan is
  ;;   #(node path ncomp interpolation count cubic? times values)
  ;; and a clip plan is #(name channels).
  (define $chan-keys '(interpolation components))

  (define ($interp? x)
    (or (and (symbol? x) (memq x '(linear step cubic cubicspline)) #t)
        (and (string? x)
             (or (string=? x "LINEAR") (string=? x "STEP")
                 (string=? x "CUBICSPLINE")))))

  (define ($interp-name who x)
    (cond ((or (eq? x 'linear) (equal? x "LINEAR")) "LINEAR")
          ((or (eq? x 'step) (equal? x "STEP")) "STEP")
          ((or (eq? x 'cubic) (eq? x 'cubicspline) (equal? x "CUBICSPLINE"))
           "CUBICSPLINE")
          (else (error who "unknown interpolation" x))))

  (define ($path-name who p)
    (let ((s (cond ((symbol? p) (symbol->string p))
                   ((string? p) p)
                   (else (error who "a channel path is a name" p)))))
      (if (or (string=? s "translation") (string=? s "rotation")
              (string=? s "scale") (string=? s "weights"))
          s
          (error who "unknown channel path" p))))

  (define ($chan-plan ch nnodes)
    (unless (and (list? ch) (>= (length ch) 5))
      (error 'glb-write!
             "a channel is (node path times values count . options)" ch))
    (let* ((node (car ch))
           (path ($path-name 'glb-write! (cadr ch)))
           (tsrc ($src 'glb-write! (caddr ch)))
           (vsrc ($src 'glb-write! (cadddr ch)))
           (count (list-ref ch 4))
           (rest (list-tail ch 5))
           ;; the interpolation may ride in the sixth slot the way
           ;; glTF itself names it, or in the key/value tail; an
           ;; interpolation name is never an option key, so the two
           ;; do not collide
           (pos-i (and (pair? rest) ($interp? (car rest)) (car rest)))
           (opts (if pos-i (cdr rest) rest)))
      ($check-options 'glb-write! $chan-keys opts)
      (let* ((interp ($interp-name
                      'glb-write!
                      (if pos-i pos-i ($option opts 'interpolation 'linear))))
             (cubic? (string=? interp "CUBICSPLINE"))
             (ncomp (cond ((string=? path "rotation") 4)
                          ((string=? path "weights")
                           ($option opts 'components 1))
                          (else 3))))
        (unless (and (integer? node) (>= node 0) (< node nnodes))
          (error 'glb-write! "a channel names a node the file lacks" node))
        (unless (and (integer? count) (> count 0))
          (error 'glb-write! "a channel needs at least one keyframe" count))
        (unless (and (integer? ncomp) (> ncomp 0))
          (error 'glb-write!
                 "morph weights need a positive 'components" ncomp))
        ($src-check 'glb-write! tsrc count 1)
        ($src-check 'glb-write! vsrc (if cubic? (* 3 count) count) ncomp)
        (vector node path ncomp interp count cubic? tsrc vsrc))))

  (define ($chan-node c) (vector-ref c 0))
  (define ($chan-path c) (vector-ref c 1))
  (define ($chan-ncomp c) (vector-ref c 2))
  (define ($chan-interp c) (vector-ref c 3))
  (define ($chan-count c) (vector-ref c 4))
  (define ($chan-cubic? c) (vector-ref c 5))
  (define ($chan-times c) (vector-ref c 6))
  (define ($chan-values c) (vector-ref c 7))
  (define ($chan-elems c)
    (if ($chan-cubic? c) (* 3 ($chan-count c)) ($chan-count c)))

  (define ($clip-plan cl nnodes)
    (unless (and (list? cl) (>= (length cl) 2))
      (error 'glb-write! "a clip is (name channels)" cl))
    ($check-options 'glb-write! '() (cddr cl))
    (let* ((name ($name 'glb-write! (car cl)))
           (chans (cadr cl))
           (cs (cond ((and (pair? chans) (list? chans)) chans)
                     ((vector? chans) (vector->list chans))
                     (else (error 'glb-write!
                                  "a clip needs a list of channels" chans)))))
      (when (null? cs)
        (error 'glb-write! "a clip needs at least one channel" cl))
      (vector name (map (lambda (c) ($chan-plan c nnodes)) cs))))

  (define ($anims-plan as nnodes)
    (let ((l (cond ((not as) '())
                   ((and (pair? as) (list? as)) as)
                   ((null? as) '())
                   ((vector? as) (vector->list as))
                   (else (error 'glb-write!
                                "'anims takes a list of clips" as)))))
      (map (lambda (c) ($clip-plan c nnodes)) l)))

  ;; an animation input accessor must carry min and max, and a
  ;; sampler whose times go backwards has no reading at all -- both
  ;; answered by one scan of the times themselves
  (define ($times-bounds src count)
    (let ((t0 ($src-ref 'glb-write! src 0 0 1)))
      (let loop ((i 1) (mn t0) (mx t0) (prev t0))
        (if (= i count)
            (cons (vector mn) (vector mx))
            (let ((t ($src-ref 'glb-write! src i 0 1)))
              (when (fl<? t prev)
                (error 'glb-write! "keyframe times go backwards" prev t))
              (loop (+ i 1)
                    (if (fl<? t mn) t mn)
                    (if (fl<? mx t) t mx)
                    t))))))

  (define ($anims-json anims base)
    (let loop ((as anims) (b base) (acc '()))
      (if (null? as)
          (list->vector (reverse acc))
          (let* ((a (car as))
                 (cs (vector-ref a 1))
                 (n (length cs))
                 (smp (let s ((l cs) (k 0) (o '()))
                        (if (null? l)
                            (list->vector (reverse o))
                            (s (cdr l) (+ k 1)
                               (cons (list (cons "input" (+ b (* 2 k)))
                                           (cons "output" (+ b (* 2 k) 1))
                                           (cons "interpolation"
                                                 ($chan-interp (car l))))
                                     o)))))
                 (chs (let s ((l cs) (k 0) (o '()))
                        (if (null? l)
                            (list->vector (reverse o))
                            (s (cdr l) (+ k 1)
                               (cons (list
                                      (cons "sampler" k)
                                      (cons "target"
                                            (list (cons "node"
                                                        ($chan-node (car l)))
                                                  (cons "path"
                                                        ($chan-path
                                                         (car l))))))
                                     o))))))
            (loop (cdr as) (+ b (* 2 n))
                  (cons (append
                         (if (vector-ref a 0)
                             (list (cons "name" (vector-ref a 0)))
                             '())
                         (list (cons "samplers" smp)
                               (cons "channels" chs)))
                        acc))))))

  ;; ---- the blocks past the primitives ----------------------------
  ;; One blob = one bufferView = one accessor, in this order: the
  ;; skin's inverse binds, then every channel's times and values,
  ;; clip by clip.  Keeping the three in lockstep is what lets an
  ;; accessor index be an offset from a single base rather than a
  ;; number threaded through the walk.
  ;;   blob = #(byte-offset elements components source kind)
  (define ($blob-off b) (vector-ref b 0))
  (define ($blob-elems b) (vector-ref b 1))
  (define ($blob-ncomp b) (vector-ref b 2))
  (define ($blob-src b) (vector-ref b 3))
  (define ($blob-kind b) (vector-ref b 4))
  (define ($blob-bytes b) (* (vector-ref b 1) (vector-ref b 2) 4))

  ;; `skin` and `skins` are one option spelled two ways: a file with
  ;; one skin written the old way and the same file written as a
  ;; one-element `skins` come out as the same bytes.  Given both,
  ;; there is no answer to which list is the file's.
  (define ($skins-plan one many nnodes)
    (when (and one many)
      (error 'glb-write! "'skin and 'skins are the same option" many))
    (cond ((and many (not (null? many)) (not (equal? many '#())))
           (let ((l (cond ((and (pair? many) (list? many)) many)
                          ((vector? many) (vector->list many))
                          (else (error 'glb-write!
                                       "'skins takes a list of skins"
                                       many)))))
             (list->vector
              (map (lambda (sk) ($skin-plan sk nnodes)) l))))
          (one (vector ($skin-plan one nnodes)))
          (else (vector))))

  ;; The morph deltas a file carries, as ONE walk: primitive by
  ;; primitive, target by target, and within a target position then
  ;; normal then tangent, skipping the ones a target omits.  Both
  ;; the blob list and the accessor indices the targets array names
  ;; are derived from this, so the two cannot walk in different
  ;; orders -- the failure that would put a normal's bytes under a
  ;; position's accessor.
  ;;   -> per plan: per target: ((glTF-name . source) ...)
  (define ($morph-slots plans)
    (map (lambda (p)
           (map (lambda (t)
                  (let loop ((c 0) (acc '()))
                    (if (= c 3)
                        (reverse acc)
                        (loop (+ c 1)
                              (let ((src (vector-ref t c)))
                                (if src
                                    (cons (cons (list-ref '("POSITION"
                                                            "NORMAL"
                                                            "TANGENT")
                                                          c)
                                                src)
                                          acc)
                                    acc))))))
                ($plan-targets p)))
         plans))

  ;; the accessor index of every morph slot, numbered from base in
  ;; the same walk order
  (define ($morph-accs slots base)
    (let plan ((ss slots) (n base) (out '()))
      (if (null? ss)
          (reverse out)
          (let tgt ((ts (car ss)) (n n) (tout '()))
            (if (null? ts)
                (plan (cdr ss) n (cons (reverse tout) out))
                (let comp ((cs (car ts)) (n n) (cout '()))
                  (if (null? cs)
                      (tgt (cdr ts) n (cons (reverse cout) tout))
                      (comp (cdr cs) (+ n 1)
                            (cons (cons (caar cs) n) cout)))))))))

  ;; An image is bytes, not numbers: it gets a bufferView and NO
  ;; accessor.  That is why images are placed after every blob and
  ;; numbered after every blob's view -- an accessor index and a view
  ;; index stop agreeing at the first image otherwise.
  ;;   image = #(offset length source mime)
  (define ($image-plan im)
    (unless (and (list? im) (>= (length im) 2))
      (error 'glb-write!
             "an image is (bytes mime) or (base length mime)" im))
    (let ((mime (car (reverse im))))
      (unless (string? mime)
        (error 'glb-write! "an image needs a mime type" im))
      (cond ((bytevector? (car im))
             (unless (= (length im) 2)
               (error 'glb-write! "an image is (bytevector mime)" im))
             (vector 0 (bytevector-length (car im)) (car im) mime))
            (else
             (unless (= (length im) 3)
               (error 'glb-write! "an image is (base length mime)" im))
             (let ((base (car im)) (len (cadr im)))
               (unless (and (integer? base) (exact? base) (>= base 0))
                 (error 'glb-write! "an image base is a staging address"
                        base))
               (unless (and (integer? len) (> len 0))
                 (error 'glb-write! "an image needs its byte length" len))
               (vector 0 len base mime))))))

  ;; an empty list is the option left out: a re-export recipe that
  ;; maps over an asset without images or skins hands one in, and
  ;; refusing it would make the recipe depend on what the asset has
  (define ($images-plan ims)
    (cond ((not ims) '())
          ((null? ims) '())
          ((and (pair? ims) (list? ims)) (map $image-plan ims))
          ((vector? ims) ($images-plan (vector->list ims)))
          (else (error 'glb-write! "'images is a list of images" ims))))

  (define ($place-images ims at)
    (let loop ((l ims) (at at) (acc '()))
      (if (null? l)
          (cons (reverse acc) at)
          (let ((im (car l)))
            (loop (cdr l) ($align4 (+ at (vector-ref im 1)))
                  (cons (vector at (vector-ref im 1)
                                (vector-ref im 2) (vector-ref im 3))
                        acc))))))

  (define ($extra-specs skins anims slots plans)
    (append
     (let skin ((i 0) (acc '()))
       (if (= i (vector-length skins))
           (reverse acc)
           (let ((sk (vector-ref skins i)))
             (skin (+ i 1)
                   (if (vector-ref sk 1)
                       (cons (list (vector-ref sk 1)
                                   (vector-length (vector-ref sk 0))
                                   16 'ibm)
                             acc)
                       acc)))))
     (let clip ((as anims) (acc '()))
       (if (null? as)
           (reverse acc)
           (clip (cdr as)
                 (let ch ((cs (vector-ref (car as) 1)) (acc acc))
                   (if (null? cs)
                       acc
                       (ch (cdr cs)
                           (cons (list ($chan-values (car cs))
                                       ($chan-elems (car cs))
                                       ($chan-ncomp (car cs))
                                       ;; morph weights are the one
                                       ;; output glTF names as loose
                                       ;; scalars rather than as
                                       ;; vectors: same bytes, a
                                       ;; different accessor over them
                                       (if (string=? ($chan-path (car cs))
                                                     "weights")
                                           'weights
                                           'values))
                                 (cons (list ($chan-times (car cs))
                                             ($chan-count (car cs)) 1 'times)
                                       acc))))))))
     ;; the morph deltas come last, so adding them cannot renumber a
     ;; view or an accessor any older file already had
     (let plan ((ss slots) (ps plans) (acc '()))
       (if (null? ss)
           (reverse acc)
           (plan (cdr ss) (cdr ps)
                 (let tgt ((ts (car ss)) (acc acc))
                   (if (null? ts)
                       acc
                       (tgt (cdr ts)
                            (let comp ((cs (car ts)) (acc acc))
                              (if (null? cs)
                                  acc
                                  (comp (cdr cs)
                                        (cons (list (cdar cs)
                                                    ($plan-vcount (car ps))
                                                    3
                                                    ;; the spec wants
                                                    ;; bounds on every
                                                    ;; POSITION
                                                    ;; accessor, a
                                                    ;; target's
                                                    ;; included
                                                    (if (string=?
                                                         (caar cs)
                                                         "POSITION")
                                                        'morph-pos
                                                        'morph))
                                              acc))))))))))))

  (define ($place specs at)
    (let loop ((ss specs) (at at) (acc '()))
      (if (null? ss)
          (cons (reverse acc) at)
          (let ((s (car ss)))
            (loop (cdr ss)
                  ($align4 (+ at (* (cadr s) (caddr s) 4)))
                  (cons (vector at (cadr s) (caddr s) (car s) (cadddr s))
                        acc))))))

  (define ($acc-type-name n)
    (cond ((= n 1) "SCALAR")
          ((= n 2) "VEC2")
          ((= n 3) "VEC3")
          ((= n 4) "VEC4")
          ((= n 16) "MAT4")
          (else (error 'glb-write! "no accessor type is this wide" n))))

  ;; ---- the JSON chunk --------------------------------------------
  ;; bufferViews and accessors are numbered as they are emitted: a
  ;; primitive contributes its vertex view, then its index view when
  ;; it has one, then its joint view when it has one; the accessors
  ;; run attributes-then-indices in layout order.
  (define ($views plans)
    (let loop ((ps plans) (acc '()))
      (if (null? ps)
          (reverse acc)
          (let* ((p (car ps))
                 (vb (list (cons "buffer" 0)
                           (cons "byteOffset" ($plan-voff p))
                           (cons "byteLength" ($plan-vbytes p))
                           (cons "byteStride" ($plan-stride p))
                           (cons "target" 34962)))   ; ARRAY_BUFFER
                 (ib (list (cons "buffer" 0)
                           (cons "byteOffset" ($plan-ioff p))
                           (cons "byteLength" ($plan-ibytes p))
                           (cons "target" 34963)))   ; ELEMENT_ARRAY
                 (jb (and ($plan-joff p)
                          (list (cons "buffer" 0)
                                (cons "byteOffset" ($plan-joff p))
                                (cons "byteLength" ($plan-jbytes p))
                                (cons "target" 34962)))))
            (loop (cdr ps)
                  (let* ((a (cons vb acc))
                         (a (if (= ($plan-icount p) 0) a (cons ib a))))
                    (if jb (cons jb a) a)))))))

  (define ($blob-views blobs)
    (map (lambda (b)
           (list (cons "buffer" 0)
                 (cons "byteOffset" ($blob-off b))
                 (cons "byteLength" ($blob-bytes b))))
         blobs))

  ;; how many views a primitive owns, and where its first one sits
  (define ($plan-views p)
    (+ 1 (if (= ($plan-icount p) 0) 0 1) (if ($plan-joff p) 1 0)))

  (define ($view-bases plans)
    (let loop ((ps plans) (n 0) (acc '()))
      (if (null? ps)
          (reverse acc)
          (loop (cdr ps) (+ n ($plan-views (car ps))) (cons n acc)))))

  (define ($view-count plans)
    (let loop ((ps plans) (n 0))
      (if (null? ps) n (loop (cdr ps) (+ n ($plan-views (car ps)))))))

  (define ($accessor bv off ct count type bounds)
    (append (list (cons "bufferView" bv)
                  (cons "byteOffset" off)
                  (cons "componentType" ct)
                  (cons "count" count)
                  (cons "type" type))
            (if bounds
                (list (cons "min" (car bounds)) (cons "max" (cdr bounds)))
                '())))

  (define ($blob-accessor b bv)
    (if (eq? ($blob-kind b) 'weights)
        ;; one SCALAR per component per key, which is how glTF says
        ;; a morph-weight sampler names the very same float stream
        ($accessor bv 0 5126 (* ($blob-elems b) ($blob-ncomp b))
                   "SCALAR" #f)
        ($accessor bv 0 5126 ($blob-elems b)
                   ($acc-type-name ($blob-ncomp b))
                   (cond ((eq? ($blob-kind b) 'times)
                          ($times-bounds ($blob-src b) ($blob-elems b)))
                         ((eq? ($blob-kind b) 'morph-pos)
                          ($src-bounds ($blob-src b) ($blob-elems b)
                                       ($blob-ncomp b)))
                         (else #f)))))

  ;; min/max over a source, component by component -- the same thing
  ;; $pos-bounds computes over an interleave, for data that arrives
  ;; as a source instead
  (define ($src-bounds src elems ncomp)
    (let ((mn (make-vector ncomp 0.0))
          (mx (make-vector ncomp 0.0)))
      (let seed ((c 0))
        (when (< c ncomp)
          (let ((v ($src-ref 'glb-write! src 0 c ncomp)))
            (vector-set! mn c v)
            (vector-set! mx c v))
          (seed (+ c 1))))
      (let e ((i 1))
        (when (< i elems)
          (let comp ((c 0))
            (when (< c ncomp)
              (let ((x ($src-ref 'glb-write! src i c ncomp)))
                (when (fl<? x (vector-ref mn c)) (vector-set! mn c x))
                (when (fl<? (vector-ref mx c) x) (vector-set! mx c x)))
              (comp (+ c 1))))
          (e (+ i 1))))
      (cons mn mx)))

  ;; accessors and the mesh primitives together: both are driven by
  ;; the same walk, so an attribute can never be given an accessor
  ;; index the primitive does not name
  (define ($mesh-json plans nmat maccs)
    (let loop ((ps plans) (bvs ($view-bases plans)) (ms maccs)
               (acc-n 0) (mat-n 0)
               (accs '()) (prims '()) (mats '()))
      (if (null? ps)
          (list (reverse accs)
                (reverse prims)
                (list->vector (reverse mats)))
          (let* ((p (car ps))
                 (bv (car bvs))
                 (layout ($plan-layout p))
                 (stride ($plan-stride p))
                 (vcount ($plan-vcount p))
                 (indexed (> ($plan-icount p) 0))
                 (jview (and ($plan-joff p) (+ bv (if indexed 2 1)))))
            (let attr ((l layout) (off 0) (n acc-n)
                       (as accs) (names '()))
              (if (not (null? l))
                  (let* ((e ($attr 'glb-write! (car l)))
                         (bounds
                          (and (eq? (car l) 'position)
                               ($pos-bounds ($plan-vbase p) vcount
                                            stride off)))
                         ;; JOINTS_0 is the one attribute described
                         ;; somewhere other than where it lies: glTF
                         ;; wants integers, the interleave has floats
                         (acc (if (eq? (car l) 'joints)
                                  ($accessor jview 0
                                             (if ($plan-ju16? p) 5123 5121)
                                             vcount ($attr-type e) #f)
                                  ($accessor bv off 5126 vcount
                                             ($attr-type e) bounds))))
                    (attr (cdr l)
                          (+ off ($attr-bytes e))
                          (+ n 1)
                          (cons acc as)
                          (cons (cons ($attr-name e) n) names)))
                  ;; indices, then the primitive that names it all
                  (let* ((as2 (if indexed
                                  (cons ($accessor
                                         (+ bv 1) 0
                                         (if ($plan-u32? p) 5125 5123)
                                         ($plan-icount p) "SCALAR" #f)
                                        as)
                                  as))
                         (col ($plan-color p))
                         ;; a named material is an index into the
                         ;; file's own array; a colour asks for one,
                         ;; and those are appended after it
                         (mi (cond (($plan-material p))
                                   (col (+ nmat mat-n))
                                   (else #f)))
                         (tgts (car ms))
                         (prim (append
                                (list (cons "attributes" (reverse names)))
                                (if indexed (list (cons "indices" n)) '())
                                (if mi (list (cons "material" mi)) '())
                                (if (null? tgts)
                                    '()
                                    (list (cons "targets"
                                                (list->vector tgts))))
                                (list (cons "mode" 4)))))  ; TRIANGLES
                    (loop (cdr ps) (cdr bvs) (cdr ms)
                          (if indexed (+ n 1) n)
                          (if col (+ mat-n 1) mat-n)
                          as2
                          (cons prim prims)
                          (if col
                              (cons (list
                                     (cons "pbrMetallicRoughness"
                                           (list (cons "baseColorFactor"
                                                       col))))
                                    mats)
                              mats)))))))))

  ;; ---- the arrays a material model needs -------------------------
  (define ($opt-key name v) (if v (list (cons name v)) '()))

  (define ($samplers-json ss)
    (list->vector
     (map (lambda (sm)
            (unless (and (list? sm) (= (length sm) 4))
              (error 'glb-write!
                     "a sampler is (mag min wrap-s wrap-t)" sm))
            ;; #f is the key left out, which is not the same as a
            ;; value: glTF reads an absent filter as "the runtime's",
            ;; and writing one would be inventing a decision
            (append ($opt-key "magFilter" (car sm))
                    ($opt-key "minFilter" (cadr sm))
                    ($opt-key "wrapS" (caddr sm))
                    ($opt-key "wrapT" (cadddr sm))))
          ss)))

  (define ($textures-json ts)
    (list->vector
     (map (lambda (t)
            (unless (pair? t)
              (error 'glb-write! "a texture is (image . sampler)" t))
            (append (list (cons "source" (car t)))
                    ($opt-key "sampler" (cdr t))))
          ts)))

  ;; one material texture slot: (texture texcoord factor).  texCoord 0
  ;; and a factor of 1 are the spec's defaults, so they are left out
  ;; -- a re-export of a file that omitted them omits them again.
  (define ($texref-json name r scalar)
    (unless (and (list? r) (= (length r) 3))
      (error 'glb-write!
             "a texture slot is (texture texcoord factor)" r))
    (cons name
          (append (list (cons "index" (car r)))
                  (if (and (cadr r) (> (cadr r) 0))
                      (list (cons "texCoord" (cadr r)))
                      '())
                  (if (and scalar (caddr r)
                           (not (= ($fl (caddr r)) 1.0)))
                      (list (cons scalar ($fl (caddr r))))
                      '()))))

  (define ($materials-json ms)
    (list->vector
     (map (lambda (m)
            (unless (and (list? m) (= (length m) 8))
              (error 'glb-write!
                     "a material is (color mr emissive base mr normal emissive occlusion)"
                     m))
            (let* ((mr (cadr m))
                   (emi (caddr m))
                   (slot (lambda (k) (list-ref m k)))
                   ;; #f is the key left out, which a file that
                   ;; never wrote one has to come back as: glTF's
                   ;; default is 1,1,1,1, and writing that instead
                   ;; would turn an absent key into a present one
                   (pbr (append
                         (if (car m)
                             (list (cons "baseColorFactor"
                                         ($rgba 'glb-write! (car m))))
                             '())
                         (if (slot 3)
                             (list ($texref-json "baseColorTexture"
                                                 (slot 3) #f))
                             '())
                         (list (cons "metallicFactor" ($fl (car mr)))
                               (cons "roughnessFactor" ($fl (cdr mr))))
                         (if (slot 4)
                             (list ($texref-json
                                    "metallicRoughnessTexture"
                                    (slot 4) #f))
                             '()))))
              (unless (pair? mr)
                (error 'glb-write!
                       "a material's metallic-roughness is a pair" mr))
              (append
               (list (cons "pbrMetallicRoughness" pbr))
               (if (slot 5)
                   (list ($texref-json "normalTexture" (slot 5) "scale"))
                   '())
               (if (slot 6)
                   (list ($texref-json "emissiveTexture" (slot 6) #f))
                   '())
               (if (slot 7)
                   (list ($texref-json "occlusionTexture" (slot 7)
                                       "strength"))
                   '())
               (if emi
                   (list (cons "emissiveFactor"
                               ($nums 'glb-write! emi 3)))
                   '()))))
          ms)))

  (define ($cameras-json cs)
    (list->vector
     (map (lambda (c)
            (unless (and (list? c) (= (length c) 5))
              (error 'glb-write!
                     "a camera is (kind a b znear zfar)" c))
            (let ((k (lambda (name v)
                       (if v (list (cons name ($fl v))) '()))))
              (cond
               ((eq? (car c) 'perspective)
                (list (cons "type" "perspective")
                      (cons "perspective"
                            (append (k "aspectRatio" (caddr c))
                                    (k "yfov" (cadr c))
                                    (k "zfar" (list-ref c 4))
                                    (k "znear" (cadddr c))))))
               ((eq? (car c) 'orthographic)
                (list (cons "type" "orthographic")
                      (cons "orthographic"
                            (append (k "xmag" (cadr c))
                                    (k "ymag" (caddr c))
                                    (k "zfar" (list-ref c 4))
                                    (k "znear" (cadddr c))))))
               (else (error 'glb-write!
                            "a camera is perspective or orthographic"
                            (car c))))))
          cs)))

  (define ($images-json ims view0)
    (list->vector
     (let loop ((l ims) (k 0) (acc '()))
       (if (null? l)
           (reverse acc)
           (loop (cdr l) (+ k 1)
                 (cons (list (cons "bufferView" (+ view0 k))
                             (cons "mimeType" (vector-ref (car l) 3)))
                       acc))))))

  (define ($image-views ims)
    (map (lambda (im)
           (list (cons "buffer" 0)
                 (cons "byteOffset" (vector-ref im 0))
                 (cons "byteLength" (vector-ref im 1))))
         ims))

  (define ($skins-json skins ibm0)
    ;; the inverse-bind accessors were numbered in skins order,
    ;; skipping the skins that gave none -- the same walk as
    ;; $extra-specs, counted the same way
    (let loop ((i 0) (n ibm0) (acc '()))
      (if (= i (vector-length skins))
          (list->vector (reverse acc))
          (let* ((sk (vector-ref skins i))
                 (has (and (vector-ref sk 1) #t)))
            (loop (+ i 1) (if has (+ n 1) n)
                  (cons ($skin-json sk (and has n)) acc))))))

  ;; primitives grouped into meshes by the node that carries them, in
  ;; the order those nodes first appear.  A file where no primitive
  ;; names a node is ONE mesh on mesh-node -- which is every file
  ;; this writer produced before meshes could be split, byte for byte.
  (define ($mesh-groups plans mesh-node)
    (let* ((pairs (let loop ((ps plans) (i 0) (acc '()))
                    (if (null? ps)
                        (reverse acc)
                        (loop (cdr ps) (+ i 1)
                              (cons (cons (or ($plan-node (car ps))
                                              mesh-node)
                                          i)
                                    acc)))))
           (order (let loop ((l pairs) (acc '()))
                    (cond ((null? l) (reverse acc))
                          ((memv (caar l) acc) (loop (cdr l) acc))
                          (else (loop (cdr l) (cons (caar l) acc)))))))
      (map (lambda (nd)
             (cons nd
                   (let pick ((l pairs) (acc '()))
                     (cond ((null? l) (reverse acc))
                           ((eqv? (caar l) nd)
                            (pick (cdr l) (cons (cdar l) acc)))
                           (else (pick (cdr l) acc))))))
           order)))

  ;; glTF puts the morph weights on the MESH, so primitives sharing a
  ;; node share them: they must agree on how many targets there are
  ;; and on the weights themselves.  Taking the first primitive's and
  ;; ignoring the rest would write a file whose other primitives are
  ;; posed by weights that were never meant for them.
  (define ($group-weights plans idxs)
    (let* ((of (lambda (i) (list-ref plans i)))
           (n0 (length ($plan-targets (of (car idxs))))))
      (let loop ((l (cdr idxs)) (ws ($plan-weights (of (car idxs)))))
        (if (null? l)
            ws
            (let* ((p (of (car l)))
                   (n (length ($plan-targets p)))
                   (w ($plan-weights p)))
              (unless (= n n0)
                (error 'glb-write!
                       "primitives on one node have different morph target counts"
                       n0 n))
              (cond ((not w) (loop (cdr l) ws))
                    ((not ws) (loop (cdr l) w))
                    ((equal? w ws) (loop (cdr l) ws))
                    (else
                     (error 'glb-write!
                            "primitives on one node give different morph weights"
                            ws w))))))))

  ;; every primitive on one node wears one skin: glTF puts the skin on
  ;; the NODE, so a mesh has nowhere to hold a second one
  (define ($group-skin plans idxs skins)
    (let loop ((l idxs) (found 'none))
      (if (null? l)
          (if (eq? found 'none) #f found)
          (let ((s ($plan-skin (list-ref plans (car l)))))
            (cond ((eq? found 'none) (loop (cdr l) s))
                  ((eqv? found s) (loop (cdr l) found))
                  (else (error 'glb-write!
                               "primitives on one node name different skins"
                               found s)))))))

  (define ($json plans binlen nds mesh-node skins anims blobs imgs
                 arrays slots)
    (let* ((groups ($mesh-groups plans mesh-node))
           (nmat (length ($option arrays 'materials '())))
           ;; how many accessors sit ahead of the morph deltas: the
           ;; primitives', then the inverse binds, then the animation
           ;; samplers.  Counted from the blob list itself, so the
           ;; number cannot drift from the order they were placed in.
           (nblob (length blobs))
           (kind-count
            (lambda (ks)
              (let loop ((l blobs) (n 0))
                (cond ((null? l) n)
                      ((memq ($blob-kind (car l)) ks)
                       (loop (cdr l) (+ n 1)))
                      (else (loop (cdr l) n))))))
           (n-ibm (kind-count '(ibm)))
           (n-anim (kind-count '(times values weights)))
           ;; the primitives' own accessors have to be counted
           ;; before the morph ones can be numbered, and the count
           ;; comes from the SAME walk that emits them -- a second
           ;; implementation of "how many accessors does a primitive
           ;; own" is exactly the thing that would drift
           (parts0 ($mesh-json plans nmat
                               (map (lambda (p) '()) plans)))
           (acc0 (length (car parts0)))
           (maccs ($morph-accs slots (+ acc0 n-ibm n-anim)))
           (parts ($mesh-json plans nmat maccs))
           (accs (car parts))
           (prims (cadr parts))
           (mats (caddr parts))
           (view0 ($view-count plans))
           ;; a group's skin: the one its primitives name, or -- for
           ;; a file written the old way, with no per-primitive skin
           ;; at all -- the file's first, exactly where this writer
           ;; used to put it
           (group-skin
            (lambda (idxs)
              (let ((named ($group-skin plans idxs skins)))
                (or named
                    (and (> (vector-length skins) 0)
                         (let any ((l idxs))
                           (cond ((null? l) #f)
                                 (($plan-joff (list-ref plans (car l))) 0)
                                 (else (any (cdr l))))))))))
           (mesh-of (let loop ((gs groups) (k 0) (acc '()))
                      (if (null? gs)
                          (reverse acc)
                          (loop (cdr gs) (+ k 1)
                                (cons (cons (caar gs) k) acc)))))
           (skin-of (let loop ((gs groups) (acc '()))
                      (if (null? gs)
                          (reverse acc)
                          (loop (cdr gs)
                                (let ((sk (group-skin (cdar gs))))
                                  (if sk
                                      (cons (cons (caar gs) sk) acc)
                                      acc))))))
           (meshes
            (list->vector
             (map (lambda (g)
                    (let ((ws ($group-weights plans (cdr g))))
                      (append
                       (list (cons "primitives"
                                   (list->vector
                                    (map (lambda (i) (list-ref prims i))
                                         (cdr g)))))
                       (if ws
                           (list (cons "weights" (list->vector ws)))
                           '()))))
                  groups)))
           (extra (let loop ((bs blobs) (k 0) (acc '()))
                    (if (null? bs)
                        (reverse acc)
                        (loop (cdr bs) (+ k 1)
                              (cons ($blob-accessor (car bs) (+ view0 k))
                                    acc)))))
           (user (lambda (key) ($option arrays key '())))
           ;; the file's own materials first, then the ones a
           ;; primitive's `color` asked for -- which is why a colour
           ;; material's index counts from the end of the array
           (all-mats (append (vector->list
                              ($materials-json (user 'materials)))
                             (vector->list mats))))
      (json->string
       (append
        (list (cons "asset"
                    (list (cons "version" "2.0")
                          (cons "generator" "goeteia (gfx glb)")))
              (cons "scene" 0)
              (cons "scenes" (vector (list (cons "nodes" ($roots nds)))))
              (cons "nodes" ($nodes-json nds mesh-of skin-of))
              (cons "meshes" meshes))
        (if (= (vector-length skins) 0)
            '()
            (list (cons "skins" ($skins-json skins acc0))))
        (if (null? anims)
            '()
            (list (cons "animations"
                        ($anims-json anims (+ acc0 n-ibm)))))
        (if (null? (user 'cameras))
            '()
            (list (cons "cameras" ($cameras-json (user 'cameras)))))
        (if (null? all-mats)
            '()
            (list (cons "materials" (list->vector all-mats))))
        (if (null? (user 'textures))
            '()
            (list (cons "textures" ($textures-json (user 'textures)))))
        (if (null? (user 'samplers))
            '()
            (list (cons "samplers" ($samplers-json (user 'samplers)))))
        (if (null? imgs)
            '()
            (list (cons "images" ($images-json imgs (+ view0 nblob)))))
        (list (cons "buffers"
                    (vector (list (cons "byteLength" binlen))))
              (cons "bufferViews"
                    (list->vector (append ($views plans)
                                          ($blob-views blobs)
                                          ($image-views imgs))))
              (cons "accessors" (list->vector (append accs extra))))))))

  ;; ---- the BIN chunk ---------------------------------------------
  (define ($joints-write! data p)
    (let ((off ($plan-joff p))
          (u16? ($plan-ju16? p))
          (jo (glb-offset ($plan-layout p) 'joints))
          (stride ($plan-stride p))
          (vbase ($plan-vbase p))
          (vcount ($plan-vcount p)))
      (let vert ((v 0))
        (when (< v vcount)
          (let comp ((c 0))
            (when (< c 4)
              (let ((n (%fl->fx
                        (%mem-f32-ref
                         (+ vbase (* v stride) jo (* 4 c))))))
                (if u16?
                    ($u16! (+ data off (* v 8) (* c 2)) n)
                    (%mem-u8-set! (+ data off (* v 4) c) n)))
              (comp (+ c 1))))
          (vert (+ v 1))))))

  (define ($blob-write! data b)
    (let ((off ($blob-off b))
          (elems ($blob-elems b))
          (ncomp ($blob-ncomp b))
          (src ($blob-src b)))
      (let e ((i 0))
        (when (< i elems)
          (let c ((j 0))
            (when (< j ncomp)
              (%mem-f32-set! (+ data off (* 4 (+ (* i ncomp) j)))
                             ($src-ref 'glb-write! src i j ncomp))
              (c (+ j 1))))
          (e (+ i 1))))))

  ;; ---- the container ---------------------------------------------
  (define $top-keys '(nodes mesh-node skin anims
                      images samplers textures materials cameras skins))

  (define (glb-write! prims . opts)
    (when (or (not (list? prims)) (null? prims))
      (error 'glb-write! "no primitives to write" prims))
    ($check-options 'glb-write! $top-keys opts)
    (let* ((nds ($nodes-plan ($option opts 'nodes #f)))
           (nnodes (vector-length nds))
           ;; an index has to be EXACT to be looked up: 0.0 passes
           ;; integer? and then misses every eqv? on 0, which is how
           ;; a mesh silently failed to reach its node.  The old
           ;; single-mesh path compared with = and never saw it.
           (mesh-node ($index ($option opts 'mesh-node 0)))
           (skins ($skins-plan ($option opts 'skin #f)
                               ($option opts 'skins #f) nnodes))
           (imgs ($images-plan ($option opts 'images #f)))
           (anims ($anims-plan ($option opts 'anims '()) nnodes)))
      ($check-nodes nds)
      (unless (and (integer? mesh-node) (>= mesh-node 0)
                   (< mesh-node nnodes))
        (error 'glb-write! "'mesh-node names a node the file lacks"
               mesh-node))
      (let* ((planned
              (let loop ((ds prims) (at 0) (acc '()))
                (if (null? ds)
                    (cons (reverse acc) at)
                    (let ((r ($plan (car ds) at skins mesh-node nnodes)))
                      (loop (cdr ds) (cdr r) (cons (car r) acc))))))
             (plans (car planned))
             (slots ($morph-slots plans))
             (placed ($place ($extra-specs skins anims slots plans)
                             (cdr planned)))
             (blobs (car placed))
             ;; images are bytes with no accessor, so they are placed
             ;; last -- after every block an accessor describes
             (imaged ($place-images imgs (cdr placed)))
             (images (car imaged))
             (binlen (cdr imaged))          ; already a multiple of 4
             (json ($json plans binlen nds mesh-node skins anims blobs
                          images opts slots))
             (jlen (string-length json))
             (jpad (remainder (- 4 (remainder jlen 4)) 4))
             (total (+ 12 8 jlen jpad 8 binlen))
             (out (fx-alloc! total)))
        ($u32! out #x46546C67)               ; "glTF"
        ($u32! (+ out 4) 2)                  ; version
        ($u32! (+ out 8) total)
        ($u32! (+ out 12) (+ jlen jpad))
        ($u32! (+ out 16) #x4E4F534A)        ; "JSON"
        (let ((at (+ out 20)))
          (let ((i 0))
            (string-for-each
             (lambda (ch)
               (%mem-u8-set! (+ at i) (char->integer ch))
               (set! i (+ i 1)))
             json))
          ;; the JSON chunk pads with spaces, the BIN chunk with zeros
          (let pad ((k 0))
            (when (< k jpad)
              (%mem-u8-set! (+ at jlen k) 32)
              (pad (+ k 1)))))
        (let ((bin (+ out 20 jlen jpad)))
          ($u32! bin binlen)
          ($u32! (+ bin 4) #x004E4942)       ; "BIN\0"
          (let ((data (+ bin 8)))
            ;; every gap between blocks is padding, and padding that
            ;; carries whatever staging held before is not reproducible
            ($fill0! data binlen)
            (let block ((ps plans))
              (unless (null? ps)
                (let ((p (car ps)))
                  ($copy! (+ data ($plan-voff p)) ($plan-vbase p)
                          ($plan-vbytes p))
                  (when (> ($plan-icount p) 0)
                    ($copy! (+ data ($plan-ioff p)) ($plan-ibase p)
                            ($plan-ibytes p)))
                  (when ($plan-joff p)
                    ($joints-write! data p)))
                (block (cdr ps))))
            (for-each (lambda (b) ($blob-write! data b)) blobs)
            ;; image bytes go out as they came in: a PNG is not
            ;; numbers, and running it through the float path would
            ;; rewrite it
            (for-each
             (lambda (im)
               (let ((at (+ data (vector-ref im 0)))
                     (len (vector-ref im 1))
                     (src (vector-ref im 2)))
                 (if (bytevector? src)
                     (let copy ((i 0))
                       (when (< i len)
                         (%mem-u8-set! (+ at i) (bytevector-u8-ref src i))
                         (copy (+ i 1))))
                     ($copy! at src len))))
             images)))
        (cons out total))))
  )
