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
;; interleave: position normal uv tangent color, each float32
;; (12/12/8/16/16 bytes).  vbase points at vertex 0; the stride is
;; the sum of the layout's attribute sizes unless an option
;; overrides it.  ibase points at a tight u16 (or u32) index array;
;; icount 0 -- or ibase #f -- writes a non-indexed primitive.
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
;;
;; What comes out: one buffer (the BIN chunk), two bufferViews per
;; primitive (vertices with a byteStride, indices without), one
;; accessor per attribute plus one per index array, one mesh holding
;; every primitive, one node, one scene.  POSITION carries the min
;; and max the specification requires, computed from the data.
;;
;; Round trip: for a layout in the canonical interleave order
;; (position normal, then uv, then tangent, then color) gltf-parse
;; reproduces the vertex bytes exactly.  Other layouts are written
;; faithfully but come back canonicalized -- the loader always gives
;; a primitive a normal (+y when the file has none) and always
;; carries a uv slot once anything past normal is present, so
;; (position uv) is written as POSITION+TEXCOORD_0 and read back as
;; position normal uv.
;;
;; Not written yet: skins, animations, morph targets, textures,
;; cameras, node hierarchies.  A layout naming joints or weights is
;; refused rather than written as something a reader would
;; misinterpret.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx glb)
  (export glb-write! glb-stride glb-offset)
  (import (rnrs) (web json) (gfx fx))

  ;; ---- the attribute vocabulary ----------------------------------
  ;; (symbol glTF-name components bytes accessor-type).  Every
  ;; attribute is float32 (componentType 5126): that is the form
  ;; (gfx gltf) rebuilds into, so the pair round-trips without a
  ;; conversion on either side.
  (define $attr-table
    '((position "POSITION"   3 12 "VEC3")
      (normal   "NORMAL"     3 12 "VEC3")
      (uv       "TEXCOORD_0" 2  8 "VEC2")
      (tangent  "TANGENT"    4 16 "VEC4")
      (color    "COLOR_0"    4 16 "VEC4")))

  (define ($attr who sym)
    (let ((e (assq sym $attr-table)))
      (cond (e e)
            ((memq sym '(joints weights))
             (error who "skinned layouts are not written yet" sym))
            (else (error who "unknown vertex attribute" sym)))))

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

  ;; ---- the primitive descriptor ----------------------------------
  (define $option-keys '(color index-u32? stride))

  (define ($option opts key default)
    (cond ((null? opts) default)
          ((eq? (car opts) key) (cadr opts))
          (else ($option (cddr opts) key default))))

  (define ($check-options opts)
    (cond ((null? opts) #t)
          ((null? (cdr opts))
           (error 'glb-write! "option without a value" (car opts)))
          ((not (memq (car opts) $option-keys))
           (error 'glb-write! "unknown primitive option" (car opts)))
          (else ($check-options (cddr opts)))))

  (define ($rgba who c)
    (let ((v (cond ((vector? c) c)
                   ((list? c) (list->vector c))
                   (else (error who "color must be four numbers" c)))))
      (unless (= (vector-length v) 4)
        (error who "color must be four numbers" c))
      (vector ($fl (vector-ref v 0)) ($fl (vector-ref v 1))
              ($fl (vector-ref v 2)) ($fl (vector-ref v 3)))))

  ;; A plan is the descriptor with everything derived and checked:
  ;;   (layout vbase vcount stride ibase icount u32? color voff ioff)
  ;; voff/ioff are byte offsets inside the BIN chunk.
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

  (define ($plan-vbytes p) (* ($plan-vcount p) ($plan-stride p)))
  (define ($plan-ibytes p)
    (* ($plan-icount p) (if ($plan-u32? p) 4 2)))

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

  (define ($plan desc at)
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
      ($check-options opts)
      (unless (and (integer? vcount) (> vcount 0))
        (error 'glb-write! "a primitive needs at least one vertex" vcount))
      (let* ((tight (glb-stride layout))
             (stride ($option opts 'stride tight))
             (u32? (and ($option opts 'index-u32? (> vcount 65536)) #t))
             (indexed (and ibase0 (> icount0 0)))
             (icount (if indexed icount0 0))
             (ibase (if indexed ibase0 0))
             (color (let ((c ($option opts 'color #f)))
                      (and c ($rgba 'glb-write! c)))))
        (unless (and (integer? stride) (>= stride tight))
          (error 'glb-write! "stride is smaller than the layout" stride))
        (unless (= (remainder stride 4) 0)
          (error 'glb-write! "stride must be a multiple of 4" stride))
        (when indexed ($check-indices ibase icount u32? vcount))
        (let* ((voff at)
               (ioff ($align4 (+ voff (* vcount stride))))
               (plan (list layout vbase vcount stride ibase icount
                           u32? color voff ioff)))
          (cons plan ($align4 (+ ioff (* icount (if u32? 4 2)))))))))

  ;; ---- the JSON chunk --------------------------------------------
  ;; bufferViews and accessors are numbered as they are emitted: the
  ;; two views of primitive k are 2k and 2k+1, and the accessors run
  ;; attributes-then-indices in layout order.
  (define ($views plans)
    (let loop ((ps plans) (acc '()))
      (if (null? ps)
          (list->vector (reverse acc))
          (let* ((p (car ps))
                 (vb (list (cons "buffer" 0)
                           (cons "byteOffset" ($plan-voff p))
                           (cons "byteLength" ($plan-vbytes p))
                           (cons "byteStride" ($plan-stride p))
                           (cons "target" 34962)))   ; ARRAY_BUFFER
                 (ib (list (cons "buffer" 0)
                           (cons "byteOffset" ($plan-ioff p))
                           (cons "byteLength" ($plan-ibytes p))
                           (cons "target" 34963))))  ; ELEMENT_ARRAY
            (loop (cdr ps)
                  (if (= ($plan-icount p) 0)
                      (cons vb acc)
                      (cons ib (cons vb acc))))))))

  ;; the view index of primitive k's vertices, given that a
  ;; non-indexed primitive contributes only one view
  (define ($view-bases plans)
    (let loop ((ps plans) (n 0) (acc '()))
      (if (null? ps)
          (reverse acc)
          (loop (cdr ps)
                (+ n (if (= ($plan-icount (car ps)) 0) 1 2))
                (cons n acc)))))

  (define ($accessor bv off ct count type bounds)
    (append (list (cons "bufferView" bv)
                  (cons "byteOffset" off)
                  (cons "componentType" ct)
                  (cons "count" count)
                  (cons "type" type))
            (if bounds
                (list (cons "min" (car bounds)) (cons "max" (cdr bounds)))
                '())))

  ;; accessors and the mesh primitives together: both are driven by
  ;; the same walk, so an attribute can never be given an accessor
  ;; index the primitive does not name
  (define ($mesh-json plans)
    (let loop ((ps plans) (bvs ($view-bases plans))
               (acc-n 0) (mat-n 0)
               (accs '()) (prims '()) (mats '()))
      (if (null? ps)
          (list (list->vector (reverse accs))
                (list->vector (reverse prims))
                (list->vector (reverse mats)))
          (let* ((p (car ps))
                 (bv (car bvs))
                 (layout ($plan-layout p))
                 (stride ($plan-stride p))
                 (vcount ($plan-vcount p)))
            (let attr ((l layout) (off 0) (n acc-n)
                       (as accs) (names '()))
              (if (not (null? l))
                  (let* ((e ($attr 'glb-write! (car l)))
                         (bounds
                          (and (eq? (car l) 'position)
                               ($pos-bounds ($plan-vbase p) vcount
                                            stride off))))
                    (attr (cdr l)
                          (+ off ($attr-bytes e))
                          (+ n 1)
                          (cons ($accessor bv off 5126 vcount
                                           ($attr-type e) bounds)
                                as)
                          (cons (cons ($attr-name e) n) names)))
                  ;; indices, then the primitive that names it all
                  (let* ((indexed (> ($plan-icount p) 0))
                         (as2 (if indexed
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

  (define ($json plans binlen)
    (let* ((parts ($mesh-json plans))
           (accs (car parts))
           (prims (cadr parts))
           (mats (caddr parts)))
      (json->string
       (append
        (list (cons "asset"
                    (list (cons "version" "2.0")
                          (cons "generator" "goeteia (gfx glb)")))
              (cons "scene" 0)
              (cons "scenes" (vector (list (cons "nodes" (vector 0)))))
              (cons "nodes" (vector (list (cons "mesh" 0))))
              (cons "meshes"
                    (vector (list (cons "primitives" prims)))))
        (if (= (vector-length mats) 0) '() (list (cons "materials" mats)))
        (list (cons "buffers"
                    (vector (list (cons "byteLength" binlen))))
              (cons "bufferViews" ($views plans))
              (cons "accessors" accs))))))

  ;; ---- the container ---------------------------------------------
  (define (glb-write! prims)
    (when (or (not (list? prims)) (null? prims))
      (error 'glb-write! "no primitives to write" prims))
    (let* ((planned
            (let loop ((ds prims) (at 0) (acc '()))
              (if (null? ds)
                  (cons (reverse acc) at)
                  (let ((r ($plan (car ds) at)))
                    (loop (cdr ds) (cdr r) (cons (car r) acc))))))
           (plans (car planned))
           (binlen (cdr planned))          ; already a multiple of 4
           (json ($json plans binlen))
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
                          ($plan-ibytes p))))
              (block (cdr ps))))))
      (cons out total)))
  )
