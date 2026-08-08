;; expect: #t palette-fnv=2458211706
;; (gfx retarget): one clip moved from one skeleton onto another,
;; with the target's bone lengths intact.
;;
;; Every fixture is built here with (gfx glb) and read back with
;; (gfx gltf), so the test depends on no file and no process.  The
;; source skeleton is deliberately NOT a straight chain -- the root
;; chain rule ("from each root down to and including the first
;; joint that does not have exactly one child") is only tested by a
;; skeleton that branches, and only the joints ON that chain may
;; receive a translation track:
;;
;;   node 0  mesh                     a root
;;   node 1  Root   parent -1   t (0,     0,   0)    1 child
;;   node 2  Hips   parent 1    t (0,     2,   0)    2 children  <- branch
;;   node 3  Spine  parent 2    t (0,   1.5,   0)    leaf
;;   node 4  Leg    parent 2    t (4,    -1, 0.5)    leaf
;;
;; so the root chain is Root, Hips and the bones that must not
;; change length are Spine (1.5) and Leg (sqrt 17.25).  The bind
;; world positions are (0,0,0) (0,2,0) (0,3.5,0) (4,1,0.5): the
;; LARGEST axis span is x = 4, not the vertical 3.5, which is what
;; pins "extent is the largest of the three spans" rather than "the
;; height".
;;
;; Clip "walk", three keys at t = 0,1,2 on every channel, so the
;; sample grid is exactly {0,1,2} and every sampled value is a key
;; value rather than an interpolation of one.  The quaternions are
;; chosen to be exactly unit in both f32 and f64 (all components
;; +-0.5, or the identity), so "identical" below means bit-for-bit
;; and not "within an epsilon of".
;;
;;   Root  translation  (0,0,0)  (0,0,1)  (0,0,2)
;;   Hips  translation  (0,2,0)  (1,3,0)  (0,2,0)
;;   Hips  rotation      I        Qa       I
;;   Spine rotation      I        I        Qb
;;   Leg   rotation      Qc       I        I
;;
;; Hips rotating while Spine and Leg hang off it is what makes a
;; WORLD rotation differ from the LOCAL one, so writing the wrong
;; one of the two shows up as a different pose rather than as a
;; rounding difference.
;;
;; Clip "melt" drives a translation channel on Spine -- a joint
;; BELOW the root chain.  A retarget that carries it across changes
;; the bone's length; this one drops it, and the target's Spine
;; keeps its bind offset at every frame.
(import (rnrs) (gfx fx) (gfx mat) (gfx gltf) (gfx glb) (gfx retarget)
        (web json))

;; ---- helpers ----------------------------------------------------
(define (fl-abs x) (if (fl<? x 0.0) (fl- 0.0 x) x))
(define tiny 0.000000001)

(define (close? a b)
  (and (= (vector-length a) (vector-length b))
       (let loop ((i 0))
         (or (= i (vector-length a))
             (and (fl<? (fl-abs (fl- (vector-ref a i) (vector-ref b i)))
                        tiny)
                  (loop (+ i 1)))))))

(define (near? a b) (fl<? (fl-abs (fl- a b)) 0.0001))

;; every element of a channel's values, against a list of expected
(define (series? vals want)
  (and (= (vector-length vals) (length want))
       (let loop ((i 0) (w want))
         (or (null? w)
             (and (close? (vector-ref vals i) (car w))
                  (loop (+ i 1) (cdr w)))))))

(define (constant? vals v)
  (let loop ((i 0))
    (or (= i (vector-length vals))
        (and (close? (vector-ref vals i) v) (loop (+ i 1))))))

;; a produced clip is (name channels); a channel is
;; (node path times values count 'interpolation 'linear)
(define (clip-name cl) (car cl))
(define (clip-chans cl) (cadr cl))
(define (chan cl node path)
  (let loop ((cs (clip-chans cl)))
    (cond ((null? cs) #f)
          ((and (= (car (car cs)) node) (eq? (cadr (car cs)) path))
           (car cs))
          (else (loop (cdr cs))))))
(define (ctimes c) (list-ref c 2))
(define (cvals c) (list-ref c 3))
(define (ccount c) (list-ref c 4))
(define (nchans cl) (length (clip-chans cl)))

(define (rot cl node) (chan cl node 'rotation))
(define (trn cl node) (chan cl node 'translation))

(define (rep k r) (cdr (assq k r)))

;; ---- the shared vertex block ------------------------------------
;; One skinned vertex is enough: the writer needs a primitive, and
;; nothing here reads it back.
(define vlayout '(position joints weights))
(define vstride (glb-stride vlayout))          ; 44
(define vbase (fx-alloc! vstride))
(%mem-f32-set! vbase 0.0)
(%mem-f32-set! (+ vbase 4) 0.0)
(%mem-f32-set! (+ vbase 8) 0.0)
(%mem-f32-set! (+ vbase 12) 0.0)               ; joints
(%mem-f32-set! (+ vbase 16) 0.0)
(%mem-f32-set! (+ vbase 20) 0.0)
(%mem-f32-set! (+ vbase 24) 0.0)
(%mem-f32-set! (+ vbase 28) 1.0)               ; weights
(%mem-f32-set! (+ vbase 32) 0.0)
(%mem-f32-set! (+ vbase 36) 0.0)
(%mem-f32-set! (+ vbase 40) 0.0)
(define prim (list vlayout vbase 1 #f 0))

;; ---- the pose vocabulary ----------------------------------------
(define I  (vector 0.0 0.0 0.0 1.0))
(define Qa (vector 0.5 0.5 0.5 0.5))
(define Qb (vector 0.5 -0.5 0.5 0.5))
(define Qc (vector -0.5 0.5 0.5 0.5))
(define nQa (vector -0.5 -0.5 -0.5 -0.5))
(define (v3 x y z) (vector x y z))

(define times3 (vector 0.0 1.0 2.0))
(define times2 (vector 0.0 1.0))

(define src-nodes
  (list (list "mesh" -1)
        (list "Root" -1 (v3 0.0 0.0 0.0))
        (list "Hips" 1 (v3 0.0 2.0 0.0))
        (list "Spine" 2 (v3 0.0 1.5 0.0))
        (list "Leg" 2 (v3 4.0 -1.0 0.5))))

(define src-skin (list (list 1 2 3 4) #f))

(define src-anims
  (list
   (list "walk"
         (list (list 1 'translation times3
                     (vector (v3 0.0 0.0 0.0) (v3 0.0 0.0 1.0)
                             (v3 0.0 0.0 2.0)) 3 'linear)
               (list 2 'translation times3
                     (vector (v3 0.0 2.0 0.0) (v3 1.0 3.0 0.0)
                             (v3 0.0 2.0 0.0)) 3 'linear)
               (list 2 'rotation times3 (vector I Qa I) 3 'linear)
               (list 3 'rotation times3 (vector I I Qb) 3 'linear)
               (list 4 'rotation times3 (vector Qc I I) 3 'linear)))
   (list "melt"
         (list (list 3 'translation times2
                     (vector (v3 0.0 1.5 0.0) (v3 0.0 3.0 0.0)) 2 'linear)
               (list 2 'rotation times2 (vector I Qa) 2 'linear)))
   ;; -Qa is the same rotation as Qa spelled in the other
   ;; hemisphere; a reader that lerps between I and -Qa takes the
   ;; long way round, so the written track has to come back to one
   ;; hemisphere
   (list "flip"
         (list (list 2 'rotation times2 (vector I nQa) 2 'linear)))))

(define src-loc (glb-write! (list prim) 'nodes src-nodes 'mesh-node 0
                            'skin src-skin 'anims src-anims))
(define gsrc (gltf-parse (car src-loc) (cdr src-loc)))
(define src-names (retarget-glb-node-names src-loc))

;; the names came back out of the file the loader dropped them from
(define names-ok
  (and (= (vector-length src-names) 5)
       (equal? (vector-ref src-names 1) "Root")
       (equal? (vector-ref src-names 4) "Leg")))

;; ---- name normalisation on its own ------------------------------
;; Namespace (both spellings), separators, casing and rig prefix.
(define normalize-ok
  (and (string=? (retarget-normalize-name "mixamorig:Hips") "hips")
       (string=? (retarget-normalize-name "rig|Hips") "hips")
       (string=? (retarget-normalize-name "Bip01-L-Hand") "lhand")
       (string=? (retarget-normalize-name "BIPED_L_HAND") "lhand")
       (string=? (retarget-normalize-name "bip01.l.hand") "lhand")
       (string=? (retarget-normalize-name "Bip01_SPINE") "spine")
       ;; longest-first: bip001 is not half-eaten by bip01's stem
       (string=? (retarget-normalize-name "bip001Spine") "spine")
       ;; a prefix that IS the whole name is not a prefix
       (string=? (retarget-normalize-name "rig") "rig")
       (string=? (retarget-normalize-name "Root") "root")))

;; ================================================================
;; (a) self-retarget is the identity
;; ================================================================
(define clip-a (retarget-clip! gsrc 0 gsrc
                               'src-names src-names 'dst-names src-names))
(define rep-a (retarget-report gsrc 0 gsrc
                               'src-names src-names 'dst-names src-names))

(define ident-ok
  (and (equal? (clip-name clip-a) "walk")
       ;; four rotation channels, two translation ones -- Spine and
       ;; Leg are below the branch and get none
       (= (nchans clip-a) 6)
       (not (trn clip-a 3))
       (not (trn clip-a 4))
       (equal? (ctimes (rot clip-a 1)) times3)
       (equal? (ctimes (trn clip-a 2)) times3)
       (= (ccount (rot clip-a 1)) 3)
       ;; the source's own key times, so the resample is exact
       (near? (rep 'ratio rep-a) 1.0)
       (near? (rep 'extent-src rep-a) 4.0)
       (near? (rep 'extent-dst rep-a) 4.0)
       (= (rep 'mapped rep-a) 4)
       (= (rep 'by-name rep-a) 4)
       (= (rep 'explicit rep-a) 0)
       (equal? (rep 'translate rep-a) '(0 1))
       (null? (rep 'ambiguous rep-a))
       ;; the poses themselves
       (series? (cvals (rot clip-a 1)) (list I I I))
       (series? (cvals (rot clip-a 2)) (list I Qa I))
       (series? (cvals (rot clip-a 3)) (list I I Qb))
       (series? (cvals (rot clip-a 4)) (list Qc I I))
       (series? (cvals (trn clip-a 1))
                (list (v3 0.0 0.0 0.0) (v3 0.0 0.0 1.0) (v3 0.0 0.0 2.0)))
       (series? (cvals (trn clip-a 2))
                (list (v3 0.0 2.0 0.0) (v3 1.0 3.0 0.0) (v3 0.0 2.0 0.0)))))

;; with no names at all both skeletons fall back to nodeN, so a
;; retarget onto the same topology still maps position for position
(define nameless-ok
  (let ((r (retarget-report gsrc 0 gsrc)))
    (and (= (rep 'mapped r) 4) (= (rep 'by-name r) 4))))

;; ================================================================
;; (b) a target scaled 1.5x and renamed
;; ================================================================
;; Same topology, every bind translation x1.5, and four spellings
;; the by-name rule has to see through: two namespaces (: and |), a
;; rig prefix, and casing.
(define b-nodes
  (list (list "mesh" -1)
        (list "mixamorig:ROOT" -1 (v3 0.0 0.0 0.0))
        (list "mixamorig:Hips" 1 (v3 0.0 3.0 0.0))
        (list "Bip01_SPINE" 2 (v3 0.0 2.25 0.0))
        (list "RIG|leg" 2 (v3 6.0 -1.5 0.75))))
(define b-loc (glb-write! (list prim) 'nodes b-nodes 'mesh-node 0
                          'skin src-skin))
(define gb (gltf-parse (car b-loc) (cdr b-loc)))
(define b-names (retarget-glb-node-names b-loc))

(define clip-b (retarget-clip! gsrc 0 gb
                               'src-names src-names 'dst-names b-names))
(define rep-b (retarget-report gsrc 0 gb
                               'src-names src-names 'dst-names b-names))

(define scaled-ok
  (and (= (rep 'mapped rep-b) 4)
       (= (rep 'by-name rep-b) 4)
       (= (rep 'unmapped rep-b) 0)
       (near? (rep 'extent-src rep-b) 4.0)
       (near? (rep 'extent-dst rep-b) 6.0)
       (near? (rep 'ratio rep-b) 1.5)
       (equal? (rep 'translate rep-b) '(0 1))
       (= (nchans clip-b) 6)
       ;; the pose angles are the SOURCE's, verbatim and local
       (series? (cvals (rot clip-b 2)) (list I Qa I))
       (series? (cvals (rot clip-b 3)) (list I I Qb))
       (series? (cvals (rot clip-b 4)) (list Qc I I))
       ;; root motion scaled: t_dst = t_dst_bind + (t_src - t_src_bind)*1.5
       (series? (cvals (trn clip-b 1))
                (list (v3 0.0 0.0 0.0) (v3 0.0 0.0 1.5) (v3 0.0 0.0 3.0)))
       (series? (cvals (trn clip-b 2))
                (list (v3 0.0 3.0 0.0) (v3 1.5 4.5 0.0) (v3 0.0 3.0 0.0)))
       ;; and nothing at all below the branch
       (not (trn clip-b 3))
       (not (trn clip-b 4))))

;; the clip that tries to melt it: the source drives Spine's
;; TRANSLATION, which is a bone length, and it must not travel
(define clip-melt (retarget-clip! gsrc 1 gb
                                  'src-names src-names 'dst-names b-names))
(define melt-ok
  (and (equal? (clip-name clip-melt) "melt")
       (= (ccount (rot clip-melt 3)) 2)
       (not (trn clip-melt 3))
       (not (trn clip-melt 4))
       (series? (cvals (rot clip-melt 2)) (list I Qa))))

;; ================================================================
;; (c) a denser target: two joints the source does not have
;; ================================================================
;;   Root -> Hips -> Spine1(new) -> Spine
;;                -> Leg1(new)   -> Leg
;; The new joints are spelled so they do NOT fold onto the source's
;; ("spine1" is not "spine"), and the halved offsets keep the bind
;; extent at 4 so the ratio stays exactly 1.
(define c-nodes
  (list (list "mesh" -1)
        (list "Root" -1 (v3 0.0 0.0 0.0))
        (list "Hips" 1 (v3 0.0 2.0 0.0))
        (list "Spine1" 2 (v3 0.0 0.75 0.0))
        (list "Spine" 3 (v3 0.0 0.75 0.0))
        (list "Leg1" 2 (v3 2.0 -0.5 0.25))
        (list "Leg" 5 (v3 2.0 -0.5 0.25))))
(define c-loc (glb-write! (list prim) 'nodes c-nodes 'mesh-node 0
                          'skin (list (list 1 2 3 4 5 6) #f)))
(define gc (gltf-parse (car c-loc) (cdr c-loc)))
(define c-names (retarget-glb-node-names c-loc))

(define clip-c (retarget-clip! gsrc 0 gc
                               'src-names src-names 'dst-names c-names))
(define rep-c (retarget-report gsrc 0 gc
                               'src-names src-names 'dst-names c-names))

(define dense-ok
  (and (= (rep 'dst-joints rep-c) 6)
       (= (rep 'mapped rep-c) 4)
       (= (rep 'unmapped rep-c) 2)
       (equal? (rep 'unmapped-joints rep-c) '(2 4))   ; Spine1, Leg1
       (near? (rep 'ratio rep-c) 1.0)
       (equal? (rep 'translate rep-c) '(0 1))
       ;; six rotation channels, two translation ones
       (= (nchans clip-c) 8)
       ;; the mapped joints carry the source's angles
       (series? (cvals (rot clip-c 4)) (list I I Qb))   ; Spine
       (series? (cvals (rot clip-c 6)) (list Qc I I))   ; Leg
       ;; the new joints hold bind: a constant rotation track and no
       ;; translation track at all
       (constant? (cvals (rot clip-c 3)) I)
       (constant? (cvals (rot clip-c 5)) I)
       (not (trn clip-c 3))
       (not (trn clip-c 5))
       (series? (cvals (trn clip-c 2))
                (list (v3 0.0 2.0 0.0) (v3 1.0 3.0 0.0) (v3 0.0 2.0 0.0)))))

;; ================================================================
;; (d) an explicit map over names that share nothing
;; ================================================================
(define d-nodes
  (list (list "mesh" -1)
        (list "alpha" -1 (v3 0.0 0.0 0.0))
        (list "beta" 1 (v3 0.0 2.0 0.0))
        (list "gamma" 2 (v3 0.0 1.5 0.0))
        (list "delta" 2 (v3 4.0 -1.0 0.5))))
(define d-loc (glb-write! (list prim) 'nodes d-nodes 'mesh-node 0
                          'skin src-skin))
(define gd (gltf-parse (car d-loc) (cdr d-loc)))
(define d-names (retarget-glb-node-names d-loc))

(define d-map '(("Hips" . "beta") ("Spine" . "gamma")))
(define clip-d (retarget-clip! gsrc 0 gd 'map d-map
                               'src-names src-names 'dst-names d-names))
(define rep-d (retarget-report gsrc 0 gd 'map d-map
                               'src-names src-names 'dst-names d-names))

(define explicit-ok
  (and (= (rep 'mapped rep-d) 2)
       (= (rep 'explicit rep-d) 2)
       (= (rep 'by-name rep-d) 0)
       (equal? (rep 'unmapped-joints rep-d) '(0 3))   ; alpha, delta
       ;; alpha is ON the root chain but is NOT mapped, so it gets
       ;; no translation track: the set is chain AND mapped
       (equal? (rep 'translate rep-d) '(1))
       (= (nchans clip-d) 5)
       (not (trn clip-d 1))
       (series? (cvals (trn clip-d 2))
                (list (v3 0.0 2.0 0.0) (v3 1.0 3.0 0.0) (v3 0.0 2.0 0.0)))
       ;; the two mapped joints move
       (series? (cvals (rot clip-d 2)) (list I Qa I))
       (series? (cvals (rot clip-d 3)) (list I I Qb))
       ;; the other two hold bind
       (constant? (cvals (rot clip-d 1)) I)
       (constant? (cvals (rot clip-d 4)) I)))

;; ================================================================
;; the hemisphere rule, the clip name, the uniform grid, and a
;; source whose own names collide
;; ================================================================
;; One hemisphere per track: -Qa goes in, +Qa comes out, because
;; every reader lerps between consecutive keys and I -> -Qa is the
;; same rotation taken the long way.
(define clip-f (retarget-clip! gsrc 2 gb
                               'src-names src-names 'dst-names b-names))
(define hemisphere-ok
  (and (equal? (clip-name clip-f) "flip")
       (series? (cvals (rot clip-f 2)) (list I Qa))))

;; 'clip-name renames without touching anything else
(define renamed-ok
  (let ((c (retarget-clip! gsrc 0 gb 'clip-name "run"
                           'src-names src-names 'dst-names b-names)))
    (and (equal? (clip-name c) "run")
         (series? (cvals (rot c 2)) (list I Qa I)))))

;; 'samples asks for a uniform grid instead of the source's keys
(define samples-ok
  (let ((c (retarget-clip! gsrc 0 gb 'samples 5
                           'src-names src-names 'dst-names b-names)))
    (and (= (ccount (rot c 2)) 5)
         (close? (ctimes (rot c 2)) (vector 0.0 0.5 1.0 1.5 2.0))
         ;; halfway between I and Qa on a uniform grid is neither
         (series? (cvals (trn c 1))
                  (list (v3 0.0 0.0 0.0) (v3 0.0 0.0 0.75) (v3 0.0 0.0 1.5)
                        (v3 0.0 0.0 2.25) (v3 0.0 0.0 3.0))))))

;; Two source joints folding to one key: the first wins and the
;; collision is reported rather than decided by joint order in
;; silence.
(define amb-nodes
  (list (list "mesh" -1)
        (list "Hips" -1 (v3 0.0 0.0 0.0))
        (list "mixamorig:HIPS" 1 (v3 0.0 1.0 0.0))))
(define amb-loc (glb-write! (list prim) 'nodes amb-nodes 'mesh-node 0
                            'skin (list (list 1 2) #f)
                            'anims (list (list "a"
                                               (list (list 2 'rotation times2
                                                           (vector I Qa) 2
                                                           'linear))))))
(define gamb (gltf-parse (car amb-loc) (cdr amb-loc)))
(define amb-names (retarget-glb-node-names amb-loc))
(define ambiguous-ok
  (let ((r (retarget-report gamb 0 gamb
                            'src-names amb-names 'dst-names amb-names)))
    (and (= (length (rep 'ambiguous r)) 1)
         (equal? (car (rep 'ambiguous r)) '("Hips" "mixamorig:HIPS"))
         ;; both targets fall on the first source joint
         (equal? (rep 'pairs r) '((0 . 0) (1 . 0))))))

;; 'map beats the name rule where the two disagree: on the (b)
;; target every joint ALSO matches by name, and the entry sending
;; the source's Leg to Bip01_SPINE has to win over the Spine that
;; folds onto the same key.
(define clip-p (retarget-clip! gsrc 0 gb 'map '(("Leg" . "Bip01_SPINE"))
                               'src-names src-names 'dst-names b-names))
(define rep-p (retarget-report gsrc 0 gb 'map '(("Leg" . "Bip01_SPINE"))
                               'src-names src-names 'dst-names b-names))
(define priority-ok
  (and (= (rep 'explicit rep-p) 1)
       (= (rep 'by-name rep-p) 3)
       (equal? (rep 'pairs rep-p) '((0 . 0) (1 . 1) (2 . 3) (3 . 3)))
       ;; node 3 now carries the source's LEG angles, not Spine's
       (series? (cvals (rot clip-p 3)) (list Qc I I))))

;; a list-shaped map entry reaches the same place as a pair-shaped one
(define map-shape-ok
  (equal? (rep 'pairs
               (retarget-report gsrc 0 gd 'map '(("Hips" "beta"))
                                'src-names src-names 'dst-names d-names))
          '((1 . 1))))

;; ================================================================
;; (e) the refusals, each one named
;; ================================================================
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk)
    #f))

(define refuse-ok
  (and ;; a map entry naming a joint the source lacks
       (refused? 'retarget-clip!
                 (lambda ()
                   (retarget-clip! gsrc 0 gd 'map '(("NoSuchBone" . "beta"))
                                   'src-names src-names
                                   'dst-names d-names)))
       ;; ... or one the target lacks
       (refused? 'retarget-clip!
                 (lambda ()
                   (retarget-clip! gsrc 0 gd 'map '(("Hips" . "omega"))
                                   'src-names src-names
                                   'dst-names d-names)))
       ;; a clip index past the source's animations
       (refused? 'retarget-clip!
                 (lambda () (retarget-clip! gsrc 5 gb
                                            'src-names src-names
                                            'dst-names b-names)))
       (refused? 'retarget-clip!
                 (lambda () (retarget-clip! gsrc -1 gb)))
       ;; a skin the asset lacks
       (refused? 'retarget-clip!
                 (lambda () (retarget-clip! gsrc 0 gb 'dst-skin 3)))
       ;; an unknown option, rather than a silently ignored one
       (refused? 'retarget-clip!
                 (lambda () (retarget-clip! gsrc 0 gb 'mapp d-map)))
       ;; and the report answers to the same rules under its own name
       (refused? 'retarget-report
                 (lambda () (retarget-report gsrc 9 gb)))))

;; ================================================================
;; (f) the round trip: the produced clip, written out and read back
;; ================================================================
(define out-loc (retarget-write-glb! gb clip-b 'names b-names))
(define gout (gltf-parse (car out-loc) (cdr out-loc)))
(define out-json
  (let* ((base (car out-loc))
         (n (+ (%mem-u8-ref (+ base 12))
               (* 256 (%mem-u8-ref (+ base 13)))
               (* 65536 (%mem-u8-ref (+ base 14)))
               (* 16777216 (%mem-u8-ref (+ base 15)))))
         (s (make-string n #\space)))
    (let loop ((i 0))
      (if (= i n)
          (string->json s)
          (begin (string-set! s i (integer->char (%mem-u8-ref (+ base 20 i))))
                 (loop (+ i 1)))))))

;; the names survive, so a second retarget off this file still has
;; something to match on
(define written-ok
  (and (equal? (gltf-animation-names gout) '("walk"))
       (near? (gltf-animation-duration gout 0) 2.0)
       (= (vector-length (json-ref out-json "nodes")) 5)
       (equal? (json-ref out-json "nodes" 3 "name") "Bip01_SPINE")
       (equal? (json-ref out-json "skins" 0 "joints") (vector 1 2 3 4))
       ;; six samplers: four rotations and two translations
       (= (vector-length (json-ref out-json "animations" 0 "samplers")) 6)
       (equal? (retarget-glb-node-names out-loc) b-names)))

;; joint world positions: the inverse binds are identity, so the
;; palette IS the run of global matrices
(define (jpos g k)
  (let ((m (vector-ref (gltf-joint-matrices g 0) k)))
    (vector (vector-ref m 12) (vector-ref m 13) (vector-ref m 14))))

(define (dist a b)
  (let ((dx (fl- (vector-ref a 0) (vector-ref b 0)))
        (dy (fl- (vector-ref a 1) (vector-ref b 1)))
        (dz (fl- (vector-ref a 2) (vector-ref b 2))))
    (flsqrt (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz)))))

;; Closed form at t = 1: Root is at (0,0,1.5); Hips sits 1.5x the
;; source's displacement away at (1.5,4.5,1.5) with rotation Qa,
;; which is the 120-degree turn about (1,1,1) taking (a,b,c) to
;; (c,a,b).  Spine and Leg keep their BIND offsets, turned by Qa:
;;   Spine (1.5,4.5,1.5) + Qa*(0,2.25,0)  = (1.5,4.5,3.75)
;;   Leg   (1.5,4.5,1.5) + Qa*(6,-1.5,.75) = (2.25,10.5,0)
(define pose-ok
  (begin
    (gltf-animate! gout 0 1.0)
    (and (close? (jpos gout 0) (v3 0.0 0.0 1.5))
         (close? (jpos gout 1) (v3 1.5 4.5 1.5))
         (close? (jpos gout 2) (v3 1.5 4.5 3.75))
         (close? (jpos gout 3) (v3 2.25 10.5 0.0)))))

;; The bone lengths, every frame and between frames.  2.25 is the
;; target's own Spine offset and sqrt(38.8125) its own Leg offset;
;; neither appears anywhere in the source.
(define leg-len (flsqrt 38.8125))
(define lengths-ok
  (let loop ((ts (list 0.0 0.4 1.0 1.5 1.9999)))
    (or (null? ts)
        (begin
          (gltf-animate! gout 0 (car ts))
          (and (near? (dist (jpos gout 1) (jpos gout 2)) 2.25)
               (near? (dist (jpos gout 1) (jpos gout 3)) leg-len)
               (loop (cdr ts)))))))

;; the melting clip, written onto the same target, still cannot
;; stretch a bone
(define melt-loc (retarget-write-glb! gb clip-melt 'names b-names))
(define gmelt (gltf-parse (car melt-loc) (cdr melt-loc)))
(define melt-len-ok
  (let loop ((ts (list 0.0 0.5 0.9999)))
    (or (null? ts)
        (begin
          (gltf-animate! gmelt 0 (car ts))
          (and (near? (dist (jpos gmelt 1) (jpos gmelt 2)) 2.25)
               (loop (cdr ts)))))))

;; existing clips are kept, and one of the same name replaced
(define keep-ok
  (let* ((two (retarget-write-glb! gout clip-melt 'names b-names))
         (g2 (gltf-parse (car two) (cdr two)))
         (one (retarget-write-glb! gout clip-b 'names b-names))
         (g1 (gltf-parse (car one) (cdr one))))
    (and (equal? (gltf-animation-names g2) '("walk" "melt"))
         (equal? (gltf-animation-names g1) '("walk")))))

;; ================================================================
;; the cross-check port: FNV-1a over the (b) palette at t = 1
;; ================================================================
;; The palette is 4 joint matrices of 16 float32s, hashed as bytes,
;; so the number is the same on every host and comparable with a
;; second implementation of the same rule.  The xor is applied to
;; the low byte alone -- the operands stay under 2^29 that way, and
;; the multiply is plain integer arithmetic modulo 2^32.
(define (fnv1a base n)
  (let loop ((i 0) (h 2166136261))
    (if (= i n)
        h
        (let* ((b (%mem-u8-ref (+ base i)))
               (lo (remainder h 256))
               (x (+ (- h lo) (bitwise-xor lo b))))
          (loop (+ i 1) (remainder (* x 16777619) 4294967296))))))

(define palette-fnv
  (begin
    (gltf-animate! gout 0 1.0)
    (fnv1a (gltf-joint-palette! gout 0) (* 64 (gltf-joint-count gout 0)))))

(display (and names-ok normalize-ok ident-ok nameless-ok scaled-ok
              melt-ok dense-ok explicit-ok map-shape-ok refuse-ok
              hemisphere-ok renamed-ok samples-ok ambiguous-ok priority-ok
              written-ok pose-ok lengths-ok melt-len-ok keep-ok))
(display " palette-fnv=")
(display palette-fnv)
