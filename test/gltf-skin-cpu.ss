;; expect: #t
;; (gfx gltf) CPU skinning: gltf-skin-positions! / gltf-skin-normals!
;; pose a skinned primitive into staging as tightly packed vec3 f32 --
;; what (gfx raster)'s rattr-f32 reads -- using the palette of the
;; CURRENT animation state.
;;
;; The blend under test is the vertex shader's, spelled out:
;;   S = w.x*P[j.x] + w.y*P[j.y] + w.z*P[j.z] + w.w*P[j.w]
;;   position = S * (pos, 1)     normal = normalize(S * (nrm, 0))
;; so the oracles here are closed forms, not screenshots.
;;
;; Three fixtures, each aimed at a different way to get it wrong:
;;   chain  40 joints, each one unit further along +x, weights
;;          (1,0,0,0).  The CPU pose is compared FLOAT FOR FLOAT
;;          against a hand blend that reads the same palette out of
;;          staging -- a second, independent computation of the same
;;          thing (a joint index read one column off, or a weight
;;          read from the joint slot, moves one and not the other).
;;   bind   one joint translated (2,3,4) with the matching inverse
;;          bind matrix, so the palette is the identity: the posed
;;          vertices must come back BIT for bit as they went in.
;;          A palette that skipped the inverse bind shifts them.
;;   rig    two joints -- one animated pure translation, one with a
;;          90-degree z rotation, a scale of 2 and a translation --
;;          and four vertices: fully weighted to each, an even
;;          blend, and a weight that does not sum to one.
;;
;; Weights ride through as the stream carries them: glTF requires
;; them to sum to one and gltf-skin-vs does not renormalize, so
;; renormalizing on this side would put the two paths on different
;; geometry.  Vertex v3 of `rig` pins that choice in both places.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx gltf))

;; ---- one staging arena, every GLB written into it by hand ----
(define base (fx-alloc! 262144))
(define at 0)
(define (b! v) (%mem-u8-set! (+ base at) v) (set! at (+ at 1)))
(define (u16! v) (b! (remainder v 256)) (b! (quotient v 256)))
(define (u32! v)
  (b! (remainder v 256))
  (b! (remainder (quotient v 256) 256))
  (b! (remainder (quotient v 65536) 256))
  (b! (quotient v 16777216)))
(define (f32! v) (%mem-f32-set! (+ base at) v) (set! at (+ at 4)))
(define (v3! x y z) (f32! x) (f32! y) (f32! z))
(define (v4! x y z w) (f32! x) (f32! y) (f32! z) (f32! w))
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

