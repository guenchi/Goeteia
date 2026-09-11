;; expect: #t
;; REGRESSION GUARD.  Written as a red witness against lib/gfx/glb.ss at
;; 86a2e50 and turned green by the narrowing described at the foot of
;; this comment.  glTF makes a
;; POSITION accessor's min/max mandatory because a viewer culls and
;; frames the scene with them, so a bound that does not contain the
;; data it describes is not a rounding nicety -- geometry disappears
;; at the edge of a frustum test that trusted the file.
;;
;; (gfx glb) computes those bounds twice, and only one of the two
;; spellings is right.  An ordinary POSITION goes through $pos-bounds,
;; which reads %mem-f32-ref -- the values AS STORED.  A morph target's
;; POSITION goes through $src-bounds, which reads the source, and the
;; source is f64 while the accessor it describes is componentType 5126,
;; f32.  Narrowing f64 to f32 moves the value, and it moves in both
;; directions, so the written bound can sit inside the stored data at
;; either end.
;;
;; The two deltas here are chosen for those two directions, and this is
;; the whole of why the defect was invisible: the existing fixture in
;; test/glb-mat.ss uses 0.0 and 1.0, which are exact in f32 and cannot
;; move.  test/glb-mat.ss's morph-bounds-ok asserts min and max EXIST
;; and are near 1.0 -- true, and true of a writer with this defect.
;;   0.1 stored as f32 is 0.10000000149011612, ABOVE the written max
;;   0.7 stored as f32 is 0.699999988079071,   BELOW the written min
;;
;; The assertion is containment with NO tolerance, deliberately: a
;; near? here would hide exactly the discrepancy the cell exists to
;; catch, since the gap IS one f32 ulp.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx gltf) (gfx glb) (web json))
(js-eval "globalThis.__mockcanvas = { width:64, height:64, addEventListener(k,f){}, getContext(kind) { return { createShader(){return {}}, shaderSource(){}, compileShader(){}, getShaderParameter(){return true}, createProgram(){return {}}, attachShader(){}, linkProgram(){}, getProgramParameter(){return true}, bindAttribLocation(){}, getUniformLocation(){return {}}, createBuffer(){return {}}, createVertexArray(){return {}}, createTexture(){return {}}, viewport(){}, enable(){}, clearColor(){}, clear(){} } } }")
(fx-init! (js-get (js-global) "__mockcanvas"))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (rd-u32 at)
  (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))
     (* 65536 (%mem-u8-ref (+ at 2))) (* 16777216 (%mem-u8-ref (+ at 3)))))
(define (glb-json loc)
  (let* ((base (car loc)) (jlen (rd-u32 (+ base 12))) (bv (make-bytevector jlen)))
    (let loop ((i 0))
      (when (< i jlen) (bytevector-u8-set! bv i (%mem-u8-ref (+ base 20 i))) (loop (+ i 1))))
    (string->json (utf8->string bv))))

