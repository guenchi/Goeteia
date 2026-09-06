;; expect: #t
;; CPU skinning of NORMALS under joints that scale unevenly or mirror.
;; A normal is a covector: it must move by the cofactor matrix of the
;; blended joint matrix (the inverse transpose up to a positive
;; factor), with the sign of the determinant folded in when a joint
;; mirrors -- not by the joint matrix itself, which is right only for
;; rotations and uniform scales (test/gltf-skin-cpu.ss covers those,
;; and stays green under this rule).  The expected values were
;; computed by hand (a 3x3 cofactor in plain Python, see the design
;; note archive/goeteia-p1-design.md, section D) and are written
;; here as numbers, not derived from the code under test.
;;
;; One joint, one triangle fully weighted to it, no inverse bind
;; matrix (identity), so the palette IS the joint's TRS.
(import (rnrs) (gfx fx) (gfx gltf))

(define base (fx-alloc! 8192))
(define at 0)
(define (b! v) (%mem-u8-set! (+ base at) v) (set! at (+ at 1)))
(define (u16! v) (b! (remainder v 256)) (b! (quotient v 256)))
(define (u32! v) (u16! (remainder v 65536)) (u16! (quotient v 65536)))
(define (f32! v) (%mem-f32-set! (+ base at) v) (set! at (+ at 4)))
(define (v3! x y z) (f32! x) (f32! y) (f32! z))
(define (str! s) (string-for-each (lambda (c) (b! (char->integer c))) s))

;; BIN: 0 pos 36 | 36 nrm 36 | 72 joints(u8) 12 | 84 weights 48 | 132 idx 6+2
(define binlen 140)
(define json
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,\"scenes\":[{\"nodes\":[0,1]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},{\"name\":\"j\"}],"
   "\"skins\":[{\"joints\":[1]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,"
   "\"JOINTS_0\":2,\"WEIGHTS_0\":3},\"indices\":4}]}],"
   "\"buffers\":[{\"byteLength\":140}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":84,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":132,\"byteLength\":6}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":4,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}"))
(define jlen (string-length json))
(define jpad (remainder (- 4 (remainder jlen 4)) 4))
(define total (+ 12 8 jlen jpad 8 binlen))
(u32! #x46546C67) (u32! 2) (u32! total) (u32! (+ jlen jpad)) (u32! #x4E4F534A)
(str! json)
(let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
(u32! binlen) (u32! #x004E4942)
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)          ; positions
(define r2 0.70710678)
(v3! r2 r2 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 r2 r2)               ; normals v0 v1 v2
(let j ((i 0)) (when (< i 12) (b! 0) (j (+ i 1))))              ; joints: all 0
(let w ((i 0)) (when (< i 3) (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 0.0) (w (+ i 1))))
(u16! 0) (u16! 1) (u16! 2) (u16! 0)

(define g (gltf-parse base total))
(define p (car (gltf-prims g)))
(define dst (fx-alloc! (* 12 3)))
(define (out v k) (%mem-f32-ref (+ dst (* 12 v) (* 4 k))))
(define (near? a b) (< (abs (- a b)) 1e-5))
(define (posed! sx sy sz)
  (gltf-node-scale-set! g 1 sx sy sz)
  (gltf-skin-normals! g p dst))

;; (a) uneven scale (2,1,1): (1,1,0)/sqrt2 -> (1,2,0)/sqrt5.
;;     The joint matrix itself would give (2,1,0)/sqrt5.
(posed! 2.0 1.0 1.0)
(define uneven-ok
  (and (near? (out 0 0) 0.4472136) (near? (out 0 1) 0.8944272) (near? (out 0 2) 0.0)))

;; (c) mirrored AND uneven (-1,1,2): (0,1,1)/sqrt2 -> (0,2,1)/sqrt5,
;;     the determinant's sign folded in.  The joint matrix would give
;;     (0,1,2)/sqrt5; the cofactor without the sign, (0,-2,-1)/sqrt5.
(posed! -1.0 1.0 2.0)
(define mirrored-ok
  (and (near? (out 2 0) 0.0) (near? (out 2 1) 0.8944272) (near? (out 2 2) 0.4472136)))

;; a pure reflection (-1,1,1) is its own inverse transpose: (1,0,0)
;; goes to (-1,0,0) under either rule -- the control that this file
;; is about the uneven cases, not reflections as such
(posed! -1.0 1.0 1.0)
(define reflection-ok
  (and (near? (out 1 0) -1.0) (near? (out 1 1) 0.0) (near? (out 1 2) 0.0)))

;; (b) a collapsed joint (1,1,0): the cofactor sends (1,0,0) to the
;;     zero vector, and a zero-length result goes out as the zero
;;     vector -- the existing "no direction to report" branch, pinned.
;;     The joint matrix would leave (1,0,0) untouched.
(posed! 1.0 1.0 0.0)
(define collapsed-ok
  (and (= (out 1 0) 0.0) (= (out 1 1) 0.0) (= (out 1 2) 0.0)))

;; (b') the same collapsed joint (1,1,0) sends (0,0,1) to ITSELF: the
;;     cofactor is diag(0,0,1), the determinant is 0 and the sign must
;;     read +1 there.  A sign() built-in (or det/|det|) gives 0 at a
;;     zero determinant and would erase this normal -- the half-fix the
;;     zero-vector case above cannot tell apart.
(define collapsed-kept-ok                  ; v2's normal (0 r2 r2) -> (0 0 r2) -> (0 0 1)
  (and (near? (out 2 0) 0.0) (near? (out 2 1) 0.0) (near? (out 2 2) 1.0)))

;; uniform scale and identity: unchanged by the rule (compatibility)
(posed! 3.0 3.0 3.0)
(define uniform-ok
  (and (near? (out 0 0) r2) (near? (out 0 1) r2) (near? (out 0 2) 0.0)))

(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)
(let ((all (list (report "uneven" uneven-ok) (report "mirrored" mirrored-ok)
                 (report "reflection" reflection-ok) (report "collapsed" collapsed-ok)
                 (report "collapsed-kept" collapsed-kept-ok)
                 (report "uniform" uniform-ok))))
  (let loop ((l all)) (or (null? l) (and (car l) (loop (cdr l))))))
