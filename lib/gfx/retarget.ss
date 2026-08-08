;; Move one clip from one skeleton onto another, keeping the
;; target's bone lengths.
;;
;; The rule, in one line
;; ---------------------
;; LOCAL ROTATIONS TRANSFER; TRANSLATIONS DO NOT.  A joint's local
;; rotation is a property of the POSE ("the elbow is bent this
;; much"), so it means the same thing on any skeleton with an elbow.
;; A joint's local translation is a property of the SKELETON ("the
;; forearm is 27 units long"), so copying it across would replace
;; the target's proportions with the source's -- which is exactly
;; the failure people mean when a retarget "melted" a character.
;;
;; Bone length preservation is therefore not something this library
;; computes and then checks; it is a consequence of never writing
;; the numbers that encode it.  Every joint below the root chain
;; keeps its bind translation at every frame, and the clip that
;; comes out carries no translation channel for it at all.
;;
;; The root chain
;; --------------
;; One thing does have to travel: where the character is.  That
;; lives on the ROOT CHAIN -- from each skeleton root down to and
;; INCLUDING the first joint with other than one child.  Those
;; offsets are not anatomy, they are the rig's way of saying "the
;; hips are this high", so rescaling them is not deformation.  The
;; factor is the ratio of the two skeletons' bind extents, and what
;; is rescaled is the DISPLACEMENT FROM BIND, not the absolute
;; value:
;;
;;   t_dst(f) = t_dst_bind + (t_src(f) - t_src_bind) * (h_dst / h_src)
;;
;; so the target keeps its own rest placement and only the motion
;; is scaled.  On two skeletons that differ by a uniform factor k
;; both readings coincide.
;;
;; The extent is the LARGEST of the three axis spans of the bind
;; pose, not the vertical one: two rigs in a retarget need not share
;; an up axis, and a ratio taken along the wrong axis is a scale
;; factor pulled out of the air.
;;
;; Joint mapping
;; -------------
;; Three sources, tried in this order, first one that names a joint
;; wins:
;;
;;   1. 'map -- an explicit table, ((source . target) ...) or
;;      ((source target) ...).  Both names are resolved against both
;;      skeletons, so a typo is a named error rather than a silently
;;      dropped limb.
;;   2. Normalised names.  retarget-normalize-name lowercases, drops
;;      an exporter namespace (mixamorig:Hips), removes separators
;;      and strips a known rig prefix, so Bip01-L-Hand, BIPED_L_HAND
;;      and bip01.l.hand are one joint.
;;   3. Nothing.  An unmapped target joint HOLDS BIND: it gets a
;;      constant rotation track equal to its bind rotation and no
;;      translation track, which is the pose a missing channel would
;;      give and is visible to a reader that only looks at the clip.
;;
;; Two source joints that fold to the same key would make the
;; heuristic depend on joint order, so the first one wins and the
;; collision is REPORTED (retarget-report's 'ambiguous) rather than
;; swallowed; an explicit 'map entry is the fix.
;;
;; Using it
;; --------
;;   (retarget-clip! src ci dst 'map m 'clip-name "run")
;;       -> (name channels), a clip descriptor (gfx glb)'s 'anims
;;          takes verbatim -- no staging round trip
;;   (retarget-write-glb! dst clip 'names ns) -> (base . len)
;;       -> the target asset plus that clip, as a GLB
;;   (retarget-report src ci dst ...) -> an alist: which rule
;;          matched what, the extents, the ratio, the joints that
;;          received a translation track
;;   (retarget-normalize-name "mixamorig:L_Hand") -> "lhand"
;;   (retarget-glb-node-names loc) -> the node names in a GLB
;;
;; Node names: (gfx gltf) keeps a node's TRS and its parent but not
;; its name, and the by-name rule needs names.  They are therefore
;; an input -- 'src-names / 'dst-names, a vector or list in node
;; order, or an alist of (node-index . name) -- and
;; retarget-glb-node-names reads them out of the GLB the asset was
;; parsed from.  A node with no name is called nodeN after its
;; index, which is what a glTF reader synthesises anyway, so a pair
;; of assets with no names at all still matches position for
;; position.
;;
;; The node table is read as the BIND pose.  (gfx gltf) animates in
;; place, so retarget an asset before posing it, or after a
;; gltf-animate! that has been reset -- a target left mid-clip would
;; contribute its posed transform as its rest placement.
;;
;; Known limits -- read before calling a result wrong
;; --------------------------------------------------
;; * The local rotation is copied VERBATIM, with no compensation for
;;   the two rigs' bind frames.  A rig whose bones run along local X
;;   and one whose bones run along local Y will both move, and both
;;   by the right amount, but the poses will not look alike: the
;;   difference between the bind orientations is a constant rotation
;;   a production retargeter folds in.  Doing that needs a
;;   correspondence between bone DIRECTIONS, which is a different
;;   and much less well-posed problem than a correspondence between
;;   bone NAMES.  What this library guarantees is what its tests
;;   say: mapped joints move, unmapped joints do not, and no bone
;;   changes length.
;; * A joint with a non-unit scale is refused rather than
;;   approximated, and so is a joint given as a matrix.  Anything
;;   within 0.0002 of unity is snapped: a float32 round trip through
;;   an exporter leaves scales like 1.0000085 all over a perfectly
;;   rigid rig, and refusing a rig over a rounding artefact is
;;   refusing a legal input.
;; * Morph target weights and any channel other than rotation and
;;   translation are not carried across.
;; * What comes out is always LINEAR.  A STEP or CUBICSPLINE source
;;   track is read at its own key times, so the produced clip agrees
;;   with it AT every key and differs from it between two: a step
;;   that used to hold now ramps.  Ask for more keys ('samples) when
;;   that matters.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx retarget)
  (export retarget-clip! retarget-write-glb! retarget-report
          retarget-normalize-name retarget-glb-node-names)
  (import (rnrs) (gfx fx) (gfx mat) (gfx gltf) (gfx glb) (web json))

  ;; ---- small numeric helpers the prelude does not carry ----------
  (define ($rt-fl v) (if (flonum? v) v (exact->inexact v)))
  (define ($rt-fl-abs x) (if (fl<? x 0.0) (fl- 0.0 x) x))
  (define ($rt-fl-min a b) (if (fl<? a b) a b))
  (define ($rt-fl-max a b) (if (fl<? a b) b a))

  ;; The one quaternion operation (gfx mat) does not already carry.
  ;; q-slerp is the other one, and it is used as it stands.
  (define ($rt-q-norm q)
    (let ((n (flsqrt (fl+ (fl+ (fl* (vector-ref q 0) (vector-ref q 0))
                               (fl* (vector-ref q 1) (vector-ref q 1)))
                          (fl+ (fl* (vector-ref q 2) (vector-ref q 2))
                               (fl* (vector-ref q 3) (vector-ref q 3)))))))
      (if (fl<? 0.0 n)
          (vector (fl/ (vector-ref q 0) n) (fl/ (vector-ref q 1) n)
                  (fl/ (vector-ref q 2) n) (fl/ (vector-ref q 3) n))
          (vector 0.0 0.0 0.0 1.0))))

  (define ($rt-q-dot a b)
    (fl+ (fl+ (fl* (vector-ref a 0) (vector-ref b 0))
              (fl* (vector-ref a 1) (vector-ref b 1)))
         (fl+ (fl* (vector-ref a 2) (vector-ref b 2))
              (fl* (vector-ref a 3) (vector-ref b 3)))))

  (define ($rt-q-neg q)
    (vector (fl- 0.0 (vector-ref q 0)) (fl- 0.0 (vector-ref q 1))
            (fl- 0.0 (vector-ref q 2)) (fl- 0.0 (vector-ref q 3))))

  ;; ---- options: a key/value tail, so a later revision can add one
  ;; without disturbing a caller -----------------------------------
  (define ($rt-option opts key default)
    (let loop ((o opts))
      (cond ((null? o) default)
            ((null? (cdr o)) default)
            ((eq? (car o) key) (cadr o))
            (else (loop (cddr o))))))

  (define ($rt-check-options who keys opts)
    (let loop ((o opts))
      (cond ((null? o) #t)
            ((null? (cdr o))
             (error who "an option is missing its value" (car o)))
            ((memq (car o) keys) (loop (cddr o)))
            (else (error who "unknown option" (car o))))))

  ;; ---- name normalisation ----------------------------------------
  ;; Exporter prefixes that name the RIG rather than the joint.
  ;; Longest first, so bip001 is not half-eaten by bip01's stem.
  (define $rt-prefixes
    '("mixamorig" "character" "armature" "bip001" "bip01" "biped"
      "skel" "rig"))

  (define ($rt-after-last s ch)
    (let loop ((i (- (string-length s) 1)))
      (cond ((< i 0) s)
            ((char=? (string-ref s i) ch)
             (substring s (+ i 1) (string-length s)))
            (else (loop (- i 1))))))

  (define ($rt-alnum-lower s)
    (let loop ((i 0) (acc '()))
      (if (= i (string-length s))
          (list->string (reverse acc))
          (let ((c (char-downcase (string-ref s i))))
            (loop (+ i 1)
                  (if (or (char-alphabetic? c) (char-numeric? c))
                      (cons c acc)
                      acc))))))

  (define ($rt-starts-with? p s)
    (and (> (string-length s) (string-length p))
         (string=? p (substring s 0 (string-length p)))))

  ;; Fold the spellings of one joint name into a single key.
  ;; Deliberately wider than any one asset needs: an exporter
  ;; namespace (rig:Hips, rig|Hips), any separator, any casing and a
  ;; leading rig prefix all disappear.  Widening this later can only
  ;; merge more names, never split ones that match today.
  (define (retarget-normalize-name name)
    (let* ((s (cond ((string? name) name)
                    ((symbol? name) (symbol->string name))
                    (else (error 'retarget-normalize-name
                                 "a joint name is a string" name))))
           (s ($rt-after-last s #\:))
           (s ($rt-after-last s #\|))
           (s ($rt-alnum-lower s)))
      (let loop ((ps $rt-prefixes))
        (cond ((null? ps) s)
              (($rt-starts-with? (car ps) s)
               (substring s (string-length (car ps)) (string-length s)))
              (else (loop (cdr ps)))))))

  ;; ---- node names -------------------------------------------------
  ;; 'src-names / 'dst-names accept a vector or list in node order,
  ;; or an alist of (node-index . name); anything a node has no
  ;; entry for is called nodeN, which is what a glTF reader
  ;; synthesises for an unnamed node.
  (define ($rt-name-lookup names ni)
    (cond ((not names) #f)
          ((vector? names)
           (and (< ni (vector-length names)) (vector-ref names ni)))
          ((and (pair? names) (pair? (car names)))
           (let loop ((l names))
             (cond ((null? l) #f)
                   ((and (pair? (car l))
                         (integer? (caar l)) (= (caar l) ni))
                    (let ((v (cdar l)))
                      (if (and (pair? v) (null? (cdr v))) (car v) v)))
                   (else (loop (cdr l))))))
          ((list? names)
           (let loop ((l names) (k 0))
             (cond ((null? l) #f)
                   ((= k ni) (car l))
                   (else (loop (cdr l) (+ k 1))))))
          (else #f)))

  (define ($rt-node-name names ni)
    (let ((n ($rt-name-lookup names ni)))
      (cond ((string? n) n)
            ((symbol? n) (symbol->string n))
            (else (string-append "node" (number->string ni))))))

  ;; The names out of a GLB's own JSON chunk, indexed by node.  The
  ;; loader keeps a node's transform and its parent but not its
  ;; name, and the by-name rule needs names, so this reads them back
  ;; from the bytes the asset was parsed from.  Takes (base . len)
  ;; -- what glb-write! returns and gltf-parse takes -- or base and
  ;; len as two arguments; the length is the header's business
  ;; either way, so it is accepted and not used.
  (define (retarget-glb-node-names loc . len)
    (let ((base (if (pair? loc) (car loc) loc)))
      ;; the magic before the length: a chunk size read out of
      ;; something that is not a GLB is a string allocation of
      ;; whatever four arbitrary bytes happen to say
      (unless (and (= (%mem-u8-ref base) 103)        ; "glTF"
                   (= (%mem-u8-ref (+ base 1)) 108)
                   (= (%mem-u8-ref (+ base 2)) 84)
                   (= (%mem-u8-ref (+ base 3)) 70))
        (error 'retarget-glb-node-names "not a GLB" base))
      (let* ((jlen (+ (%mem-u8-ref (+ base 12))
                      (* 256 (%mem-u8-ref (+ base 13)))
                      (* 65536 (%mem-u8-ref (+ base 14)))
                      (* 16777216 (%mem-u8-ref (+ base 15)))))
             (s (make-string jlen #\space)))
      (let loop ((i 0))
        (when (< i jlen)
          (string-set! s i (integer->char (%mem-u8-ref (+ base 20 i))))
          (loop (+ i 1))))
      (let* ((j (string->json s))
             (ns (json-ref j "nodes"))
             (n (if ns (vector-length ns) 0))
             (out (make-vector n #f)))
        (let loop ((i 0))
          (when (< i n)
            (vector-set! out i (json-ref ns i "name"))
            (loop (+ i 1))))
        out))))

  ;; ---- the skeleton -----------------------------------------------
  ;; #(joint-nodes parents children order roots bind-t bind-q names)
  ;; Deliberately more complete than the retarget needs -- child
  ;; lists and a topological order are what a later tool would grow
  ;; its own loader for.
  (define ($rt-sk-nodes s) (vector-ref s 0))
  (define ($rt-sk-parents s) (vector-ref s 1))
  (define ($rt-sk-children s) (vector-ref s 2))
  (define ($rt-sk-order s) (vector-ref s 3))
  (define ($rt-sk-roots s) (vector-ref s 4))
  (define ($rt-sk-bt s) (vector-ref s 5))
  (define ($rt-sk-bq s) (vector-ref s 6))
  (define ($rt-sk-names s) (vector-ref s 7))
  (define ($rt-sk-count s) (vector-length (vector-ref s 0)))

  (define $rt-scale-tol 0.0002)

  (define ($rt-skeleton who g si names)
    (let ((skins (gltf-skins g)))
      (unless (and (integer? si) (>= si 0) (< si (vector-length skins)))
        (error who "the asset has no such skin" si))
      (let* ((skin (vector-ref skins si))
             (jn (vector-ref skin 0))
             (nj (vector-length jn))
             (nodes (gltf-nodes g))
             (nn (vector-length nodes))
             (pos (make-vector nn -1))
             (parents (make-vector nj -1))
             (kids (make-vector nj '()))
             (bt (make-vector nj #f))
             (bq (make-vector nj #f))
             (nms (make-vector nj #f)))
        (when (= nj 0)
          (error who "the skin has no joints" si))
        (let loop ((k 0))
          (when (< k nj)
            (let ((ni (vector-ref jn k)))
              (unless (and (integer? ni) (>= ni 0) (< ni nn))
                (error who "a skin names a node the asset lacks" ni))
              (vector-set! pos ni k))
            (loop (+ k 1))))
        (let loop ((k 0))
          (when (< k nj)
            (let* ((ni (vector-ref jn k))
                   (v (vector-ref nodes ni))
                   (nm ($rt-node-name names ni))
                   (pn (vector-ref v 11)))
              (when (vector-ref v 10)
                (error who "a joint is given as a matrix, not TRS" nm))
              (let ((sx (vector-ref v 7)) (sy (vector-ref v 8))
                    (sz (vector-ref v 9)))
                (when (or (fl<? $rt-scale-tol ($rt-fl-abs (fl- sx 1.0)))
                          (fl<? $rt-scale-tol ($rt-fl-abs (fl- sy 1.0)))
                          (fl<? $rt-scale-tol ($rt-fl-abs (fl- sz 1.0))))
                  (error who "a joint carries a non-unit scale" nm)))
              (vector-set! nms k nm)
              (vector-set! bt k (vector (vector-ref v 0) (vector-ref v 1)
                                        (vector-ref v 2)))
              (vector-set! bq k ($rt-q-norm
                                 (vector (vector-ref v 3) (vector-ref v 4)
                                         (vector-ref v 5) (vector-ref v 6))))
              (vector-set! parents k
                           (if (and (integer? pn) (>= pn 0))
                               (vector-ref pos pn)
                               -1)))
            (loop (+ k 1))))
        ;; children, in joint order
        (let loop ((k (- nj 1)))
          (when (>= k 0)
            (let ((p (vector-ref parents k)))
              (when (>= p 0)
                (vector-set! kids p (cons k (vector-ref kids p)))))
            (loop (- k 1))))
        ;; root-to-leaf topological order; a parent always precedes
        ;; its child, and a shortfall means the hierarchy is not a
        ;; forest
        (let* ((roots (let loop ((k (- nj 1)) (acc '()))
                        (if (< k 0)
                            acc
                            (loop (- k 1)
                                  (if (< (vector-ref parents k) 0)
                                      (cons k acc)
                                      acc)))))
               ;; the step bound is not decoration: a joint listed
               ;; as a child of two nodes leaves a parent link that
               ;; closes on itself, and a walk with no bound does
               ;; not come back to report it
               (order (let walk ((stack roots) (acc '()) (steps 0))
                        (cond ((> steps nj)
                               (error who "the joint hierarchy has a cycle"
                                      si))
                              ((null? stack) (reverse acc))
                              (else
                               (walk (append (vector-ref kids (car stack))
                                             (cdr stack))
                                     (cons (car stack) acc)
                                     (+ steps 1)))))))
          (unless (= (length order) nj)
            (error who "the joint hierarchy is not a forest" si))
          (vector jn parents kids order roots bt bq nms)))))

  ;; world bind positions, one #(x y z) per joint
  (define ($rt-bind-world s)
    (let* ((n ($rt-sk-count s))
           (gm (make-vector n #f))
           (out (make-vector n #f))
           (parents ($rt-sk-parents s))
           (bt ($rt-sk-bt s))
           (bq ($rt-sk-bq s)))
      (let loop ((o ($rt-sk-order s)))
        (unless (null? o)
          (let* ((i (car o))
                 (t (vector-ref bt i))
                 (q (vector-ref bq i))
                 (local (m4-mul (m4-translate (vector-ref t 0)
                                              (vector-ref t 1)
                                              (vector-ref t 2))
                                (m4-from-quat (vector-ref q 0)
                                              (vector-ref q 1)
                                              (vector-ref q 2)
                                              (vector-ref q 3))))
                 (p (vector-ref parents i))
                 (g (if (< p 0) local (m4-mul (vector-ref gm p) local))))
            (vector-set! gm i g)
            (vector-set! out i (vector (vector-ref g 12) (vector-ref g 13)
                                       (vector-ref g 14))))
          (loop (cdr o))))
      out))

  ;; The bind skeleton's size: the LARGEST of its three axis spans,
  ;; not the vertical one -- see the header.
  (define ($rt-extent s)
    (let ((w ($rt-bind-world s))
          (n ($rt-sk-count s)))
      (let axis ((k 0) (best 0.0))
        (if (= k 3)
            best
            (let comp ((i 1)
                       (lo (vector-ref (vector-ref w 0) k))
                       (hi (vector-ref (vector-ref w 0) k)))
              (if (= i n)
                  (axis (+ k 1) ($rt-fl-max best (fl- hi lo)))
                  (let ((v (vector-ref (vector-ref w i) k)))
                    (comp (+ i 1) ($rt-fl-min lo v) ($rt-fl-max hi v)))))))))

  ;; Joint indices from each root down to (and including) the first
  ;; joint that does not have exactly one child.  These are the
  ;; joints whose local translation is the rig's placement of the
  ;; character rather than the length of a bone, so they are the
  ;; only ones allowed to receive a translation track.
  (define ($rt-root-chain s)
    (let ((kids ($rt-sk-children s)))
      (let roots ((rs ($rt-sk-roots s)) (acc '()))
        (if (null? rs)
            (reverse acc)
            (let down ((i (car rs)) (acc acc))
              (let ((ch (vector-ref kids i)))
                (if (and (pair? ch) (null? (cdr ch)))
                    (down (car ch) (cons i acc))
                    (roots (cdr rs) (cons i acc)))))))))

  ;; ---- the mapping ------------------------------------------------
  (define ($rt-resolve who s name side)
    (let* ((nms ($rt-sk-names s))
           (n (vector-length nms))
           ;; an exact name first; the last joint to carry it wins,
           ;; the way a name table built by assignment resolves it
           (exact (let loop ((i 0) (hit #f))
                    (if (= i n)
                        hit
                        (loop (+ i 1)
                              (if (string=? (vector-ref nms i) name)
                                  i
                                  hit))))))
      (if exact
          exact
          (let* ((key (retarget-normalize-name name))
                 (hits (let loop ((i (- n 1)) (acc '()))
                         (if (< i 0)
                             acc
                             (loop (- i 1)
                                   (if (string=?
                                        (retarget-normalize-name
                                         (vector-ref nms i))
                                        key)
                                       (cons i acc)
                                       acc))))))
            (if (and (pair? hits) (null? (cdr hits)))
                (car hits)
                (error who
                       (if (null? hits)
                           (if (eq? side 'source)
                               "the source skeleton has no such joint"
                               "the target skeleton has no such joint")
                           (if (eq? side 'source)
                               "the source joint name is ambiguous"
                               "the target joint name is ambiguous"))
                       name))))))

  (define ($rt-map-pairs who explicit)
    ;; ((src . dst) ...) or ((src dst) ...) -> ((src . dst) ...)
    (cond ((not explicit) '())
          ((null? explicit) '())
          ((and (pair? explicit) (list? explicit))
           (map (lambda (e)
                  (cond ((and (pair? e) (pair? (cdr e)) (null? (cddr e)))
                         (cons (car e) (cadr e)))
                        ((pair? e) (cons (car e) (cdr e)))
                        (else (error who
                                     "'map takes (source . target) pairs" e))))
                explicit))
          (else (error who "'map takes a list of pairs" explicit))))

  ;; -> #(pairs reasons ambiguous), pairs a vector indexed by target
  ;; joint holding a source joint index or #f
  (define ($rt-mapping who src dst explicit)
    (let* ((nd ($rt-sk-count dst))
           (ns ($rt-sk-count src))
           (pairs (make-vector nd #f))
           (reason (make-vector nd #f)))
      (let loop ((es ($rt-map-pairs who explicit)))
        (unless (null? es)
          (let ((si ($rt-resolve who src (caar es) 'source))
                (di ($rt-resolve who dst (cdar es) 'target)))
            (vector-set! pairs di si)
            (vector-set! reason di 'explicit))
          (loop (cdr es))))
      ;; the by-name pass.  Two source joints folding to one key
      ;; would make the result depend on joint order, so the first
      ;; wins and the collision is reported rather than swallowed.
      (let* ((snm ($rt-sk-names src))
             (dnm ($rt-sk-names dst))
             (amb '())
             (by-norm '()))
        (let loop ((i 0))
          (when (< i ns)
            (let* ((k (retarget-normalize-name (vector-ref snm i)))
                   (hit (assoc k by-norm)))
              (if hit
                  (set! amb (cons (list (vector-ref snm (cdr hit))
                                        (vector-ref snm i))
                                  amb))
                  (set! by-norm (cons (cons k i) by-norm))))
            (loop (+ i 1))))
        (let loop ((i 0))
          (when (< i nd)
            (unless (vector-ref pairs i)
              (let ((hit (assoc (retarget-normalize-name (vector-ref dnm i))
                                by-norm)))
                (when hit
                  (vector-set! pairs i (cdr hit))
                  (vector-set! reason i 'name))))
            (loop (+ i 1))))
        (vector pairs reason (reverse amb)))))

  ;; ---- the source clip, decoded -----------------------------------
  ;; Only rotation and translation travel; a scale or morph-weight
  ;; channel is not something a retarget can mean.
  ;; -> a vector indexed by node: #f, or #(t-times t-vals r-times r-vals)
  (define ($rt-tracks g ai)
    (let* ((anim (vector-ref (gltf-anims g) ai))
           (chans (vector-ref anim 1))
           (nn (vector-length (gltf-nodes g)))
           (out (make-vector nn #f)))
      (let loop ((c 0))
        (when (< c (vector-length chans))
          (let* ((ch (vector-ref chans c))
                 (ni (vector-ref ch 0))
                 (path (vector-ref ch 1)))
            (when (and (integer? ni) (>= ni 0) (< ni nn)
                       (or (eq? path 'translation) (eq? path 'rotation)))
              (let ((slot (or (vector-ref out ni)
                              (let ((v (make-vector 4 #f)))
                                (vector-set! out ni v)
                                v))))
                (if (eq? path 'translation)
                    (begin (vector-set! slot 0 (vector-ref ch 2))
                           (vector-set! slot 1 (vector-ref ch 3)))
                    (begin (vector-set! slot 2 (vector-ref ch 2))
                           (vector-set! slot 3 (vector-ref ch 3)))))))
          (loop (+ c 1))))
      out))

  ;; The span holding t: the largest k with times[k] <= t, clamped
  ;; to the interior.  Ends are answered verbatim, so a key value
  ;; comes back as itself and not as an interpolation of itself.
  (define ($rt-sample tt tv t rot?)
    (let ((n (vector-length tt)))
      (cond
       ((= n 0) #f)
       ((= n 1) (vector-ref tv 0))
       ((not (fl<? (vector-ref tt 0) t)) (vector-ref tv 0))
       ((not (fl<? t (vector-ref tt (- n 1)))) (vector-ref tv (- n 1)))
       (else
        (let bs ((lo 0) (hi (- n 1)))
          (if (> (- hi lo) 1)
              (let ((mid (quotient (+ lo hi) 2)))
                (if (fl<? t (vector-ref tt mid))
                    (bs lo mid)
                    (bs mid hi)))
              (let* ((t0 (vector-ref tt lo))
                     (t1 (vector-ref tt hi))
                     (u (fl/ (fl- t t0) (fl- t1 t0)))
                     (a (vector-ref tv lo))
                     (b (vector-ref tv hi)))
                (if rot?
                    (q-slerp a b u)
                    (vector
                     (fl+ (vector-ref a 0)
                          (fl* (fl- (vector-ref b 0) (vector-ref a 0)) u))
                     (fl+ (vector-ref a 1)
                          (fl* (fl- (vector-ref b 1) (vector-ref a 1)) u))
                     (fl+ (vector-ref a 2)
                          (fl* (fl- (vector-ref b 2) (vector-ref a 2)) u)))))))))))

  ;; ---- the sample grid --------------------------------------------
  ;; The source clip's OWN key times, so a linear resample is exact.
  ;; Sampling on a uniform grid instead would make even an identity
  ;; retarget differ from its input everywhere between grid points:
  ;; an error small, plausible and entirely self-inflicted.
  (define $rt-time-limit 4096)

  ;; merge and dedup are written with an accumulator rather than as
  ;; the natural recursion: the grid can hold thousands of keys, and
  ;; a recursion that deep is a stack the compiler has no reason to
  ;; have sized for
  (define ($rt-merge a b)
    (let loop ((a a) (b b) (acc '()))
      (cond ((null? a) (append (reverse acc) b))
            ((null? b) (append (reverse acc) a))
            ((fl<? (car b) (car a)) (loop a (cdr b) (cons (car b) acc)))
            (else (loop (cdr a) b (cons (car a) acc))))))

  (define ($rt-sort-fl l)
    (if (or (null? l) (null? (cdr l)))
        l
        (let split ((rest l) (x '()) (y '()))
          (if (null? rest)
              ($rt-merge ($rt-sort-fl x) ($rt-sort-fl y))
              (split (cdr rest) y (cons (car rest) x))))))

  (define ($rt-dedup l)
    (let loop ((l l) (acc '()))
      (cond ((null? l) (reverse acc))
            ((and (pair? acc) (fl=? (car l) (car acc))) (loop (cdr l) acc))
            (else (loop (cdr l) (cons (car l) acc))))))

  (define ($rt-clip-times g ai)
    (let* ((anim (vector-ref (gltf-anims g) ai))
           (chans (vector-ref anim 1))
           (ts (let loop ((c 0) (acc '()))
                 (if (= c (vector-length chans))
                     acc
                     (let* ((ch (vector-ref chans c))
                            (path (vector-ref ch 1)))
                       (loop (+ c 1)
                             (if (or (eq? path 'translation)
                                     (eq? path 'rotation))
                                 (let ((tt (vector-ref ch 2)))
                                   (let k ((i 0) (a acc))
                                     (if (= i (vector-length tt))
                                         a
                                         (k (+ i 1)
                                            (cons (vector-ref tt i) a)))))
                                 acc))))))
           (sorted ($rt-dedup ($rt-sort-fl ts))))
      (cond ((null? sorted) (list 0.0))
            ((<= (length sorted) $rt-time-limit) sorted)
            (else
             ;; a decimated grid can land on the same key twice, and
             ;; a sampler with a repeated input is not a legal glTF
             ;; animation
             (let* ((v (list->vector sorted))
                    (n (vector-length v)))
               ($rt-dedup
                (let pick ((i 0) (acc '()))
                  (if (= i $rt-time-limit)
                      (reverse acc)
                      (let ((k (quotient (* i n) $rt-time-limit)))
                        (pick (+ i 1)
                              (cons (vector-ref v (if (< k n) k (- n 1)))
                                    acc)))))))))))

  ;; ---- the core ---------------------------------------------------
  ;; The only place the semantics live.  Everything a target joint
  ;; can receive is decided here and nowhere else: a rotation if it
  ;; is mapped, a scaled root displacement if it is mapped AND on
  ;; the root chain, and its bind value otherwise.
  (define ($rt-channels src dst tracks pairs times ratio tset)
    (let* ((nd ($rt-sk-count dst))
           (nf (length times))
           (sjn ($rt-sk-nodes src))
           (djn ($rt-sk-nodes dst))
           (sbt ($rt-sk-bt src))
           (sbq ($rt-sk-bq src))
           (dbt ($rt-sk-bt dst))
           (dbq ($rt-sk-bq dst))
           (tv (list->vector times)))
      (let joint ((di (- nd 1)) (acc '()))
        (if (< di 0)
            acc
            (let* ((si (vector-ref pairs di))
                   (moves? (memv di tset))
                   (rot (make-vector nf #f))
                   (tr (and si moves? (make-vector nf #f))))
              (let frame ((f 0) (prev #f))
                (when (< f nf)
                  (let* ((t (vector-ref tv f))
                         (q (if si
                                ;; the LOCAL rotation, not the world
                                ;; one: a world rotation carries every
                                ;; ancestor's orientation with it, so
                                ;; writing it into a local slot applies
                                ;; the whole chain a second time
                                (let* ((slot (vector-ref tracks
                                                         (vector-ref sjn si)))
                                       (s (and slot
                                               (vector-ref slot 2)
                                               ($rt-sample (vector-ref slot 2)
                                                        (vector-ref slot 3)
                                                        t #t))))
                                  ($rt-q-norm (if s s (vector-ref sbq si))))
                                (vector-ref dbq di)))
                         ;; one hemisphere per track: a sign flip
                         ;; between keys is a rotation the long way
                         ;; round for every reader that lerps
                         (q (if (and prev (fl<? ($rt-q-dot q prev) 0.0))
                                ($rt-q-neg q)
                                q)))
                    (vector-set! rot f q)
                    (when tr
                      (let* ((slot (vector-ref tracks (vector-ref sjn si)))
                             (s (and slot
                                     (vector-ref slot 0)
                                     ($rt-sample (vector-ref slot 0)
                                              (vector-ref slot 1) t #f)))
                             (s (if s s (vector-ref sbt si)))
                             (sb (vector-ref sbt si))
                             (db (vector-ref dbt di)))
                        (vector-set!
                         tr f
                         (vector
                          (fl+ (vector-ref db 0)
                               (fl* (fl- (vector-ref s 0) (vector-ref sb 0))
                                    ratio))
                          (fl+ (vector-ref db 1)
                               (fl* (fl- (vector-ref s 1) (vector-ref sb 1))
                                    ratio))
                          (fl+ (vector-ref db 2)
                               (fl* (fl- (vector-ref s 2) (vector-ref sb 2))
                                    ratio))))))
                    (frame (+ f 1) q))))
              (joint (- di 1)
                     (cons (list (vector-ref djn di) 'rotation tv rot nf
                                 'interpolation 'linear)
                           (if tr
                               (cons (list (vector-ref djn di) 'translation
                                           tv tr nf
                                           'interpolation 'linear)
                                     acc)
                               acc))))))))

  ;; ---- the plan: one walk, two answers ---------------------------
  (define $rt-clip-keys
    '(map clip-name src-names dst-names skin dst-skin samples))

  (define ($rt-plan who src ci dst opts)
    ($rt-check-options who $rt-clip-keys opts)
    (let ((anims (gltf-anims src)))
      (unless (and (integer? ci) (>= ci 0) (< ci (vector-length anims)))
        (error who "the source has no such animation" ci))
      (let* ((s ($rt-skeleton who src ($rt-option opts 'skin 0)
                           ($rt-option opts 'src-names #f)))
             (d ($rt-skeleton who dst ($rt-option opts 'dst-skin 0)
                           ($rt-option opts 'dst-names #f)))
             (m ($rt-mapping who s d ($rt-option opts 'map #f)))
             (pairs (vector-ref m 0))
             (reason (vector-ref m 1))
             (hs ($rt-extent s))
             (hd ($rt-extent d)))
        (unless (fl<? 0.0 hs)
          (error who "the source skeleton has no extent" hs))
        (let* ((ratio (fl/ hd hs))
               (samples ($rt-option opts 'samples 0))
               ;; the clip's own clock, over the channels that
               ;; travel: a scale track running past the last
               ;; rotation key is not motion this tool carries, so
               ;; it must not stretch the resample either
               (dur (let last ((l ($rt-clip-times src ci)) (m 0.0))
                      (if (null? l)
                          m
                          (last (cdr l) ($rt-fl-max m (car l))))))
               (times (if (and (integer? samples) (> samples 1))
                          (let loop ((i (- samples 1)) (acc '()))
                            (if (< i 0)
                                acc
                                (loop (- i 1)
                                      (cons (fl/ (fl* dur ($rt-fl i))
                                                 ($rt-fl (- samples 1)))
                                            acc))))
                          ($rt-clip-times src ci)))
               (tset (let loop ((c ($rt-root-chain d)) (acc '()))
                       (cond ((null? c) (reverse acc))
                             ((vector-ref pairs (car c))
                              (loop (cdr c) (cons (car c) acc)))
                             (else (loop (cdr c) acc)))))
               (name (let ((n ($rt-option opts 'clip-name #f)))
                       (if n n (vector-ref (vector-ref anims ci) 0))))
               (chans ($rt-channels s d ($rt-tracks src ci) pairs times ratio
                                 tset))
               (nd ($rt-sk-count d))
               (mapped (let loop ((i 0) (k 0))
                         (if (= i nd)
                             k
                             (loop (+ i 1)
                                   (if (vector-ref pairs i) (+ k 1) k)))))
               (byreason (lambda (r)
                           (let loop ((i 0) (k 0))
                             (if (= i nd)
                                 k
                                 (loop (+ i 1)
                                       (if (eq? (vector-ref reason i) r)
                                           (+ k 1) k))))))
               (tl (list->vector times)))
          (vector
           (list name chans)
           (list
            (cons 'clip name)
            (cons 'frames (length times))
            (cons 'duration (fl- (vector-ref tl (- (vector-length tl) 1))
                                 (vector-ref tl 0)))
            (cons 'src-joints ($rt-sk-count s))
            (cons 'dst-joints nd)
            (cons 'mapped mapped)
            (cons 'unmapped (- nd mapped))
            (cons 'explicit (byreason 'explicit))
            (cons 'by-name (byreason 'name))
            (cons 'extent-src hs)
            (cons 'extent-dst hd)
            (cons 'ratio ratio)
            (cons 'translate tset)
            (cons 'pairs (let loop ((i (- nd 1)) (acc '()))
                           (if (< i 0)
                               acc
                               (loop (- i 1)
                                     (if (vector-ref pairs i)
                                         (cons (cons i (vector-ref pairs i))
                                               acc)
                                         acc)))))
            (cons 'unmapped-joints
                  (let loop ((i (- nd 1)) (acc '()))
                    (if (< i 0)
                        acc
                        (loop (- i 1)
                              (if (vector-ref pairs i) acc (cons i acc))))))
            (cons 'src-names (vector->list ($rt-sk-names s)))
            (cons 'dst-names (vector->list ($rt-sk-names d)))
            (cons 'ambiguous (vector-ref m 2))))))))

  ;; A clip descriptor (gfx glb)'s 'anims takes verbatim:
  ;;   (name ((node path times values count 'interpolation 'linear) ...))
  ;; Every target joint gets a rotation channel -- an unmapped one
  ;; holds its bind rotation, which is what a reader that only looks
  ;; at the clip must be able to see -- and the mapped joints on the
  ;; root chain also get a translation channel.  Nothing else does,
  ;; and that is the whole of bone-length preservation.
  (define (retarget-clip! src ci dst . opts)
    (vector-ref ($rt-plan 'retarget-clip! src ci dst opts) 0))

  ;; The same walk, reporting instead of producing: which rule
  ;; matched what, the two extents and their ratio, and the joints
  ;; that received a translation track.  When a retarget looks wrong
  ;; the first question is always which rule matched.
  (define (retarget-report src ci dst . opts)
    (vector-ref ($rt-plan 'retarget-report src ci dst opts) 1))

  ;; ---- writing the target out ------------------------------------
  (define ($rt-node->desc names i v)
    (list ($rt-name-lookup names i)
          (vector-ref v 11)
          (vector (vector-ref v 0) (vector-ref v 1) (vector-ref v 2))
          (vector (vector-ref v 3) (vector-ref v 4)
                  (vector-ref v 5) (vector-ref v 6))
          (vector (vector-ref v 7) (vector-ref v 8) (vector-ref v 9))))

  ;; CUBICSPLINE is the one shape the parser splits and the writer
  ;; wants whole: in-tangent, value, out-tangent, per key.
  (define ($rt-chan->desc ch)
    (let* ((path (vector-ref ch 1))
           (times (vector-ref ch 2))
           (vals (vector-ref ch 3))
           (interp (vector-ref ch 5))
           (n (vector-length times))
           (out (if (eq? interp 'cubic)
                    (let ((o (make-vector (* 3 n) #f)))
                      (let loop ((i 0))
                        (if (= i n)
                            o
                            (begin
                              (vector-set! o (* 3 i)
                                           (vector-ref (vector-ref ch 6) i))
                              (vector-set! o (+ (* 3 i) 1)
                                           (vector-ref vals i))
                              (vector-set! o (+ (* 3 i) 2)
                                           (vector-ref (vector-ref ch 7) i))
                              (loop (+ i 1))))))
                    vals)))
      (append (list (vector-ref ch 0) path times out n interp)
              (if (eq? path 'weights)
                  (list 'components (vector-length (vector-ref vals 0)))
                  '()))))

  (define $rt-write-keys '(names mesh-node keep-anims? skin))

  ;; The target asset plus one clip, as GLB bytes -> (base . len),
  ;; the pair (gltf-parse base len) reads back.  The clip replaces
  ;; any the target already carries under the same name; 'keep-anims?
  ;; #f drops the rest of them.
  (define (retarget-write-glb! dst clip . opts)
    ($rt-check-options 'retarget-write-glb! $rt-write-keys opts)
    (unless (and (list? clip) (>= (length clip) 2))
      (error 'retarget-write-glb! "a clip is (name channels)" clip))
    (let* ((names ($rt-option opts 'names #f))
           (mesh-node ($rt-option opts 'mesh-node 0))
           (keep? (let ((k ($rt-option opts 'keep-anims? 'yes)))
                    (if (eq? k 'yes) #t k)))
           (si ($rt-option opts 'skin 0))
           (skins (gltf-skins dst))
           (nodes (gltf-nodes dst))
           (name (car clip))
           (old (let loop ((as (vector->list (gltf-anims dst))) (acc '()))
                  (cond ((not keep?) '())
                        ((null? as) (reverse acc))
                        ((and (string? name) (string? (vector-ref (car as) 0))
                              (string=? name (vector-ref (car as) 0)))
                         (loop (cdr as) acc))
                        (else
                         (loop (cdr as)
                               (cons (list (vector-ref (car as) 0)
                                           (map $rt-chan->desc
                                                (vector->list
                                                 (vector-ref (car as) 1))))
                                     acc)))))))
      (unless (and (integer? si) (>= si 0) (< si (vector-length skins)))
        (error 'retarget-write-glb! "the asset has no such skin" si))
      (glb-write!
       (map (lambda (p)
              (list (gprim-layout p) (gprim-vbase p)
                    (quotient (gprim-vbytes p) (gprim-stride p))
                    (gprim-ibase p) (gprim-icount p)
                    'color (gprim-color p)
                    'index-u32? (gprim-index-u32? p)))
            (gltf-prims dst))
       'nodes (let loop ((i (- (vector-length nodes) 1)) (acc '()))
                (if (< i 0)
                    acc
                    (loop (- i 1)
                          (cons ($rt-node->desc names i (vector-ref nodes i))
                                acc))))
       'mesh-node mesh-node
       'skin (list (vector-ref (vector-ref skins si) 0)
                   (vector-ref (vector-ref skins si) 1))
       'anims (append old (list (list name (cadr clip)))))))
  )