(define layout '(position normal uv))
(define stride (glb-stride layout))
(define vcount 3)
(define vbase (fx-alloc! (* vcount stride)))
(let v ((i 0))
  (when (< i vcount)
    (let ((a (+ vbase (* i stride))))
      (%mem-f32-set! a (exact->inexact i)) (%mem-f32-set! (+ a 4) 0.0) (%mem-f32-set! (+ a 8) 0.0)
      (%mem-f32-set! (+ a 12) 0.0) (%mem-f32-set! (+ a 16) 1.0) (%mem-f32-set! (+ a 20) 0.0)
      (%mem-f32-set! (+ a 24) 0.5) (%mem-f32-set! (+ a 28) 0.5))
    (v (+ i 1))))
(define ibase (fx-alloc! 8))
(%mem-u8-set! ibase 0) (%mem-u8-set! (+ ibase 1) 0) (%mem-u8-set! (+ ibase 2) 1) (%mem-u8-set! (+ ibase 3) 0)
(%mem-u8-set! (+ ibase 4) 2) (%mem-u8-set! (+ ibase 5) 0)

;; one morph target; every vertex carries the same delta, so each
;; component's min and max are that component's single value
(define dpos (vector 0.1 0.7 1.0  0.1 0.7 1.0  0.1 0.7 1.0))
(define loc (glb-write! (list (list layout vbase vcount ibase 3
                                    'targets (list (list dpos #f #f))
                                    'weights '(1.0)))))
(define g (gltf-parse (car loc) (cdr loc)))
(define p (car (gltf-prims g)))

(define j (glb-json loc))
(define ai (json-ref j "meshes" 0 "primitives" 0 "targets" 0 "POSITION"))
(define a (json-ref j "accessors" ai))
(define mn (json-ref a "min"))
(define mx (json-ref a "max"))
(define (at v i) (exact->inexact (vector-ref v i)))

;; the bound must contain the data it describes, at every vertex and
;; every component, as the value actually came back off the f32 stream
(define target0 (vector-ref (vector-ref (gprim-morph p) 1) 0))
(let vert ((v 0))
  (when (< v vcount)
    (let comp ((c 0))
      (when (< c 3)
        (let ((stored (vector-ref target0 (+ (* v 3) c))))
          (when (fl<? stored (at mn c))
            (want 'stored-below-the-written-min (list 'component c 'stored stored 'min (at mn c)) 'contained))
          (when (fl<? (at mx c) stored)
            (want 'stored-above-the-written-max (list 'component c 'stored stored 'max (at mx c)) 'contained)))
        (comp (+ c 1))))
    (vert (+ v 1))))


;; THE CONTROL, and it is what makes this a discriminator rather than a
;; complaint about floating point.  The SAME two values, written as
;; ordinary POSITION instead of a morph delta, go through $pos-bounds
;; and are contained -- because that spelling reads the stored f32.
;; So the fix is to make the morph path do what the position path
;; already does, not to widen a bound by an ulp: a writer that padded
;; every bound would satisfy the rows above and this one, and would
;; also be wrong, because the bound would no longer be the data's.
;; This half must stay GREEN, before and after.
(define vb2 (fx-alloc! (* vcount stride)))
(let v ((i 0))
  (when (< i vcount)
    (let ((a (+ vb2 (* i stride))))
      (%mem-f32-set! a 0.1) (%mem-f32-set! (+ a 4) 0.7) (%mem-f32-set! (+ a 8) 1.0)
      (%mem-f32-set! (+ a 12) 0.0) (%mem-f32-set! (+ a 16) 1.0) (%mem-f32-set! (+ a 20) 0.0)
      (%mem-f32-set! (+ a 24) 0.5) (%mem-f32-set! (+ a 28) 0.5))
    (v (+ i 1))))
(define loc2 (glb-write! (list (list layout vb2 vcount ibase 3))))
(define j2 (glb-json loc2))
(define a2 (json-ref j2 "accessors"
                     (json-ref j2 "meshes" 0 "primitives" 0 "attributes" "POSITION")))
(define mn2 (json-ref a2 "min"))
(define mx2 (json-ref a2 "max"))
(let vert ((v 0))
  (when (< v vcount)
    (let comp ((c 0))
      (when (< c 3)
        (let ((stored (%mem-f32-ref (+ vb2 (* v stride) (* 4 c)))))
          (when (fl<? stored (at mn2 c))
            (want 'CONTROL-ordinary-position-below-min
                  (list 'component c 'stored stored 'min (at mn2 c)) 'contained))
          (when (fl<? (at mx2 c) stored)
            (want 'CONTROL-ordinary-position-above-max
                  (list 'component c 'stored stored 'max (at mx2 c)) 'contained)))
        (comp (+ c 1))))
    (vert (+ v 1))))


;; THE SAME DEFECT, SECOND SITE.  $times-bounds does it too, and there
;; the reasoning is written down: "The ordering is compared on the f32
;; values because that is what the file will hold; the bounds stay as
;; they were read, since they describe the same numbers the accessor
;; describes."  The last clause is the defect.  They are not the same
;; numbers -- the accessor holds the f32 and the bound holds the f64 --
;; and the line above it already reaches for $as-f32 to compare the
;; ordering, for exactly the reason that also applies to the bounds.
;;
;; A range needs different values than a single component does: the low
;; end has to round DOWN and the high end UP, or the narrowed values
;; land inside the written interval and nothing shows.  Keyframe times
;; must also strictly increase, which 0.7 < 1.1 satisfies.
;;   0.7 stored as f32 is 0.699999988079071, BELOW the written min
;;   1.1 stored as f32 is 1.100000023841858, ABOVE the written max
(define scratch (fx-alloc! 4))
(define (as-f32 v) (%mem-f32-set! scratch v) (%mem-f32-ref scratch))
(define nodes (list (list "root" -1 (vector 0.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))))
(define loc3
  (glb-write! (list (list layout vbase vcount ibase 3))
              'nodes nodes
              'anims (list (list "slide"
                                 (list (list 0 'translation
                                             (vector 0.7 1.1)
                                             (vector (vector 0.0 0.0 0.0) (vector 2.0 0.0 0.0))
                                             2 'linear))))))
(define j3 (glb-json loc3))
(define a3 (json-ref j3 "accessors"
                     (json-ref j3 "animations" 0 "samplers" 0 "input")))
(let ((mn3 (exact->inexact (vector-ref (json-ref a3 "min") 0)))
      (mx3 (exact->inexact (vector-ref (json-ref a3 "max") 0))))
  (when (fl<? (as-f32 0.7) mn3)
    (want 'keyframe-time-below-the-written-min
          (list 'stored (as-f32 0.7) 'min mn3) 'contained))
  (when (fl<? mx3 (as-f32 1.1))
    (want 'keyframe-time-above-the-written-max
          (list 'stored (as-f32 1.1) 'max mx3) 'contained)))

;; HOW IT WAS FIXED, recorded here because the tool and the argument
;; were both already in the file: $as-f32 (glb.ss:913) now wraps the
;; READ in both $src-bounds and $times-bounds, so a bound is computed
;; over the value as stored.  The ordering guard lost its own pair of
;; $as-f32 calls in the same change, the values reaching it having
;; already been narrowed.
(display (if (null? fails) #t fails))