(define (glb! json binlen fill!)
  (let* ((jlen (string-length json))
         (jpad (remainder (- 4 (remainder jlen 4)) 4))
         (total (+ 12 8 jlen jpad 8 binlen))
         (start at))
    (u32! #x46546C67)
    (u32! 2)
    (u32! total)
    (u32! (+ jlen jpad))
    (u32! #x4E4F534A)
    (str! json)
    (let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
    (u32! binlen)
    (u32! #x004E4942)
    (fill!)
    (cons (+ base start) total)))

(define (near? a b)
  (and (fl<? (fl- a b) 0.0001) (fl<? (fl- b a) 0.0001)))

;; ---- fixture "chain": nj joints, each one unit further along +x --
;; node 0 carries the mesh and the skin; nodes 1..nj are the chain,
;; every one translated (1,0,0) from its parent.  No
;; inverseBindMatrices, so palette[k] is a translation by (k+1,0,0).
(define (chain-json nj)
  (let node ((k 1) (acc ""))
    (if (> k nj)
        (string-append
         "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
         "\"scenes\":[{\"nodes\":[0,1]}],"
         "\"nodes\":[{\"mesh\":0,\"skin\":0}" acc "],"
         "\"skins\":[{\"joints\":["
         (let j ((k 1) (s ""))
           (if (> k nj)
               s
               (j (+ k 1)
                  (string-append s (if (= k 1) "" ",")
                                 (number->string k)))))
         "]}],"
         "\"meshes\":[{\"primitives\":[{\"attributes\":"
         "{\"POSITION\":0,\"JOINTS_0\":1,\"WEIGHTS_0\":2},"
         "\"indices\":3}]}],"
         "\"buffers\":[{\"byteLength\":104}],"
         "\"bufferViews\":["
         "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
         "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
         "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":48},"
         "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6}],"
         "\"accessors\":["
         "{\"bufferView\":0,\"componentType\":5126,\"count\":3,"
         "\"type\":\"VEC3\"},"
         "{\"bufferView\":1,\"componentType\":5121,\"count\":3,"
         "\"type\":\"VEC4\"},"
         "{\"bufferView\":2,\"componentType\":5126,\"count\":3,"
         "\"type\":\"VEC4\"},"
         "{\"bufferView\":3,\"componentType\":5123,\"count\":3,"
         "\"type\":\"SCALAR\"}]}")
        (node (+ k 1)
              (string-append
               acc
               (if (= k nj)
                   ",{\"translation\":[1,0,0]}"
                   (string-append ",{\"translation\":[1,0,0],"
                                  "\"children\":["
                                  (number->string (+ k 1)) "]}")))))))

;; the vertices reference three DIFFERENT joints high up the chain,
;; so a single wrong index shows up as one wrong vertex
(define (chain-glb! nj)
  (let ((hi (lambda (d) (let ((v (- nj d))) (if (> v 255) 255 v)))))
    (glb! (chain-json nj) 104
          (lambda ()
            (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
            (b! (hi 1)) (b! 0) (b! 0) (b! 0)
            (b! (hi 3)) (b! 0) (b! 0) (b! 0)
            (b! (hi 5)) (b! 0) (b! 0) (b! 0)
            (let w ((i 0))
              (when (< i 3)
                (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 0.0)
                (w (+ i 1))))
            (u16! 0) (u16! 1) (u16! 2) (u16! 0)))))

;; ---- fixture "bind": palette == identity by construction ----
;; joint node at (2,3,4), inverse bind matrix the translation back.
;; jidx is the joint index written into JOINTS_0 -- 0 is the only
;; legal one, and the out-of-range build below is the refusal case.
(define (bind-json)
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},{\"translation\":[2,3,4]}],"
   "\"skins\":[{\"joints\":[1],\"inverseBindMatrices\":5}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1,\"JOINTS_0\":2,\"WEIGHTS_0\":3},"
   "\"indices\":4}]}],"
   "\"buffers\":[{\"byteLength\":204}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":84,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":132,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":140,\"byteLength\":64}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":4,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":1,\"type\":\"MAT4\"}]}"))

(define (bind-glb! jidx)
  (glb! (bind-json) 204
        (lambda ()
          (v3! 1.0 2.0 3.0) (v3! -1.0 0.5 2.0) (v3! 0.0 0.0 0.0)
          (v3! 0.0 0.0 1.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
          (let j ((i 0))
            (when (< i 3)
              (b! jidx) (b! 0) (b! 0) (b! 0)
              (j (+ i 1))))
          (let w ((i 0))
            (when (< i 3)
              (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 0.0)
              (w (+ i 1))))
          (u16! 0) (u16! 1) (u16! 2) (u16! 0)
          (v4! 1.0 0.0 0.0 0.0) (v4! 0.0 1.0 0.0 0.0)
          (v4! 0.0 0.0 1.0 0.0) (v4! -2.0 -3.0 -4.0 1.0))))

;; ---- fixture "rig": one animated joint, one rotated+scaled one --
;; node 1 (joint A) is a pure translation driven by the clip "mov";
;; node 2 (joint B) sits at (5,6,7), turned 90 degrees about +z and
;; scaled by 2.  Inverse binds default to the identity, so the
;; palette is exactly the joint's global matrix.
(define (rig-json)
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1,2]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},"
   "{\"translation\":[0,0,0]},"
   "{\"translation\":[5,6,7],"
   "\"rotation\":[0,0,0.70710678,0.70710678],\"scale\":[2,2,2]}],"
   "\"skins\":[{\"joints\":[1,2]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1,\"JOINTS_0\":2,\"WEIGHTS_0\":3},"
   "\"indices\":4}]}],"
   "\"animations\":[{\"name\":\"mov\","
   "\"samplers\":[{\"input\":5,\"output\":6,"
   "\"interpolation\":\"LINEAR\"}],"
   "\"channels\":[{\"sampler\":0,\"target\":"
   "{\"node\":1,\"path\":\"translation\"}}]}],"
   "\"buffers\":[{\"byteLength\":232}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":16},"
   "{\"buffer\":0,\"byteOffset\":112,\"byteLength\":64},"
   "{\"buffer\":0,\"byteOffset\":176,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":184,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":196,\"byteLength\":36}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"count\":4,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5126,\"count\":4,\"type\":\"VEC4\"},"
   "{\"bufferView\":4,\"componentType\":5123,\"count\":4,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]}"))

