;; expect: #t
;; RED ON PURPOSE: a non-joint node in the middle of a joint chain
;; breaks the chain, and the skeleton's bind extent is computed as if
;; the joints below it were not there.
;;
;;   Root    joint,     y = 0
;;   Helper  NOT a joint, y = +10   (a rig's alignment/IK helper)
;;   Tip     joint,     y = +1 from Helper
;;
;; The tip's world bind position is y = 11, so the extent is 11.  The
;; report says 1: the parent lookup only recognises a parent that is
;; itself a joint, so Tip is treated as a root of its own and Helper's
;; ten units never enter the world position.
;;
;; ⚠️ The extent is the denominator of the retarget ratio.  Reading it
;; as 1 instead of 11 scales every root displacement by eleven times
;; what it should be, and nothing anywhere reports a problem -- the
;; output is a valid animation of a figure moving wrongly.
;;
;; ⭐ Helper nodes between joints are not exotic.  They are how rigs
;; carry alignment, twist and IK targets, and a joint list that skips
;; them is the normal shape of an exported skin rather than a
;; malformed one.
;;
;; ⭐ The control is the same skeleton with the helper made a joint:
;; the extent must read 11 there, which is what says the difference is
;; the helper's jointness and not the geometry.  Without it, "11 is
;; wrong" and "this skeleton is unusual" cannot be told apart.
;;
;; ⚠️ If the fix is to REFUSE this skeleton rather than to walk through
;; the helper, this cell has to change shape rather than be deleted --
;; but a refusal must then be explicit, because the failure mode being
;; fixed is precisely that nothing was said.
(import (rnrs) (gfx retarget) (gfx glb) (gfx gltf) (gfx fx) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b) (< (abs (- a b)) 0.001))
(define (rep k r) (cdr (assq k r)))

(define vlayout '(position joints weights))
(define vstride (glb-stride vlayout))
(define vbase (fx-alloc! vstride))
(let fill ((i 0)) (when (< i vstride) (%mem-u8-set! (+ vbase i) 0) (fill (+ i 1))))
(%mem-f32-set! (+ vbase 28) 1.0)               ; one weight of 1.0
(define prim (list vlayout vbase 1 #f 0))

(define I (vector 0.0 0.0 0.0 1.0))
(define times2 (vector 0.0 1.0))

;; node 0 mesh, 1 Root, 2 Helper, 3 Tip
(define nodes (list (list "mesh" -1)
                    (list "Root" -1 (v3 0.0 0.0 0.0))
                    (list "Helper" 1 (v3 0.0 10.0 0.0))
                    (list "Tip" 2 (v3 0.0 1.0 0.0))))
(define anims (list (list "clip"
                          (list (list 1 'rotation times2 (vector I I) 2 'linear)
                                (list 3 'rotation times2 (vector I I) 2 'linear)))))

(define (extent-of joints)
  (let* ((loc (glb-write! (list prim) 'nodes nodes 'mesh-node 0
                          'skin (list joints #f) 'anims anims))
         (g (gltf-parse (car loc) (cdr loc)))
         (names (retarget-glb-node-names loc)))
    (rep 'extent-src (retarget-report g 0 g 'src-names names 'dst-names names))))

;; ⚠️ These report the extent they read, not whether it was right.  A
;; boolean is silent about WHAT it saw, and the number is the whole
;; diagnosis here: 1.0 says the helper's translation was skipped, and
;; some third value would say something else is wrong and this cell had
;; better be re-read rather than believed.
(define (extent-reading joints)
  (let ((e (extent-of joints)))
    (if (near? e 11.0) 'eleven e)))

;; ---- red: the helper is not a joint ----
(want 'g17-extent-through-helper (extent-reading '(1 3)) 'eleven)

;; ---- control: the same geometry with the helper joined ----
(want 'g17-CONTROL-helper-as-joint (extent-reading '(1 2 3)) 'eleven)

(if (null? fails) (display #t) (begin (display fails) (newline)))
