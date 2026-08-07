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
;; interleave: position normal uv tangent color joints weights, each
;; float32 (12/12/8/16/16/16/16 bytes).  vbase points at vertex 0;
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
;;
;; glb-write! itself takes a key/value tail as well, for everything
;; that is not one primitive's vertices:
;;
;;   (glb-write! prims 'nodes ns 'mesh-node k 'skin sk 'anims as)
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
;; block, one accessor per attribute plus one per index array, one
;; mesh holding every primitive, the node array, one scene, and --
;; when asked for -- one skin and the animations.  POSITION carries
;; the min and max the specification requires, computed from the
;; data; so does every animation input.
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
;; and weights) gltf-parse reproduces the vertex bytes exactly.
;; Other layouts are written faithfully but come back canonicalized
;; -- the loader always gives a primitive a normal (+y when the file
;; has none) and always carries a uv slot once anything past normal
;; is present, so (position uv) is written as POSITION+TEXCOORD_0
;; and read back as position normal uv.
;;
;; Not written yet: morph targets, textures, cameras, materials
;; beyond a base colour, and more than one skin.
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
  (define ($src-check who x elems ncomp)
    (when (vector? x)
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
    (if (vector? x)
        ($elem-ref who (vector-ref x e) c)
        (%mem-f32-ref (+ x (* 4 (+ (* e ncomp) c))))))

  ;; ---- the primitive descriptor ----------------------------------
  (define $option-keys '(color index-u32? stride joints-u16?))

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

  (define ($plan desc at njoints)
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
                      (and c ($rgba 'glb-write! c)))))
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
                           u32? color voff ioff joff ju16?)))
          (cons plan end)))))

  ;; ---- the node array --------------------------------------------
  ;; A node plan is #(name parent translation rotation scale), the
  ;; three transforms #f when the node does not give them (glTF's
  ;; own defaults then apply, which is also what (gfx gltf) reads).
  (define $node-keys '(translation rotation scale))

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
           (kv? (and (pair? rest) (symbol? (car rest)))))
      (when kv? ($check-options 'glb-write! $node-keys rest))
      (unless (or kv? (<= (length rest) 3))
        (error 'glb-write!
               "a node is (name parent translation rotation scale)" nd))
      (let ((pick (lambda (key k)
                    (if kv?
                        ($option rest key #f)
                        (and (> (length rest) k) (list-ref rest k))))))
        (let ((t (pick 'translation 0))
              (r (pick 'rotation 1))
              (s (pick 'scale 2)))
          (vector name (if (< parent 0) -1 parent)
                  (and t ($nums 'glb-write! t 3))
                  (and r ($nums 'glb-write! r 4))
                  (and s ($nums 'glb-write! s 3)))))))

  ;; the one node this writer emitted before nodes were describable
  (define ($default-nodes) (vector (vector #f -1 #f #f #f)))

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

  (define ($nodes-json nds mesh-node skinned?)
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
                       (if (= i mesh-node) (list (cons "mesh" 0)) '())
                       (if (and (= i mesh-node) skinned?)
                           (list (cons "skin" 0))
                           '()))))
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

  (define ($extra-specs skin anims)
    (append
     (if (and skin (vector-ref skin 1))
         (list (list (vector-ref skin 1)
                     (vector-length (vector-ref skin 0)) 16 'ibm))
         '())
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
                                       acc))))))))))

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
                   (and (eq? ($blob-kind b) 'times)
                        ($times-bounds ($blob-src b) ($blob-elems b))))))

  ;; accessors and the mesh primitives together: both are driven by
  ;; the same walk, so an attribute can never be given an accessor
  ;; index the primitive does not name
  (define ($mesh-json plans)
    (let loop ((ps plans) (bvs ($view-bases plans))
               (acc-n 0) (mat-n 0)
               (accs '()) (prims '()) (mats '()))
      (if (null? ps)
          (list (reverse accs)
                (list->vector (reverse prims))
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
                         (prim (append
                                (list (cons "attributes" (reverse names)))
                                (if indexed (list (cons "indices" n)) '())
                                (if col (list (cons "material" mat-n)) '())
                                (list (cons "mode" 4)))))  ; TRIANGLES
                    (loop (cdr ps) (cdr bvs)
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

  (define ($json plans binlen nds mesh-node skin anims blobs skinned?)
    (let* ((parts ($mesh-json plans))
           (accs (car parts))
           (prims (cadr parts))
           (mats (caddr parts))
           (view0 ($view-count plans))
           (acc0 (length accs))
           (ibm? (and skin (vector-ref skin 1) #t))
           (extra (let loop ((bs blobs) (k 0) (acc '()))
                    (if (null? bs)
                        (reverse acc)
                        (loop (cdr bs) (+ k 1)
                              (cons ($blob-accessor (car bs) (+ view0 k))
                                    acc))))))
      (json->string
       (append
        (list (cons "asset"
                    (list (cons "version" "2.0")
                          (cons "generator" "goeteia (gfx glb)")))
              (cons "scene" 0)
              (cons "scenes" (vector (list (cons "nodes" ($roots nds)))))
              (cons "nodes" ($nodes-json nds mesh-node skinned?))
              (cons "meshes"
                    (vector (list (cons "primitives" prims)))))
        (if skin
            (list (cons "skins"
                        (vector ($skin-json skin (and ibm? acc0)))))
            '())
        (if (null? anims)
            '()
            (list (cons "animations"
                        ($anims-json anims (+ acc0 (if ibm? 1 0))))))
        (if (= (vector-length mats) 0) '() (list (cons "materials" mats)))
        (list (cons "buffers"
                    (vector (list (cons "byteLength" binlen))))
              (cons "bufferViews"
                    (list->vector (append ($views plans)
                                          ($blob-views blobs))))
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
  (define $top-keys '(nodes mesh-node skin anims))

  (define (glb-write! prims . opts)
    (when (or (not (list? prims)) (null? prims))
      (error 'glb-write! "no primitives to write" prims))
    ($check-options 'glb-write! $top-keys opts)
    (let* ((nds ($nodes-plan ($option opts 'nodes #f)))
           (nnodes (vector-length nds))
           (mesh-node ($option opts 'mesh-node 0))
           (skin ($skin-plan ($option opts 'skin #f) nnodes))
           (njoints (and skin (vector-length (vector-ref skin 0))))
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
                    (let ((r ($plan (car ds) at njoints)))
                      (loop (cdr ds) (cdr r) (cons (car r) acc))))))
             (plans (car planned))
             (placed ($place ($extra-specs skin anims) (cdr planned)))
             (blobs (car placed))
             (binlen (cdr placed))          ; already a multiple of 4
             ;; the mesh node carries the skin only when the mesh
             ;; really has joint inputs: a node with a skin and no
             ;; JOINTS_0 is a primitive no reader can pose
             (skinned? (let loop ((ps plans))
                         (cond ((null? ps) #f)
                               (($plan-joff (car ps)) #t)
                               (else (loop (cdr ps))))))
             (json ($json plans binlen nds mesh-node skin anims blobs
                          skinned?))
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
            (for-each (lambda (b) ($blob-write! data b)) blobs)))
        (cons out total))))
  )