(define (rig-glb!)
  (glb! (rig-json) 232
        (lambda ()
          ;; positions
          (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
          (v3! 0.0 0.0 0.0) (v3! 0.0 0.0 0.0)
          ;; normals
          (v3! 0.0 0.0 1.0) (v3! 1.0 0.0 0.0)
          (v3! 0.0 1.0 0.0) (v3! 0.0 0.0 1.0)
          ;; joints
          (b! 0) (b! 0) (b! 0) (b! 0)
          (b! 1) (b! 0) (b! 0) (b! 0)
          (b! 0) (b! 1) (b! 0) (b! 0)
          (b! 0) (b! 0) (b! 0) (b! 0)
          ;; weights: full A, full B, an even blend, and a sum of .5
          (v4! 1.0 0.0 0.0 0.0)
          (v4! 1.0 0.0 0.0 0.0)
          (v4! 0.5 0.5 0.0 0.0)
          (v4! 0.5 0.0 0.0 0.0)
          (u16! 0) (u16! 1) (u16! 2) (u16! 3)
          (f32! 0.0) (f32! 1.0) (f32! 2.0)
          (v3! 0.0 0.0 0.0) (v3! 4.0 0.0 0.0) (v3! 8.0 0.0 0.0))))

;; ---- fixture "plain": no JOINTS_0 at all ----
(define (plain-json)
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0]}],"
   "\"nodes\":[{\"mesh\":0}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1},\"indices\":2}]}],"
   "\"buffers\":[{\"byteLength\":80}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":6}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}"))

