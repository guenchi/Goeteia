;; expect: #t
;; (gfx glb) v2: skins, node hierarchies and animations written out,
;; read back by the parser that reads real files.  The round trip is
;; the oracle again, but the questions are different from the static
;; writer's: a skeleton is only right if the PARENT LINKS are right,
;; and an animation is only right if the sampler layout is.
;;
;; The fixture is built so both have closed forms.
;;
;;   node 0  the mesh, a root
;;   node 1  j0  root,     translation (1,0,0)
;;   node 2  j1  child(1),             (2,0,0)
;;   node 3  j2  child(2),             (4,0,0)
;;   node 4  j3  child(3),             (8,0,0)
;;
;; The chain is deliberately NOT uniform: bind globals sit at x =
;; 1, 3, 7, 15, so a parent index off by one moves them.  The
;; inverse binds are the true inverses, T(-1) T(-3) T(-7) T(-15),
;; which makes "the bind palette is four identity matrices" a single
;; assertion over the joint order, the parent links and the inverse
;; binds at once -- each of the three wrong on its own breaks it.
;;
;; Clip "mix" drives four channels through three interpolations:
;;   j0  translation CUBICSPLINE  keys at t = 0,2,3, key0's
;;         out-tangent (6,6,6) and every other tangent zero -- the
;;         same discriminator test/gltf-anim.ss uses, so a value
;;         read one element off the in/value/out triple shows as a
;;         different POSITION rather than as a rounding difference
;;   j1  scale       STEP         (1,1,1) (2,2,2) (3,3,3) at 0,1,2
;;   j2  rotation    LINEAR       identity -> 90 degrees about z
;;   j3  translation LINEAR       (8,0,0) -> (8,0,4)
;; "wag" is a second clip so names and durations have to be told
;; apart, and "morph" is a weights channel -- the one output glTF
;; stores as loose scalars instead of as vectors.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf) (gfx glb) (web json))

;; ---- the recording mock GL (as in test/glb.ss) -------------------
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', UNSIGNED_INT:'UI', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){}, generateMipmap(t){}, texImage2D(...a){}, activeTexture(u){}, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform2f(loc,x,y){}, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){}, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){}, uniform3f(loc,x,y,z){}, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){} } } }")

;; fx-init! rewinds the staging bump allocator, so it runs BEFORE
;; any fx-alloc! here
(fx-init! (js-get (js-global) "__mockcanvas"))

(define (near? a b)
  (and (fl<? (fl- a b) 0.0001) (fl<? (fl- b a) 0.0001)))

