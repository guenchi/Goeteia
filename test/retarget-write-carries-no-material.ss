;; expect: #t
;; retarget-write-glb! writes each primitive with its colour and nothing
;; else of its material, and an absent baseColorFactor comes back as
;; an explicit white.
;;
;; The writer rebuilds each primitive from its layout, vertices,
;; indices, node and its current rendering colour (gprim-color), and
;; writes that colour as the material's baseColorFactor.  Metallic,
;; roughness, emissive and every texture slot are not read and so not
;; written; the primitive comes back in a material that has only the
;; colour.  The rows read the factors and two of the five texture slots
;; (base colour and metallic-roughness); the other three go the same way
;; in the writer -- retarget.ss hands glb-write! no material at all --
;; and are not read here.  This is what docs/api.md says of retarget-write-glb!, and
;; this cell is what keeps that sentence true: a writer that started
;; carrying the material would turn these rows red and the sentence
;; would have to change with it.
;;
;; AN ABSENT FACTOR BECOMES AN EXPLICIT WHITE.  A primitive whose
;; material wrote no baseColorFactor renders as white -- glTF's default
;; -- and is written back with baseColorFactor (1 1 1 1), which glTF
;; defines as the same colour.  Ruled 2026-10-21: keep it so, rather
;; than add a rule that would omit the key only when the colour is
;; still the default, on an export path that does not carry the
;; material at all.
(import (rnrs) (gfx retarget) (gfx glb) (gfx gltf) (gfx fx) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b) (< (abs (- a b)) 0.001))
(define (vnear? v w)
  (and (vector? v) (= (vector-length v) (vector-length w))
       (let loop ((i 0))
         (or (= i (vector-length v))
             (and (near? (vector-ref v i) (vector-ref w i)) (loop (+ i 1)))))))

;; one skinned vertex with a uv, so that a texture can be referred to;
;; the setup otherwise follows defect-g18-write-glb-loses-placement.ss
(define vlayout '(position normal uv joints weights))
(define vstride (glb-stride vlayout))
(define vbase (fx-alloc! vstride))
(let fill ((i 0)) (when (< i vstride) (%mem-u8-set! (+ vbase i) 0) (fill (+ i 1))))
(%mem-f32-set! (+ vbase (glb-offset vlayout 'weights)) 1.0)
;; a tiny fake PNG, as test/glb-mat.ss writes one
(define png (bytevector #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A 1 2 3 4))
(define I (vector 0.0 0.0 0.0 1.0))
(define times2 (vector 0.0 1.0))
(define nodes (list (list "root" -1)
                    (list "Root" -1 (v3 0.0 0.0 0.0))
                    (list "Tip" 1 (v3 0.0 1.0 0.0))))
(define anims (list (list "clip"
                          (list (list 1 'rotation times2 (vector I I) 2 'linear)
                                (list 2 'rotation times2 (vector I I) 2 'linear)))))

;; A material is (color (metallic . roughness) emissive base mr normal
;; emissive occlusion); #f for the colour leaves baseColorFactor out.
(define (round-trip material . images)
  (let* ((src (apply glb-write! (list (list vlayout vbase 1 #f 0 'material 0))
                     'materials (list material)
                     'nodes nodes 'mesh-node 0
                     'skin (list '(1 2) #f) 'anims anims
                     (if (null? images)
                         '()
                         (list 'images (list (list png "image/png")) 'textures '((0 . #f))))))
         (g (gltf-parse (car src) (cdr src)))
         (names (retarget-glb-node-names src))
         (clip (retarget-clip! g 0 g 'src-names names 'dst-names names))
         (out (retarget-write-glb! g clip))
         (g2 (gltf-parse (car out) (cdr out))))
    (list (car (gltf-prims g)) (car (gltf-prims g2)))))

;; A material with every factor away from its default.
(let* ((pp (round-trip (list (vector 0.25 0.5 0.75 1.0) (cons 0.2 0.7) (vector 0.5 0.0 0.0)
                             #f #f #f #f #f)))
       (before (car pp)) (after (cadr pp)))
  (want "CONTROL the source carries the metallic factor it was written with"
        (near? (gprim-metallic before) 0.2) #t)
  (want "CONTROL and the emissive factor"
        (vnear? (gprim-emissive before) (vector 0.5 0.0 0.0)) #t)
  (want "the colour is carried" (vnear? (gprim-color after) (vector 0.25 0.5 0.75 1.0)) #t)
  (want "the metallic factor is not carried: it reads as glTF's default 1"
        (near? (gprim-metallic after) 1.0) #t)
  (want "the roughness factor is not carried: it reads as glTF's default 1"
        (near? (gprim-roughness after) 1.0) #t)
  (want "the emissive factor is not carried: it reads as glTF's default black"
        (vnear? (gprim-emissive after) (vector 0.0 0.0 0.0)) #t))

;; A material with a base colour texture and a metallic-roughness texture.
(let* ((pp (round-trip (list (vector 1.0 1.0 1.0 1.0) (cons 1.0 1.0) (vector 0.0 0.0 0.0)
                             '(0 0 1.0) '(0 0 1.0) #f #f #f)
                       'with-image))
       (before (car pp)) (after (cadr pp)))
  (want "CONTROL the source refers to a base colour texture" (and (gprim-base-tex before) #t) #t)
  (want "CONTROL and to a metallic-roughness texture" (and (gprim-mr-tex before) #t) #t)
  (want "the base colour texture is not carried" (gprim-base-tex after) #f)
  (want "the metallic-roughness texture is not carried" (gprim-mr-tex after) #f))

;; A material that wrote no baseColorFactor.
(let* ((pp (round-trip (list #f (cons 1.0 1.0) (vector 0.0 0.0 0.0) #f #f #f #f #f)))
       (before (car pp)) (after (cadr pp)))
  (want "CONTROL the source has no baseColorFactor" (gprim-base-color-factor before) #f)
  (want "CONTROL and renders as white" (vnear? (gprim-color before) (vector 1.0 1.0 1.0 1.0)) #t)
  (want "an absent factor is written back as an explicit white"
        (vnear? (gprim-base-color-factor after) (vector 1.0 1.0 1.0 1.0)) #t))

(if (null? fails) (display #t) (begin (display (reverse fails)) (newline)))