(define (plain-glb!)
  (glb! (plain-json) 80
        (lambda ()
          (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
          (v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0)
          (u16! 0) (u16! 1) (u16! 2) (u16! 0))))

;; every GLB is written before anything parses: gltf-parse allocates
;; out of the same bump heap, above this arena
(define loc-chain (chain-glb! 40))
(define loc-bind (bind-glb! 0))
(define loc-bad (bind-glb! 3))
(define loc-rig (rig-glb!))
(define loc-plain (plain-glb!))

(define g-chain (gltf-parse (car loc-chain) (cdr loc-chain)))
(define g-bind (gltf-parse (car loc-bind) (cdr loc-bind)))
(define g-bad (gltf-parse (car loc-bad) (cdr loc-bad)))
(define g-rig (gltf-parse (car loc-rig) (cdr loc-rig)))
(define g-plain (gltf-parse (car loc-plain) (cdr loc-plain)))

(define p-chain (car (gltf-prims g-chain)))
(define p-bind (car (gltf-prims g-bind)))
(define p-bad (car (gltf-prims g-bad)))
(define p-rig (car (gltf-prims g-rig)))
(define p-plain (car (gltf-prims g-plain)))

(define (errors? th) (guard (e (#t #t)) (th) #f))

;; ---- the vertex count is part of the API: callers size with it --
(define vcount-ok
  (and (= (gprim-vcount p-chain) 3)
       (= (gprim-vcount p-rig) 4)
       (= (gprim-vcount p-plain) 3)
       ;; and it agrees with the two numbers it is derived from
       (= (* (gprim-vcount p-rig) (gprim-stride p-rig))
          (gprim-vbytes p-rig))))

;; ---- destinations, tightly packed vec3 f32 ----
(define dst-chain (fx-alloc! (* 12 (gprim-vcount p-chain))))
(define dst-bind (fx-alloc! (* 12 (gprim-vcount p-bind))))
(define dst-bindn (fx-alloc! (* 12 (gprim-vcount p-bind))))
(define dst-rig (fx-alloc! (* 12 (gprim-vcount p-rig))))
(define dst-rign (fx-alloc! (* 12 (gprim-vcount p-rig))))

(define (out at v k) (%mem-f32-ref (+ at (* 12 v) (* 4 k))))

;; ---- reading the interleave back, by layout ----
;; the canonical order is position normal uv joints weights, so a
;; skinned primitive with no TEXCOORD_0/TANGENT/COLOR_0 strides 64
(define (attr-off p a)
  (let scan ((l (gprim-layout p)) (off 0))
    (cond ((null? l) -1)
          ((eq? (car l) a) off)
          (else (scan (cdr l)
                      (+ off (case (car l)
                               ((position normal) 12)
                               ((uv) 8)
                               (else 16))))))))
(define (vattr p a v k)
  (%mem-f32-ref (+ (gprim-vbase p) (* v (gprim-stride p))
                   (attr-off p a) (* 4 k))))
(define layout-ok
  (and (equal? (gprim-layout p-rig)
               '(position normal uv joints weights))
       (= (gprim-stride p-rig) 64)
       (= (attr-off p-rig 'joints) 32)
       (= (attr-off p-rig 'weights) 48)))

;; ---- the hand blend: a second, independent path to the same pose --
;; element i of S, straight out of the palette in staging
(define (hand-elem pal p v i)
  (let loop ((c 0) (s 0.0))
    (if (= c 4)
        s
        (loop (+ c 1)
              (fl+ s (fl* (vattr p 'weights v c)
                          (%mem-f32-ref
                           (+ pal
                              (* 64 (%fl->fx (vattr p 'joints v c)))
                              (* 4 i)))))))))
(define (hand-pos pal p v k)
  (fl+ (fl+ (fl* (hand-elem pal p v k) (vattr p 'position v 0))
            (fl* (hand-elem pal p v (+ k 4)) (vattr p 'position v 1)))
       (fl+ (fl* (hand-elem pal p v (+ k 8)) (vattr p 'position v 2))
            (hand-elem pal p v (+ k 12)))))

;; ---- chain: float for float against the hand blend ----
(define chain-n (gltf-skin-positions! g-chain p-chain dst-chain))
(define pal-chain (gltf-joint-palette! g-chain 0))
(define chain-ok
  (and (= chain-n 3)
       (let v ((i 0))
         (or (= i 3)
             (and (let k ((j 0))
                    (or (= j 3)
                        (and (= (out dst-chain i j)
                                (hand-pos pal-chain p-chain i j))
                             (k (+ j 1)))))
                  (v (+ i 1)))))))
;; and against the closed form the fixture was built for: vertex i
;; rides joint (40-1-2i), a translation by (40-2i, 0, 0)
(define chain-closed-ok
  (let v ((i 0))
    (or (= i 3)
        (and (= (out dst-chain i 0)
                (fl+ (vattr p-chain 'position i 0)
                     (fixnum->flonum (- 40 (* 2 i)))))
             (= (out dst-chain i 1) (vattr p-chain 'position i 1))
             (= (out dst-chain i 2) (vattr p-chain 'position i 2))
             (v (+ i 1))))))

;; ---- bind: the identity palette moves nothing, bit for bit ----
(define bind-n (gltf-skin-positions! g-bind p-bind dst-bind))
(define bind-nn (gltf-skin-normals! g-bind p-bind dst-bindn))
(define bind-ok
  (and (= bind-n 3) (= bind-nn 3)
       ;; the palette really is the identity -- the inverse bind
       ;; cancels the joint's (2,3,4), and dropping either factor
       ;; would leave a translation in the fourth column
       (let ((pal (gltf-joint-palette! g-bind 0)))
         (and (= (%mem-f32-ref (+ pal 48)) 0.0)
              (= (%mem-f32-ref (+ pal 52)) 0.0)
              (= (%mem-f32-ref (+ pal 56)) 0.0)
              (= (%mem-f32-ref pal) 1.0)
              (= (%mem-f32-ref (+ pal 20)) 1.0)
              (= (%mem-f32-ref (+ pal 40)) 1.0)))
       (let v ((i 0))
         (or (= i 3)
             (and (let k ((j 0))
                    (or (= j 3)
                        (and (= (out dst-bind i j)
                                (vattr p-bind 'position i j))
                             (= (out dst-bindn i j)
                                (vattr p-bind 'normal i j))
                             (k (+ j 1)))))
                  (v (+ i 1)))))))

;; ---- rig, before any clip runs: joint A is at the origin ----
(define rig-bind-ok
  (let ((n (gltf-skin-positions! g-rig p-rig dst-rig)))
    (and (= n 4)
         (= (out dst-rig 0 0) 1.0)
         (= (out dst-rig 0 1) 0.0)
         (= (out dst-rig 0 2) 0.0))))

;; ---- rig, animated: t = 0.5 puts joint A at (2,0,0) ----
(gltf-animate! g-rig 0 0.5)
(define rig-n (gltf-skin-positions! g-rig p-rig dst-rig))
(define rig-nn (gltf-skin-normals! g-rig p-rig dst-rign))
(define pal-rig (gltf-joint-palette! g-rig 0))

;; the clip lands where the closed form says
(define anim-palette-ok
  (and (= (%mem-f32-ref (+ pal-rig 48)) 2.0)
       (= (%mem-f32-ref (+ pal-rig 52)) 0.0)
       (= (%mem-f32-ref (+ pal-rig 56)) 0.0)
       ;; joint B is untouched by the clip: still (5,6,7), turned
       ;; 90 degrees about z and scaled by 2
       (near? (%mem-f32-ref (+ pal-rig 64 48)) 5.0)
       (near? (%mem-f32-ref (+ pal-rig 64 52)) 6.0)
       (near? (%mem-f32-ref (+ pal-rig 64 56)) 7.0)
       (near? (%mem-f32-ref (+ pal-rig 64 0)) 0.0)
       (near? (%mem-f32-ref (+ pal-rig 64 4)) 2.0)
       (near? (%mem-f32-ref (+ pal-rig 64 16)) -2.0)
       (near? (%mem-f32-ref (+ pal-rig 64 20)) 0.0)))

;; v0 rides joint A alone: it moves by exactly the palette's
;; translation, nothing else
(define full-weight-ok
  (and (= rig-n 4)
       (= (out dst-rig 0 0)
          (fl+ (vattr p-rig 'position 0 0) (%mem-f32-ref (+ pal-rig 48))))
       (= (out dst-rig 0 1) (vattr p-rig 'position 0 1))
       (= (out dst-rig 0 2) (vattr p-rig 'position 0 2))))

;; v1 rides joint B alone: (0,1,0) turns to -x, doubles, translates
(define rotated-weight-ok
  (and (near? (out dst-rig 1 0) 3.0)
       (near? (out dst-rig 1 1) 6.0)
       (near? (out dst-rig 1 2) 7.0)))

;; v2 is an even blend of the two.  It sits at the origin, so the
;; answer is the average of the two fourth columns -- and both are
;; exact, so this is an equality, not a neighbourhood
(define blend-weight-ok
  (and (= (out dst-rig 2 0) 3.5)
       (= (out dst-rig 2 1) 3.0)
       (= (out dst-rig 2 2) 3.5)))

;; v3's weights sum to 0.5 and are used as they are: the origin maps
;; to half of joint A's translation.  Renormalizing would give
;; (2,0,0) -- the same answer a correct implementation gives for a
;; weight of one, which is why this vertex exists.
(define unnormalized-weight-ok
  (and (= (out dst-rig 3 0) 1.0)
       (= (out dst-rig 3 1) 0.0)
       (= (out dst-rig 3 2) 0.0)))

;; the hand blend agrees on every rig vertex too
(define rig-hand-ok
  (let v ((i 0))
    (or (= i 4)
        (and (let k ((j 0))
               (or (= j 3)
                   (and (near? (out dst-rig i j)
                               (hand-pos pal-rig p-rig i j))
                        (k (+ j 1)))))
             (v (+ i 1))))))

;; ---- normals ----
;; v0: joint A is a pure translation, so its normal does not move at
;; all.  Reading the fourth column into a direction would put it at
;; normalize((2,0,1)).
(define normal-translation-ok
  (and (= rig-nn 4)
       (= (out dst-rign 0 0) 0.0)
       (= (out dst-rign 0 1) 0.0)
       (= (out dst-rign 0 2) 1.0)))

;; v1: +x turned 90 degrees about +z is +y, and the joint's scale of
;; 2 is divided back out
(define normal-rotation-ok
  (and (near? (out dst-rign 1 0) 0.0)
       (near? (out dst-rign 1 1) 1.0)
       (near? (out dst-rign 1 2) 0.0)))

;; v2: the blended basis sends +y to (-1, 0.5, 0); normalized that
;; is (-2,1,0)/sqrt(5)
(define normal-blend-ok
  (and (near? (out dst-rign 2 0) -0.8944272)
       (near? (out dst-rign 2 1) 0.4472136)
       (near? (out dst-rign 2 2) 0.0)))

;; v3: a half weight halves the direction, and the renormalization
;; puts it back on the unit sphere.  Without it this reads (0,0,0.5).
(define normal-unit-ok
  (and (= (out dst-rign 3 0) 0.0)
       (= (out dst-rign 3 1) 0.0)
       (= (out dst-rign 3 2) 1.0)))

;; and every posed normal really is unit length
(define normal-length-ok
  (let v ((i 0))
    (or (= i 4)
        (and (near? (fl+ (fl+ (fl* (out dst-rign i 0) (out dst-rign i 0))
                              (fl* (out dst-rign i 1) (out dst-rign i 1)))
                         (fl* (out dst-rign i 2) (out dst-rign i 2)))
                    1.0)
             (v (+ i 1))))))

;; ---- refusals ----
(define plain-dst (fx-alloc! 36))
(define refuse-ok
  (and (errors? (lambda () (gltf-skin-positions! g-plain p-plain plain-dst)))
       (errors? (lambda () (gltf-skin-normals! g-plain p-plain plain-dst)))
       ;; a joint index outside the skin is a broken asset, not a
       ;; licence to blend whatever staging holds at that address
       (errors? (lambda ()
                  (gltf-skin-positions! g-bad p-bad dst-bind)))))

;; the writes stay inside the destination: the byte after the last
;; vertex is untouched
(define bounds-dst (fx-alloc! 52))
(%mem-f32-set! (+ bounds-dst 36) 12345.0)
(define bounds-ok
  (and (= (gltf-skin-positions! g-bind p-bind bounds-dst) 3)
       (= (%mem-f32-ref (+ bounds-dst 36)) 12345.0)))

(display (and vcount-ok layout-ok
              chain-ok chain-closed-ok
              bind-ok rig-bind-ok anim-palette-ok
              full-weight-ok rotated-weight-ok blend-weight-ok
              unnormalized-weight-ok rig-hand-ok
              normal-translation-ok normal-rotation-ok
              normal-blend-ok normal-unit-ok normal-length-ok
              refuse-ok bounds-ok))
