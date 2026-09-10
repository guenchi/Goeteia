;; expect: #t
;; RED ON PURPOSE: writing a retargeted clip back out moves the mesh to
;; node 0 and rebuilds each primitive from a handful of fields, so
;; everything not in that handful is gone from the file.
;;
;; The write path takes 'mesh-node from its options and defaults it to
;; 0 -- not to where the primitive actually was.  A mesh parented to
;; a node with a transform comes back parented to the root, and the
;; model is somewhere else.  Nothing is reported: the file is valid,
;; the animation is correct, and the figure stands in the wrong place.
;;
;; And the primitive is reassembled as layout, vertex base, count,
;; index base, index count, colour and index width.  A material index,
;; a base-colour texture, morph targets, a per-primitive skin: none of
;; those are read, so none of them are written.  Losing them is
;; quieter than moving the mesh, because the result still renders --
;; untextured, unlit, in the default material -- and looks like an
;; asset problem rather than a writer problem.
;;
;; THIS IS AN EXPORT PATH.  The failure is a file, and it is
;; discovered by whoever opens that file, with no way back to what made
;; it.  Same shape as the GLB writer accepting invalid times
;; (defect-g15): a writer that silently drops what it cannot carry
;; hands the diagnosis to the person least able to make it.
;;
;; gltf-prims answers a LIST.  Reading it with vector-ref is an
;; illegal cast, which is a trap, which takes the file's whole verdict
;; -- so a first draft of this cell reported nothing at all and looked
;; like a library that could not read its own output.  Three times
;; tonight the trap in a cell was the cell's own code; each time the
;; first reading pointed at the library.
;;
;; The controls are the fields the writer DOES carry, so a red says
;; which half is broken rather than "the round trip is broken": vertex
;; count and the base-colour factor survive, and passing 'mesh-node
;; explicitly puts the mesh back where it belongs -- which is what says
;; the default is the defect rather than the write itself.
(import (rnrs) (gfx retarget) (gfx glb) (gfx gltf) (gfx fx) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b) (< (abs (- a b)) 0.001))

(define vlayout '(position joints weights))
(define vstride (glb-stride vlayout))
(define vbase (fx-alloc! vstride))
(let fill ((i 0)) (when (< i vstride) (%mem-u8-set! (+ vbase i) 0) (fill (+ i 1))))
(%mem-f32-set! (+ vbase 28) 1.0)
(define I (vector 0.0 0.0 0.0 1.0))
(define times2 (vector 0.0 1.0))

;; node 0 is an empty root; the mesh hangs off node 1, which is moved
(define nodes (list (list "root" -1)
                    (list "carrier" 0 (v3 0.0 5.0 0.0))
                    (list "Root" -1 (v3 0.0 0.0 0.0))
                    (list "Tip" 2 (v3 0.0 1.0 0.0))))
(define anims (list (list "clip"
                          (list (list 2 'rotation times2 (vector I I) 2 'linear)
                                (list 3 'rotation times2 (vector I I) 2 'linear)))))
(define prim (list vlayout vbase 1 #f 0 'color (vector 0.25 0.5 0.75 1.0)))

(define src-loc (glb-write! (list prim) 'nodes nodes 'mesh-node 1
                            'skin (list '(2 3) #f) 'anims anims))
(define g (gltf-parse (car src-loc) (cdr src-loc)))
(define names (retarget-glb-node-names src-loc))

(want 'g18-SETUP-source-node (gprim-node (car (gltf-prims g))) 1)

(define clip (retarget-clip! g 0 g 'src-names names 'dst-names names))
(define out-loc (retarget-write-glb! g clip))
(define g2 (gltf-parse (car out-loc) (cdr out-loc)))
(define p2 (car (gltf-prims g2)))

;; ---- controls: what the writer does carry ----
(want 'g18-CONTROL-vertex-count (gprim-vcount p2) 1)
(want 'g18-CONTROL-base-colour
      (near? (vector-ref (gprim-base-color-factor p2) 2) 0.75) #t)
(let* ((fixed (retarget-write-glb! g clip 'mesh-node 1))
       (g3 (gltf-parse (car fixed) (cdr fixed))))
  (want 'g18-CONTROL-explicit-mesh-node
        (gprim-node (car (gltf-prims g3))) 1))

;; ---- red ----
(want 'g18-mesh-stays-on-its-node (gprim-node p2) 1)

(if (null? fails) (display #t) (begin (display fails) (newline)))