(define (bytes=? a b n)
  (let loop ((i 0))
    (cond ((= i n) #t)
          ((= (%mem-u8-ref (+ a i)) (%mem-u8-ref (+ b i))) (loop (+ i 1)))
          (else #f))))

(define (rd-u16 at) (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))))

;; ---- the skinned vertex block -----------------------------------
(define skin-layout '(position normal uv joints weights))
(define vstride (glb-stride skin-layout))          ; 64
(define vcount 3)
(define vbase (fx-alloc! (* vcount vstride)))

(define (vert! v px py pz js ws)
  (let ((d (+ vbase (* v vstride))))
    (%mem-f32-set! d px)
    (%mem-f32-set! (+ d 4) py)
    (%mem-f32-set! (+ d 8) pz)
    (%mem-f32-set! (+ d 12) 0.0)                    ; normal +y
    (%mem-f32-set! (+ d 16) 1.0)
    (%mem-f32-set! (+ d 20) 0.0)
    (%mem-f32-set! (+ d 24) (fl* 0.5 (fixnum->flonum v)))
    (%mem-f32-set! (+ d 28) (fl* 0.25 (fixnum->flonum v)))
    (let j ((l js) (i 0))
      (unless (null? l)
        (%mem-f32-set! (+ d 32 (* 4 i)) (car l))
        (j (cdr l) (+ i 1))))
    (let w ((l ws) (i 0))
      (unless (null? l)
        (%mem-f32-set! (+ d 48 (* 4 i)) (car l))
        (w (cdr l) (+ i 1))))))

(vert! 0 0.0 0.0 0.0 '(0.0 1.0 0.0 0.0) '(0.5 0.5 0.0 0.0))
(vert! 1 1.0 0.0 0.0 '(2.0 3.0 0.0 0.0) '(0.25 0.75 0.0 0.0))
(vert! 2 0.0 1.0 0.0 '(3.0 0.0 0.0 0.0) '(1.0 0.0 0.0 0.0))

(define ibase (fx-alloc! 8))
(%mem-u8-set! ibase 0) (%mem-u8-set! (+ ibase 1) 0)
(%mem-u8-set! (+ ibase 2) 1) (%mem-u8-set! (+ ibase 3) 0)
(%mem-u8-set! (+ ibase 4) 2) (%mem-u8-set! (+ ibase 5) 0)

;; ---- the inverse bind matrices, tight mat4s in staging ----------
(define ibm-base (fx-alloc! 256))
(define (ibm! k x)
  (let ((d (+ ibm-base (* k 64))))
    (let z ((i 0))
      (when (< i 16) (%mem-f32-set! (+ d (* 4 i)) 0.0) (z (+ i 1))))
    (%mem-f32-set! d 1.0)
    (%mem-f32-set! (+ d 20) 1.0)
    (%mem-f32-set! (+ d 40) 1.0)
    (%mem-f32-set! (+ d 60) 1.0)
    (%mem-f32-set! (+ d 48) x)))
(ibm! 0 -1.0) (ibm! 1 -3.0) (ibm! 2 -7.0) (ibm! 3 -15.0)

;; ---- keyframe data, bump-allocated ------------------------------
(define anim-base (fx-alloc! 4096))
(define anim-at 0)
(define (fput! vs)
  (let ((start (+ anim-base anim-at)))
    (let loop ((l vs))
      (unless (null? l)
        (%mem-f32-set! (+ anim-base anim-at) (car l))
        (set! anim-at (+ anim-at 4))
        (loop (cdr l))))
    start))

(define s45 0.70710678)

(define cub-t (fput! '(0.0 2.0 3.0)))
;; in-tangent / value / out-tangent per key
(define cub-v (fput! '(0.0 0.0 0.0   1.0  2.0  3.0   6.0 6.0 6.0
                       0.0 0.0 0.0   7.0  8.0  9.0   0.0 0.0 0.0
                       0.0 0.0 0.0  13.0 14.0 15.0   0.0 0.0 0.0)))
(define step-t (fput! '(0.0 1.0 2.0)))
(define step-v (fput! '(1.0 1.0 1.0  2.0 2.0 2.0  3.0 3.0 3.0)))
(define lin-t (fput! '(0.0 2.0)))
(define rot-v (fput! (list 0.0 0.0 0.0 1.0  0.0 0.0 s45 s45)))
(define t3-v (fput! '(8.0 0.0 0.0  8.0 0.0 4.0)))
(define wag-t (fput! '(0.0 1.0)))
(define wag-v (fput! (list 0.0 0.0 0.0 1.0  0.0 s45 0.0 s45)))
(define mor-t (fput! '(0.0 2.0)))
(define mor-v (fput! '(0.0 1.0  0.25 0.75)))

;; ---- the file ---------------------------------------------------
;; node 2 gives its transform as a key/value tail, the rest
;; positionally: both spellings have to reach the same place
(define nodes
  (list (list "mesh" -1)
        (list "j0" -1 (vector 1.0 0.0 0.0))
        (list "j1" 1 'translation (list 2.0 0.0 0.0))
        (list "j2" 2 (vector 4.0 0.0 0.0))
        (list "j3" 3 (vector 8.0 0.0 0.0))))

(define skin (list (list 1 2 3 4) ibm-base))

(define anims
  (list
   (list "mix"
         (list (list 1 'translation cub-t cub-v 3 'cubic)
               (list 2 'scale step-t step-v 3 'step)
               (list 3 'rotation lin-t rot-v 2 'linear)
               (list 4 'translation lin-t t3-v 2)))   ; default: linear
   (list "wag" (list (list 2 'rotation wag-t wag-v 2 'linear)))
   (list "morph"
         (list (list 0 'weights mor-t mor-v 2 'linear 'components 2)))))

(define prim
  (list skin-layout vbase vcount ibase 3
        'color (vector 0.2 0.4 0.6 1.0)))

(define loc (glb-write! (list prim)
                        'nodes nodes 'mesh-node 0
                        'skin skin 'anims anims))
(define g (gltf-parse (car loc) (cdr loc)))

(define (glb-jchunk l)
  (+ (%mem-u8-ref (+ (car l) 12))
     (* 256 (%mem-u8-ref (+ (car l) 13)))
     (* 65536 (%mem-u8-ref (+ (car l) 14)))
     (* 16777216 (%mem-u8-ref (+ (car l) 15)))))
(define (glb-json l)
  (let* ((b (+ (car l) 20))
         (n (glb-jchunk l))
         (s (make-string n #\space)))
    (let loop ((i 0))
      (if (= i n)
          (string->json s)
          (begin (string-set! s i (integer->char (%mem-u8-ref (+ b i))))
                 (loop (+ i 1)))))))
(define j (glb-json loc))

;; ---- (a) the mesh still round-trips, skin inputs and all --------
(define prim-ok
  (let ((q (car (gltf-prims g))))
    (and (= (length (gltf-prims g)) 1)
         (equal? (gprim-layout q) skin-layout)
         (= (gprim-stride q) 64)
         (= (gprim-vbytes q) (* vcount vstride))
         ;; joints made the trip through u8 and back to floats
         (bytes=? (gprim-vbase q) vbase (* vcount vstride))
         (= (gprim-icount q) 3)
         (= (rd-u16 (gprim-ibase q)) 0)
         (= (rd-u16 (+ (gprim-ibase q) 2)) 1)
         (= (rd-u16 (+ (gprim-ibase q) 4)) 2)
         (equal? (gprim-color q) (vector 0.2 0.4 0.6 1.0)))))

;; JOINTS_0 is the one attribute that does NOT stay in the
;; interleave: glTF wants integers there.  It gets a bufferView of
;; its own, while WEIGHTS_0 is described where it already lies.
(define joints-json-ok
  (and (= (json-ref j "meshes" 0 "primitives" 0 "attributes" "JOINTS_0") 3)
       (= (json-ref j "meshes" 0 "primitives" 0 "attributes" "WEIGHTS_0") 4)
       (= (json-ref j "accessors" 3 "componentType") 5121)   ; u8
       (equal? (json-ref j "accessors" 3 "type") "VEC4")
       (= (json-ref j "accessors" 3 "count") 3)
       (= (json-ref j "accessors" 3 "bufferView") 2)         ; its own
       (= (json-ref j "accessors" 3 "byteOffset") 0)
       (= (json-ref j "accessors" 4 "componentType") 5126)   ; f32
       (= (json-ref j "accessors" 4 "bufferView") 0)         ; interleave
       (= (json-ref j "accessors" 4 "byteOffset") 48)
       (= (json-ref j "bufferViews" 0 "byteStride") 64)
       (= (json-ref j "bufferViews" 2 "byteLength") 12)      ; 3 x 4 u8
       ;; the joint view has no byteStride: it is tightly packed
       (not (json-ref j "bufferViews" 2 "byteStride"))))

;; ---- (b) the node tree ------------------------------------------
(define nodes-json-ok
  (and (= (vector-length (json-ref j "nodes")) 5)
       (equal? (json-ref j "scenes" 0 "nodes") (vector 0 1))
       (= (json-ref j "nodes" 0 "mesh") 0)
       (= (json-ref j "nodes" 0 "skin") 0)
       (not (json-ref j "nodes" 1 "mesh"))
       (equal? (json-ref j "nodes" 1 "children") (vector 2))
       (equal? (json-ref j "nodes" 2 "children") (vector 3))
       (equal? (json-ref j "nodes" 3 "children") (vector 4))
       (not (json-ref j "nodes" 4 "children"))
       (equal? (json-ref j "nodes" 1 "name") "j0")
       ;; the key/value spelling landed in the same place as the
       ;; positional one
       (near? (exact->inexact (json-ref j "nodes" 2 "translation" 0)) 2.0)
       (near? (exact->inexact (json-ref j "nodes" 4 "translation" 0)) 8.0)))

(define skin-json-ok
  (and (equal? (json-ref j "skins" 0 "joints") (vector 1 2 3 4))
       (let ((a (json-ref j "skins" 0 "inverseBindMatrices")))
         (and (= a 6)                                  ; 5 attrs + indices
              (equal? (json-ref j "accessors" a "type") "MAT4")
              (= (json-ref j "accessors" a "count") 4)
              (= (json-ref j "accessors" a "componentType") 5126)))))

;; ---- (c) the skin, read back ------------------------------------
(define skin-parse-ok
  (let* ((sk (vector-ref (gltf-skins g) 0))
         (js (vector-ref sk 0))
         (ibms (vector-ref sk 1)))
    (and (= (gltf-joint-count g 0) 4)
         (equal? js (vector 1 2 3 4))
         ;; every inverse bind, float for float
         (let loop ((k 0))
           (or (= k 4)
               (let ((m (vector-ref ibms k))
                     (x (vector-ref (vector -1.0 -3.0 -7.0 -15.0) k)))
                 (and (near? (vector-ref m 0) 1.0)
                      (near? (vector-ref m 5) 1.0)
                      (near? (vector-ref m 10) 1.0)
                      (near? (vector-ref m 15) 1.0)
                      (near? (vector-ref m 12) x)
                      (near? (vector-ref m 13) 0.0)
                      (near? (vector-ref m 14) 0.0)
                      (near? (vector-ref m 1) 0.0)
                      (loop (+ k 1)))))))))

;; the bind palette is global(joint) x inverse-bind, and the fixture
;; makes the inverse binds the true inverses -- so this is FOUR
;; identity matrices, and only if the joint order, the parent links
;; and the matrices all survived.  Computed before any clip runs.
(define (ident? m)
  (let loop ((i 0))
    (or (= i 16)
        (and (near? (vector-ref m i)
                    (if (or (= i 0) (= i 5) (= i 10) (= i 15)) 1.0 0.0))
             (loop (+ i 1))))))

(define bind-ok
  (let ((pal (gltf-joint-matrices g 0)))
    (and (= (vector-length pal) 4)
         (ident? (vector-ref pal 0))
         (ident? (vector-ref pal 1))
         (ident? (vector-ref pal 2))
         (ident? (vector-ref pal 3)))))

;; ---- (d) the animations -----------------------------------------
(define anim-json-ok
  (and (= (vector-length (json-ref j "animations")) 3)
       (equal? (json-ref j "animations" 0 "name") "mix")
       (equal? (json-ref j "animations" 1 "name") "wag")
       (equal? (json-ref j "animations" 2 "name") "morph")
       (equal? (json-ref j "animations" 0 "samplers" 0 "interpolation")
               "CUBICSPLINE")
       (equal? (json-ref j "animations" 0 "samplers" 1 "interpolation")
               "STEP")
       (equal? (json-ref j "animations" 0 "samplers" 2 "interpolation")
               "LINEAR")
       (equal? (json-ref j "animations" 0 "samplers" 3 "interpolation")
               "LINEAR")
       (= (json-ref j "animations" 0 "channels" 0 "sampler") 0)
       (= (json-ref j "animations" 0 "channels" 0 "target" "node") 1)
       (equal? (json-ref j "animations" 0 "channels" 0 "target" "path")
               "translation")
       (= (json-ref j "animations" 0 "channels" 1 "target" "node") 2)
       (equal? (json-ref j "animations" 0 "channels" 1 "target" "path")
               "scale")
       (equal? (json-ref j "animations" 0 "channels" 2 "target" "path")
               "rotation")
       (= (json-ref j "animations" 2 "channels" 0 "target" "node") 0)
       (equal? (json-ref j "animations" 2 "channels" 0 "target" "path")
               "weights")))

;; the sampler accessors: an input carries the min and max the
;; specification demands, computed rather than copied -- and they are
;; the real extremes of the track, not its first and last element in
;; whichever order they happened to be written
(define sampler-acc-ok
  (let ((in0 (json-ref j "animations" 0 "samplers" 0 "input"))
        (out0 (json-ref j "animations" 0 "samplers" 0 "output"))
        (out1 (json-ref j "animations" 0 "samplers" 1 "output"))
        (out2 (json-ref j "animations" 0 "samplers" 2 "output"))
        (outm (json-ref j "animations" 2 "samplers" 0 "output")))
    (and (= in0 7)                       ; straight after the skin's
         (= out0 8)
         (equal? (json-ref j "accessors" in0 "type") "SCALAR")
         (= (json-ref j "accessors" in0 "count") 3)
         (near? (exact->inexact (json-ref j "accessors" in0 "min" 0)) 0.0)
         (near? (exact->inexact (json-ref j "accessors" in0 "max" 0)) 3.0)
         ;; min really is below max, on every input in the file
         (let loop ((a 7))
           (or (> a 18)
               (let ((mn (json-ref j "accessors" a "min"))
                     (mx (json-ref j "accessors" a "max")))
                 (and (or (not mn)
                          (fl<? (exact->inexact (vector-ref mn 0))
                                (exact->inexact (vector-ref mx 0)))
                          (near? (exact->inexact (vector-ref mn 0))
                                 (exact->inexact (vector-ref mx 0))))
                      (loop (+ a 1))))))
         ;; CUBICSPLINE output: three elements per key, one accessor
         (equal? (json-ref j "accessors" out0 "type") "VEC3")
         (= (json-ref j "accessors" out0 "count") 9)
         (equal? (json-ref j "accessors" out1 "type") "VEC3")
         (= (json-ref j "accessors" out1 "count") 3)
         (equal? (json-ref j "accessors" out2 "type") "VEC4")
         (= (json-ref j "accessors" out2 "count") 2)
         ;; morph weights: loose SCALARs, keys x targets of them
         (equal? (json-ref j "accessors" outm "type") "SCALAR")
         (= (json-ref j "accessors" outm "count") 4)
         ;; an output carries no min/max: only inputs must
         (not (json-ref j "accessors" out0 "min")))))

(define names-ok
  (and (equal? (gltf-animation-names g) '("mix" "wag" "morph"))
       (near? (gltf-animation-duration g 0) 3.0)
       (near? (gltf-animation-duration g 1) 1.0)
       (near? (gltf-animation-duration g 2) 2.0)))

;; ---- (e) what the clips actually pose ---------------------------
(define (pal k) (vector-ref (gltf-joint-matrices g 0) k))
(define (at? m x y z)
  (and (near? (vector-ref m 12) x)
       (near? (vector-ref m 13) y)
       (near? (vector-ref m 14) z)))

;; t = 0: every channel sits on its first key.  j0's cubic key is
;; the MIDDLE of its in/value/out triple -- (1,2,3), not the
;; in-tangent (0,0,0) and not the out-tangent (6,6,6) -- and the
;; chain is otherwise at bind, so every palette matrix is the same
;; pure translation (0,2,3).
(define t0-ok
  (begin
    (gltf-animate! g 0 0.0)
    (and (at? (pal 0) 0.0 2.0 3.0)
         (at? (pal 1) 0.0 2.0 3.0)
         (at? (pal 2) 0.0 2.0 3.0)
         (at? (pal 3) 0.0 2.0 3.0)
         (ident? (let ((m (pal 3)))
                   (let ((c (make-vector 16 0.0)))
                     (let cp ((i 0))
                       (when (< i 16)
                         (vector-set! c i (vector-ref m i))
                         (cp (+ i 1))))
                     (vector-set! c 12 0.0)
                     (vector-set! c 13 0.0)
                     (vector-set! c 14 0.0)
                     (vector-set! c 12 0.0)
                     c))))))

;; t = 1, the whole chain at once:
;;   j0  hermite over span [0,2] with key0's out-tangent (6,6,6):
;;         (5.5, 6.5, 7.5) -- a lerp would say (4,5,6)
;;   j1  STEP holds key 1: scale 2
;;   j2  nlerp half of a 90-degree turn IS 45 degrees, and the
;;         parent's scale rides along: the palette's first column is
;;         (2cos45, 2sin45, 0)
;;   j3  its own LINEAR translation, (8,0,2) at the halfway point
;; and the palette translations follow in closed form.
(define c45 0.70710678)
(define t1-ok
  (begin
    (gltf-animate! g 0 1.0)
    (and (at? (pal 0) 4.5 6.5 7.5)
         (at? (pal 1) 1.5 6.5 7.5)
         (at? (pal 2) (fl- 15.5 (fl* 14.0 c45))
              (fl- 6.5 (fl* 14.0 c45)) 7.5)
         ;; j3 differs from j2 in z alone: its own channel moved it
         ;; 2 along the parent's z, and the parent's scale doubled it
         (at? (pal 3) (fl- 15.5 (fl* 14.0 c45))
              (fl- 6.5 (fl* 14.0 c45)) 11.5)
         (near? (vector-ref (pal 0) 0) 1.0)
         (near? (vector-ref (pal 1) 0) 2.0)
         (near? (vector-ref (pal 1) 5) 2.0)
         (near? (vector-ref (pal 2) 0) (fl* 2.0 c45))
         (near? (vector-ref (pal 2) 1) (fl* 2.0 c45))
         (near? (vector-ref (pal 2) 4) (fl- 0.0 (fl* 2.0 c45))))))

;; STEP holds the left key inside a span and takes the right key AT
;; its own time -- read off j1's scale, which is all this palette
;; matrix's first column carries
(define step-ok
  (and (begin (gltf-animate! g 0 0.5) (near? (vector-ref (pal 1) 0) 1.0))
       (begin (gltf-animate! g 0 1.0) (near? (vector-ref (pal 1) 0) 2.0))
       (begin (gltf-animate! g 0 1.5) (near? (vector-ref (pal 1) 0) 2.0))
       (begin (gltf-animate! g 0 2.0) (near? (vector-ref (pal 1) 0) 3.0))))

;; the second cubic span has zero tangents, so its midpoint is the
;; plain average -- (10,11,12), which the inverse bind moves to
;; (9,11,12)
(define cub-mid-ok
  (begin
    (gltf-animate! g 0 2.5)
    (at? (pal 0) 9.0 11.0 12.0)))

;; the second clip drives j1's rotation alone.  A clip returns the
;; nodes it TOUCHES to bind before sampling, so "wag" at t = 0 undoes
;; what "mix" did to j1 while leaving j0's pose in place -- and every
;; palette matrix falls back to the same pure translation.  At the
;; halfway point the nlerp of identity and a 90-degree turn about y
;; is 45 degrees, which the palette's leading diagonal shows.
(define wag-ok
  (and (begin
         (gltf-animate! g 0 0.0)
         (gltf-animate! g 1 0.0)
         (and (at? (pal 0) 0.0 2.0 3.0)
              (at? (pal 1) 0.0 2.0 3.0)
              (at? (pal 2) 0.0 2.0 3.0)
              (at? (pal 3) 0.0 2.0 3.0)))
       (begin
         (gltf-animate! g 1 0.5)
         (and (near? (vector-ref (pal 1) 0) c45)
              (near? (vector-ref (pal 1) 5) 1.0)
              ;; j0 is upstream of the clip and did not move
              (near? (vector-ref (pal 0) 0) 1.0)))))

;; the morph channel survives as a channel: two targets a key, read
;; back out of an accessor of loose scalars
(define morph-chan-ok
  (let* ((clip (vector-ref (gltf-anims g) 2))
         (ch (vector-ref (vector-ref clip 1) 0))
         (times (vector-ref ch 2))
         (vals (vector-ref ch 3)))
    (and (= (vector-ref ch 0) 0)
         (eq? (vector-ref ch 1) 'weights)
         (eq? (vector-ref ch 5) 'linear)
         (= (vector-length times) 2)
         (near? (vector-ref times 0) 0.0)
         (near? (vector-ref times 1) 2.0)
         (= (vector-length (vector-ref vals 0)) 2)
         (near? (vector-ref (vector-ref vals 0) 0) 0.0)
         (near? (vector-ref (vector-ref vals 0) 1) 1.0)
         (near? (vector-ref (vector-ref vals 1) 0) 0.25)
         (near? (vector-ref (vector-ref vals 1) 1) 0.75))))

;; ---- (f) the written file draws, palette and all ----------------
(define gllog (js-get (js-global) "__gllog"))
(define (log-len) (js->number (js-get gllog "length")))
(define (entry i) (js->string (js-index gllog i)))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-from p from)
  (let ((n (log-len)))
    (let loop ((i from) (c 0))
      (if (= i n)
          c
          (loop (+ i 1) (if (prefix? p (entry i)) (+ c 1) c))))))

(define skin-prog (fx-program! gltf-skin-vs mesh-tex-fs))
(define mark (log-len))
(cmd-begin!)
(gltf-draw! g skin-prog (m4-identity))
(cmd-flush!)
(define draw-ok
  (and (= (count-from "drawElements:TRI:3:US" mark) 1)
       ;; four joints x sixteen floats, through the uniform-array
       ;; carrier the program declares
       (= (count-from "uniformMat4:U:u_joints:64" mark) 1)
       ;; the vertex upload is the 64-byte interleave the file
       ;; declared, joints slot and all: 3 x 64 bytes = 48 floats
       (= (count-from "bufferData:48" mark) 1)
       ;; and every attribute is bound at the offset the interleave
       ;; puts it, joints at 32 and weights at 48
       (= (count-from "attrib:3,4,F,false,64,32" mark) 1)
       (= (count-from "attrib:4,4,F,false,64,48" mark) 1)))

;; ---- (g) forced u16 joint indices -------------------------------
;; The auto width only reaches u16 past joint 255, which the loader's
;; own ceiling puts out of reach, so the option is how the branch is
;; exercised -- and the parser has to read it back the same.
(define loc-u16 (glb-write! (list (append prim (list 'joints-u16? #t)))
                            'nodes nodes 'mesh-node 0 'skin skin))
(define g-u16 (gltf-parse (car loc-u16) (cdr loc-u16)))
(define ju16-ok
  (let ((j2 (glb-json loc-u16))
        (q (car (gltf-prims g-u16))))
    (and (= (json-ref j2 "accessors" 3 "componentType") 5123)
         (= (json-ref j2 "bufferViews" 2 "byteLength") 24)   ; 3 x 4 u16
         (bytes=? (gprim-vbase q) vbase (* vcount vstride)))))

;; ---- (h) re-export: a parsed asset goes straight back out -------
;; The recipe docs/graphics.md gives.  Nothing here is a staging
;; address: the writer takes the very vectors (gfx gltf) parsed.
(define g2 (gltf-parse (car loc) (cdr loc)))

(define (node->desc v)
  (list #f (vector-ref v 11)
        (vector (vector-ref v 0) (vector-ref v 1) (vector-ref v 2))
        (vector (vector-ref v 3) (vector-ref v 4)
                (vector-ref v 5) (vector-ref v 6))
        (vector (vector-ref v 7) (vector-ref v 8) (vector-ref v 9))))

;; CUBICSPLINE is the one shape the parser splits and the writer
;; wants whole: in-tangent, value, out-tangent, per key, in that order
(define (chan->desc ch)
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
                            (vector-set! o (+ (* 3 i) 1) (vector-ref vals i))
                            (vector-set! o (+ (* 3 i) 2)
                                         (vector-ref (vector-ref ch 7) i))
                            (loop (+ i 1))))))
                  vals)))
    (append (list (vector-ref ch 0) path times out n interp)
            (if (eq? path 'weights)
                (list 'components (vector-length (vector-ref vals 0)))
                '()))))

(define (clip->desc a)
  (list (vector-ref a 0)
        (map chan->desc (vector->list (vector-ref a 1)))))

(define loc-re
  (glb-write!
   (map (lambda (p)
          (list (gprim-layout p) (gprim-vbase p)
                (quotient (gprim-vbytes p) (gprim-stride p))
                (gprim-ibase p) (gprim-icount p)
                'color (gprim-color p)
                'index-u32? (gprim-index-u32? p)))
        (gltf-prims g2))
   'nodes (map node->desc (vector->list (gltf-nodes g2)))
   'mesh-node 0
   'skin (list (vector-ref (vector-ref (gltf-skins g2) 0) 0)
               (vector-ref (vector-ref (gltf-skins g2) 0) 1))
   'anims (map clip->desc (vector->list (gltf-anims g2)))))

(define jre (glb-json loc-re))
(define gre (gltf-parse (car loc-re) (cdr loc-re)))

;; The two files are not the same bytes -- the second generation has
;; no node names, and it spells out transforms the first left to
;; glTF's defaults.  Every accessor still has to describe the same
;; data in the same order.
(define (acc-same? a b i)
  (and (= (json-ref a "accessors" i "componentType")
          (json-ref b "accessors" i "componentType"))
       (equal? (json-ref a "accessors" i "type")
               (json-ref b "accessors" i "type"))
       (= (json-ref a "accessors" i "count")
          (json-ref b "accessors" i "count"))
       (let ((ma (json-ref a "accessors" i "min"))
             (mb (json-ref b "accessors" i "min")))
         (and (eq? (and ma #t) (and mb #t))
              (or (not ma)
                  (let loop ((k 0))
                    (or (= k (vector-length ma))
                        (and (near? (exact->inexact (vector-ref ma k))
                                    (exact->inexact (vector-ref mb k)))
                             (near? (exact->inexact
                                     (vector-ref (json-ref a "accessors" i "max") k))
                                    (exact->inexact
                                     (vector-ref (json-ref b "accessors" i "max") k)))
                             (loop (+ k 1))))))))))

(define reexport-json-ok
  (and (= (vector-length (json-ref jre "accessors"))
          (vector-length (json-ref j "accessors")))
       (= (vector-length (json-ref jre "bufferViews"))
          (vector-length (json-ref j "bufferViews")))
       (= (vector-length (json-ref jre "nodes"))
          (vector-length (json-ref j "nodes")))
       (equal? (json-ref jre "skins" 0 "joints")
               (json-ref j "skins" 0 "joints"))
       (equal? (json-ref jre "nodes" 2 "children")
               (json-ref j "nodes" 2 "children"))
       (equal? (json-ref jre "scenes" 0 "nodes")
               (json-ref j "scenes" 0 "nodes"))
       (= (json-ref jre "nodes" 0 "skin") 0)
       (equal? (json-ref jre "animations" 0 "samplers" 0 "interpolation")
               "CUBICSPLINE")
       (equal? (json-ref jre "animations" 0 "samplers" 1 "interpolation")
               "STEP")
       (let loop ((i 0))
         (or (= i (vector-length (json-ref j "accessors")))
             (and (acc-same? j jre i) (loop (+ i 1)))))))

;; and the second generation poses identically to the first
(define (pal-re k) (vector-ref (gltf-joint-matrices gre 0) k))
(define (pal-same? a b)
  (let loop ((i 0))
    (or (= i 16)
        (and (near? (vector-ref a i) (vector-ref b i)) (loop (+ i 1))))))

(define reexport-pose-ok
  (and (equal? (gltf-animation-names gre) '("mix" "wag" "morph"))
       (near? (gltf-animation-duration gre 0) 3.0)
       (near? (gltf-animation-duration gre 2) 2.0)
       (bytes=? (gprim-vbase (car (gltf-prims gre)))
                vbase (* vcount vstride))
       ;; bind first: the skeleton itself made the second trip
       (ident? (pal-re 0)) (ident? (pal-re 3))
       (begin
         (gltf-animate! g 0 1.0)
         (gltf-animate! gre 0 1.0)
         (and (pal-same? (pal 0) (pal-re 0))
              (pal-same? (pal 1) (pal-re 1))
              (pal-same? (pal 2) (pal-re 2))
              (pal-same? (pal 3) (pal-re 3))))
       (begin
         (gltf-animate! g 0 2.5)
         (gltf-animate! gre 0 2.5)
         (pal-same? (pal 0) (pal-re 0)))))

;; ---- (i) refusals ------------------------------------------------
(define refuse-ok
  (and (guard (e (#t #t))                  ; a joint index no skin owns
         (glb-write! (list prim) 'nodes nodes
                     'skin (list (list 1 2) ibm-base))
         #f)
       (guard (e (#t #t))                  ; a parent the file lacks
         (glb-write! (list prim) 'nodes (list (list "a" 4)) 'skin skin)
         #f)
       (guard (e (#t #t))                  ; a parent ring
         (glb-write! (list prim)
                     'nodes (list (list "a" 1) (list "b" 0))
                     'skin (list (list 0) #f))
         #f)
       (guard (e (#t #t))                  ; a node that is its own parent
         (glb-write! (list prim) 'nodes (list (list "a" 0))
                     'skin (list (list 0) #f))
         #f)
       (guard (e (#t #t))                  ; a skin joint the file lacks
         (glb-write! (list prim) 'nodes nodes
                     'skin (list (list 1 2 3 9) ibm-base))
         #f)
       (guard (e (#t #t))                  ; too few inverse binds
         (glb-write! (list prim) 'nodes nodes
                     'skin (list (list 1 2 3 4)
                                 (vector (vector-ref
                                          (vector-ref
                                           (vector-ref (gltf-skins g2) 0) 1)
                                          0))))
         #f)
       (guard (e (#t #t))                  ; a channel node the file lacks
         (glb-write! (list prim) 'nodes nodes 'skin skin
                     'anims (list (list "x" (list (list 9 'translation
                                                       lin-t t3-v 2)))))
         #f)
       (guard (e (#t #t))                  ; a path no reader knows
         (glb-write! (list prim) 'nodes nodes 'skin skin
                     'anims (list (list "x" (list (list 1 'wobble
                                                       lin-t t3-v 2)))))
         #f)
       (guard (e (#t #t))                  ; an interpolation no reader knows
         (glb-write! (list prim) 'nodes nodes 'skin skin
                     'anims (list (list "x" (list (list 1 'translation
                                                       lin-t t3-v 2
                                                       'interpolation
                                                       'smooth)))))
         #f)
       (guard (e (#t #t))                  ; keyframe times going backwards
         (glb-write! (list prim) 'nodes nodes 'skin skin
                     'anims (list (list "x" (list (list 1 'translation
                                                       (vector 2.0 0.0)
                                                       t3-v 2)))))
         #f)
       (guard (e (#t #t))                  ; a source shorter than the count
         (glb-write! (list prim) 'nodes nodes 'skin skin
                     'anims (list (list "x" (list (list 1 'translation
                                                       (vector 0.0 1.0)
                                                       (vector (vector 0.0 0.0 0.0))
                                                       2)))))
         #f)
       (guard (e (#t #t))                  ; a fractional joint index
         (let* ((b (fx-alloc! (* vcount vstride))))
           (let cp ((i 0))
             (when (< i (* vcount vstride))
               (%mem-u8-set! (+ b i) (%mem-u8-ref (+ vbase i)))
               (cp (+ i 1))))
           (%mem-f32-set! (+ b 32) 1.5)
           (glb-write! (list (list skin-layout b vcount ibase 3))
                       'nodes nodes 'skin skin))
         #f)
       (guard (e (#t #t))                  ; 'mesh-node past the nodes
         (glb-write! (list prim) 'nodes nodes 'mesh-node 9 'skin skin)
         #f)
       (guard (e (#t #t))                  ; an unknown top-level option
         (glb-write! (list prim) 'skins skin)
         #f)))

(display (and prim-ok joints-json-ok nodes-json-ok skin-json-ok
              skin-parse-ok bind-ok anim-json-ok sampler-acc-ok names-ok
              t0-ok t1-ok step-ok cub-mid-ok wag-ok morph-chan-ok
              draw-ok ju16-ok reexport-json-ok reexport-pose-ok
              refuse-ok))
