;; expect: #t
;; (gfx glb): GLB written from staging memory, read back by the
;; parser that reads real files.  The round trip is the oracle --
;; layout, vertex bytes, indices and material colour all have to
;; survive it -- and the container itself is checked where a parser
;; would not notice: chunk alignment, the space padding the JSON
;; chunk takes and the zero padding the BIN chunk takes, POSITION's
;; mandatory min/max, and the index component type.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf) (gfx glb) (web json))

;; ---- the recording mock GL (as in test/gltf-draw.ss) -------------
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', UNSIGNED_INT:'UI', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, generateMipmap(t){ push('genMip', t) }, texImage2D(...a){ push('texImage', a.length) }, activeTexture(u){ push('activeTexture', u) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

;; fx-init! rewinds the staging bump allocator, so it runs BEFORE any
;; fx-alloc! here -- otherwise the GLBs written below would be handed
;; out a second time and overwritten.
(fx-init! (js-get (js-global) "__mockcanvas"))
(define heap0 (fx-alloc! 0))            ; where a re-init rewinds to

;; ---- staging helpers --------------------------------------------
(define (rd-u32 at)
  (+ (%mem-u8-ref at)
     (* 256 (%mem-u8-ref (+ at 1)))
     (* 65536 (%mem-u8-ref (+ at 2)))
     (* 16777216 (%mem-u8-ref (+ at 3)))))
(define (rd-u16 at)
  (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))))

(define (bytes=? a b n)
  (let loop ((i 0))
    (cond ((= i n) #t)
          ((= (%mem-u8-ref (+ a i)) (%mem-u8-ref (+ b i))) (loop (+ i 1)))
          (else #f))))

;; a vertex block filled so that every 4-byte slot in the stride
;; holds a distinct value: a wrong byteStride or byteOffset cannot
;; land on a value that happens to match
(define (fill-verts! base vcount stride)
  (let vert ((v 0))
    (when (< v vcount)
      (let slot ((c 0))
        (when (< c (quotient stride 4))
          (%mem-f32-set! (+ base (* v stride) (* 4 c))
                         (+ (* 8.0 (fixnum->flonum v))
                            (* 0.25 (fixnum->flonum c))))
          (slot (+ c 1))))
      (vert (+ v 1)))))

(define (u16-indices! base is)
  (let loop ((l is) (k 0))
    (unless (null? l)
      (%mem-u8-set! (+ base (* 2 k)) (remainder (car l) 256))
      (%mem-u8-set! (+ base (* 2 k) 1) (quotient (car l) 256))
      (loop (cdr l) (+ k 1)))))

(define (u32-indices! base is)
  (let loop ((l is) (k 0))
    (unless (null? l)
      (let ((v (car l)) (a (+ base (* 4 k))))
        (%mem-u8-set! a (remainder v 256))
        (%mem-u8-set! (+ a 1) (remainder (quotient v 256) 256))
        (%mem-u8-set! (+ a 2) (remainder (quotient v 65536) 256))
        (%mem-u8-set! (+ a 3) (remainder (quotient v 16777216) 256)))
      (loop (cdr l) (+ k 1)))))

;; a whole primitive's worth of staging, ready to hand to glb-write!
(define (make-prim layout vcount is u32?)
  (let* ((stride (glb-stride layout))
         (vbase (fx-alloc! (* vcount stride)))
         (n (length is))
         (ibase (fx-alloc! (* n (if u32? 4 2)))))
    (fill-verts! vbase vcount stride)
    (if u32? (u32-indices! ibase is) (u16-indices! ibase is))
    (list layout vbase vcount stride ibase n)))

(define (pl-layout p) (car p))
(define (pl-vbase p) (cadr p))
(define (pl-vcount p) (caddr p))
(define (pl-stride p) (cadddr p))
(define (pl-ibase p) (list-ref p 4))
(define (pl-icount p) (list-ref p 5))

;; the descriptor glb-write! eats, straight out of the same fields a
;; parsed gprim exposes
(define (desc p . opts)
  (append (list (pl-layout p) (pl-vbase p) (pl-vcount p)
                (pl-ibase p) (pl-icount p))
          opts))

;; every field of a written primitive against the source it came from
(define (roundtrip-ok? p g k u32?)
  (let ((q (list-ref (gltf-prims g) k)))
    (and (equal? (gprim-layout q) (pl-layout p))
         (= (gprim-stride q) (pl-stride p))
         (= (gprim-vbytes q) (* (pl-vcount p) (pl-stride p)))
         (bytes=? (gprim-vbase q) (pl-vbase p) (gprim-vbytes q))
         (= (gprim-icount q) (pl-icount p))
         (eq? (and (gprim-index-u32? q) #t) u32?)
         (let loop ((i 0))
           (cond ((= i (pl-icount p)) #t)
                 ((= (if u32?
                         (rd-u32 (+ (gprim-ibase q) (* 4 i)))
                         (rd-u16 (+ (gprim-ibase q) (* 2 i))))
                     (if u32?
                         (rd-u32 (+ (pl-ibase p) (* 4 i)))
                         (rd-u16 (+ (pl-ibase p) (* 2 i)))))
                  (loop (+ i 1)))
                 (else #f))))))

;; ---- the container, byte by byte --------------------------------
(define (glb-jchunk loc) (rd-u32 (+ (car loc) 12)))
(define (glb-binchunk loc) (rd-u32 (+ (car loc) 20 (glb-jchunk loc))))
(define (glb-bin loc) (+ (car loc) 20 (glb-jchunk loc) 8))

(define (glb-json-text loc)
  (let* ((b (+ (car loc) 20))
         (n (glb-jchunk loc))
         (s (make-string n #\space)))
    (let loop ((i 0))
      (if (= i n)
          s
          (begin (string-set! s i (integer->char (%mem-u8-ref (+ b i))))
                 (loop (+ i 1)))))))

(define (glb-json loc) (string->json (glb-json-text loc)))

;; trailing spaces of the JSON chunk = its padding
(define (json-pad loc)
  (let ((b (+ (car loc) 20)))
    (let loop ((k (glb-jchunk loc)) (n 0))
      (if (and (> k 0) (= (%mem-u8-ref (+ b (- k 1))) 32))
          (loop (- k 1) (+ n 1))
          n))))

;; the chunk is 4-aligned, and everything past the JSON's closing
;; brace is the space the specification names -- not a zero
(define (json-pad-ok? loc)
  (let ((n (json-pad loc)) (jl (glb-jchunk loc)))
    (and (= (remainder jl 4) 0)
         (< n 4)
         (= (%mem-u8-ref (+ (car loc) 20 (- jl n 1))) 125))))  ; #\}

(define (header-ok? loc)
  (let ((b (car loc)))
    (and (= (rd-u32 b) #x46546C67)               ; "glTF"
         (= (rd-u32 (+ b 4)) 2)
         (= (rd-u32 (+ b 8)) (cdr loc))
         (= (rd-u32 (+ b 16)) #x4E4F534A)        ; "JSON"
         (= (rd-u32 (+ b 20 (glb-jchunk loc) 4)) #x004E4942) ; "BIN\0"
         (= (remainder (cdr loc) 4) 0)
         (= (remainder (glb-binchunk loc) 4) 0)
         (= (+ 12 8 (glb-jchunk loc) 8 (glb-binchunk loc)) (cdr loc))
         ;; the buffer the JSON declares IS the BIN chunk
         (= (json-ref (glb-json loc) "buffers" 0 "byteLength")
            (glb-binchunk loc)))))

;; ---- (a) one primitive, the widest static layout ----------------
(define wide '(position normal uv tangent color))
(define pa (make-prim wide 4 '(0 1 2 2 1 3) #f))
(define loc-a (glb-write! (list (desc pa 'color (vector 0.25 0.5 0.75 1.0)))))
(define ga (gltf-parse (car loc-a) (cdr loc-a)))

(define a-ok
  (and (= (pl-stride pa) 64)
       (= (length (gltf-prims ga)) 1)
       (roundtrip-ok? pa ga 0 #f)
       (equal? (gprim-color (car (gltf-prims ga)))
               (vector 0.25 0.5 0.75 1.0))
       (header-ok? loc-a)
       (json-pad-ok? loc-a)))

;; a primitive with no colour option gets no material at all, and
;; the loader's own default answers instead
(define loc-nomat (glb-write! (list (desc pa))))
(define g-nomat (gltf-parse (car loc-nomat) (cdr loc-nomat)))
(define nomat-ok
  (and (not (json-ref (glb-json loc-nomat) "materials"))
       (equal? (gprim-color (car (gltf-prims g-nomat)))
               (vector 0.8 0.8 0.8 1.0))))

;; ---- (b) several primitives, different layouts, one file --------
(define pb (make-prim '(position normal) 3 '(0 1 2) #f))
(define pc (make-prim '(position normal uv) 5 '(0 1 2 0 2 3 0 3 4) #f))
(define loc-m
  (glb-write! (list (desc pa 'color (vector 1.0 0.0 0.0 1.0))
                    (desc pb)
                    (desc pc 'color (vector 0.0 1.0 0.0 0.5)))))
(define gm (gltf-parse (car loc-m) (cdr loc-m)))

(define multi-ok
  (and (= (length (gltf-prims gm)) 3)
       (roundtrip-ok? pa gm 0 #f)
       (roundtrip-ok? pb gm 1 #f)
       (roundtrip-ok? pc gm 2 #f)
       ;; the strides really do differ, so a shared bufferView or a
       ;; stride copied from the first primitive would show
       (= (gprim-stride (list-ref (gltf-prims gm) 0)) 64)
       (= (gprim-stride (list-ref (gltf-prims gm) 1)) 24)
       (= (gprim-stride (list-ref (gltf-prims gm) 2)) 32)
       ;; materials are numbered per primitive that asks for one
       (equal? (gprim-color (list-ref (gltf-prims gm) 0))
               (vector 1.0 0.0 0.0 1.0))
       (equal? (gprim-color (list-ref (gltf-prims gm) 1))
               (vector 0.8 0.8 0.8 1.0))
       (equal? (gprim-color (list-ref (gltf-prims gm) 2))
               (vector 0.0 1.0 0.0 0.5))
       (header-ok? loc-m)
       (json-pad-ok? loc-m)))

;; every accessor names the bufferView its own primitive owns, at the
;; offset the interleave puts it -- read out of the file, not out of
;; the writer's own bookkeeping
(define view-ok
  (let ((j (glb-json loc-m)))
    (and (= (vector-length (json-ref j "bufferViews")) 6)
         (= (vector-length (json-ref j "accessors")) 13)
         (= (json-ref j "bufferViews" 0 "byteStride") 64)
         (= (json-ref j "bufferViews" 2 "byteStride") 24)
         (= (json-ref j "bufferViews" 4 "byteStride") 32)
         ;; primitive 0: position/normal/uv/tangent/color at 0/12/24/32/48
         (= (json-ref j "accessors" 0 "byteOffset") 0)
         (= (json-ref j "accessors" 1 "byteOffset") 12)
         (= (json-ref j "accessors" 2 "byteOffset") 24)
         (= (json-ref j "accessors" 3 "byteOffset") 32)
         (= (json-ref j "accessors" 4 "byteOffset") 48)
         (= (json-ref j "accessors" 3 "bufferView") 0)
         (= (json-ref j "accessors" 5 "bufferView") 1)   ; its indices
         (equal? (json-ref j "accessors" 3 "type") "VEC4")
         (equal? (json-ref j "accessors" 2 "type") "VEC2")
         (= (json-ref j "accessors" 0 "componentType") 5126)
         (= (json-ref j "meshes" 0 "primitives" 0 "attributes" "TANGENT") 3)
         (= (json-ref j "meshes" 0 "primitives" 2 "attributes" "POSITION") 9)
         (= (json-ref j "meshes" 0 "primitives" 2 "indices") 12)
         (= (json-ref j "meshes" 0 "primitives" 2 "material") 1))))

;; ---- (c) u16 and u32 indices ------------------------------------
(define pu (make-prim '(position normal) 4 '(0 1 2 3 2 1) #t))
(define loc-u32 (glb-write! (list (desc pu 'index-u32? #t))))
(define gu32 (gltf-parse (car loc-u32) (cdr loc-u32)))
(define u32-ok
  (and (= (json-ref (glb-json loc-u32) "accessors" 2 "componentType") 5125)
       ;; six u32 indices, not three
       (= (json-ref (glb-json loc-u32) "bufferViews" 1 "byteLength") 24)
       ;; the loader repacks small meshes as u16, so compare values
       (let ((q (car (gltf-prims gu32))))
         (and (= (gprim-icount q) 6)
              (let loop ((i 0))
                (cond ((= i 6) #t)
                      ((= (rd-u16 (+ (gprim-ibase q) (* 2 i)))
                          (rd-u32 (+ (pl-ibase pu) (* 4 i))))
                       (loop (+ i 1)))
                      (else #f)))))))

(define u16-ok
  (and (= (json-ref (glb-json loc-a) "accessors" 5 "componentType") 5123)
       (= (json-ref (glb-json loc-a) "bufferViews" 1 "byteLength") 12)))

;; past 65536 vertices the index width switches on its own, exactly
;; where (gfx gltf) switches on the way back in
(define big-n 65537)
(define pbig (make-prim '(position normal) big-n
                        (list 0 1 65536 65536 1 0) #t))
(define loc-big (glb-write! (list (desc pbig))))
(define big-ok
  (let ((j (glb-json loc-big)))
    (and (= (json-ref j "accessors" 2 "componentType") 5125)
         (= (json-ref j "accessors" 0 "count") big-n)
         (= (json-ref j "bufferViews" 1 "byteLength") 24))))

;; a primitive with no index array at all: the loader draws its
;; vertices in order, so icount comes back as the vertex count
(define pn (make-prim '(position normal uv) 3 '(0 1 2) #f))
(define loc-noidx
  (glb-write! (list (list (pl-layout pn) (pl-vbase pn) 3 #f 0))))
(define gnoidx (gltf-parse (car loc-noidx) (cdr loc-noidx)))
(define noidx-ok
  (let ((j (glb-json loc-noidx))
        (q (car (gltf-prims gnoidx))))
    (and (= (vector-length (json-ref j "bufferViews")) 1)
         (= (vector-length (json-ref j "accessors")) 3)
         (not (json-ref j "meshes" 0 "primitives" 0 "indices"))
         (equal? (gprim-layout q) (pl-layout pn))
         (= (gprim-icount q) 3)
         (bytes=? (gprim-vbase q) (pl-vbase pn) (gprim-vbytes q))
         (header-ok? loc-noidx)
         (json-pad-ok? loc-noidx))))

;; ---- (d) POSITION min/max ---------------------------------------
;; asymmetric and negative on every axis, and one axis constant: a
;; swapped min/max, a per-axis mix-up or a hard-coded bound all show
(define pmm-layout '(position normal))
(define pmm-stride (glb-stride pmm-layout))
(define pmm-base (fx-alloc! (* 4 pmm-stride)))
(define (pos! v x y z)
  (let ((d (+ pmm-base (* v pmm-stride))))
    (%mem-f32-set! d x)
    (%mem-f32-set! (+ d 4) y)
    (%mem-f32-set! (+ d 8) z)
    (%mem-f32-set! (+ d 12) 0.0)
    (%mem-f32-set! (+ d 16) 1.0)
    (%mem-f32-set! (+ d 20) 0.0)))
(pos! 0 -3.0   0.5  2.0)
(pos! 1  0.25 -7.5  2.0)
(pos! 2 -0.75  6.25 2.0)
(pos! 3 -2.5  -0.25 2.0)
(define pmm-idx (fx-alloc! 8))
(u16-indices! pmm-idx '(0 1 2))
(define loc-mm
  (glb-write! (list (list pmm-layout pmm-base 4 pmm-idx 3))))
(define mm-json (glb-json loc-mm))
(define (mm-ref key i)
  (exact->inexact (json-ref mm-json "accessors" 0 key i)))
(define minmax-ok
  (and (fl=? (mm-ref "min" 0) -3.0)
       (fl=? (mm-ref "min" 1) -7.5)
       (fl=? (mm-ref "min" 2) 2.0)
       (fl=? (mm-ref "max" 0) 0.25)
       (fl=? (mm-ref "max" 1) 6.25)
       (fl=? (mm-ref "max" 2) 2.0)
       ;; only POSITION carries them
       (not (json-ref mm-json "accessors" 1 "min"))))

;; ---- a padded interleave, and a colour given as a list -----------
;; 'stride widens the vertex block past what the layout needs; the
;; loader repacks to its own canonical 24, so the VALUES have to
;; survive even though the bytes do not
(define ps-stride 32)
(define ps-base (fx-alloc! (* 3 ps-stride)))
(let v ((i 0))
  (when (< i 3)
    (let ((d (+ ps-base (* i ps-stride))))
      (%mem-f32-set! d (fixnum->flonum i))
      (%mem-f32-set! (+ d 4) 0.5)
      (%mem-f32-set! (+ d 8) -1.25)
      (%mem-f32-set! (+ d 12) 0.0)
      (%mem-f32-set! (+ d 16) 1.0)
      (%mem-f32-set! (+ d 20) 0.0)
      (%mem-f32-set! (+ d 24) 99.0)        ; the padding, never read
      (%mem-f32-set! (+ d 28) 99.0))
    (v (+ i 1))))
(define ps-idx (fx-alloc! 8))
(u16-indices! ps-idx '(0 1 2))
(define loc-s
  (glb-write! (list (list '(position normal) ps-base 3 ps-idx 3
                          'stride ps-stride
                          'color (list 0.5 0.25 0.125 1.0)))))
(define gs2 (gltf-parse (car loc-s) (cdr loc-s)))
(define stride-ok
  (let* ((j (glb-json loc-s))
         (q (car (gltf-prims gs2)))
         (vb (gprim-vbase q)))
    (and (= (json-ref j "bufferViews" 0 "byteStride") 32)
         (= (json-ref j "bufferViews" 0 "byteLength") 96)
         (= (gprim-stride q) 24)             ; repacked, padding dropped
         (fl=? (%mem-f32-ref vb) 0.0)
         (fl=? (%mem-f32-ref (+ vb 4)) 0.5)
         (fl=? (%mem-f32-ref (+ vb 8)) -1.25)
         (fl=? (%mem-f32-ref (+ vb 16)) 1.0)
         (fl=? (%mem-f32-ref (+ vb 24)) 1.0)  ; vertex 1's x
         (fl=? (%mem-f32-ref (+ vb 48)) 2.0)  ; vertex 2's x
         ;; POSITION's bounds come from the strided reads, not from
         ;; the padding that sits four bytes past normal
         (fl=? (exact->inexact (json-ref j "accessors" 0 "max" 0)) 2.0)
         (fl=? (exact->inexact (json-ref j "accessors" 0 "max" 1)) 0.5)
         ;; a colour given as a list reads back the same as a vector
         (equal? (gprim-color q) (vector 0.5 0.25 0.125 1.0))
         (header-ok? loc-s)
         (json-pad-ok? loc-s))))

;; a stride under the layout's own size, or off the 4-byte grid, is
;; a file no reader could interpret -- refused at the call
(define stride-refuse-ok
  (and (guard (e (#t #t))
         (glb-write! (list (list '(position normal) ps-base 3 ps-idx 3
                                 'stride 20)))
         #f)
       (guard (e (#t #t))
         (glb-write! (list (list '(position normal) ps-base 3 ps-idx 3
                                 'stride 26)))
         #f)))

;; ---- (e) alignment and padding ----------------------------------
;; an odd index count leaves the index block 2 bytes short of the
;; next 4-byte boundary; the next primitive still has to start there,
;; and the gap has to be zero
(define pe1 (make-prim '(position normal) 3 '(0 1 2) #f))
(define pe2 (make-prim '(position normal uv) 3 '(0 1 2) #f))
(define loc-e (glb-write! (list (desc pe1) (desc pe2))))
(define ge (gltf-parse (car loc-e) (cdr loc-e)))
(define pad-ok
  (let* ((j (glb-json loc-e))
         (i-off (json-ref j "bufferViews" 1 "byteOffset"))
         (i-len (json-ref j "bufferViews" 1 "byteLength"))
         (next (json-ref j "bufferViews" 2 "byteOffset"))
         (bin (glb-bin loc-e)))
    (and (= i-len 6)                       ; three u16 indices
         (= next (+ i-off 8))              ; rounded up from 6
         (= (%mem-u8-ref (+ bin i-off 6)) 0)
         (= (%mem-u8-ref (+ bin i-off 7)) 0)
         (= (remainder next 4) 0)
         (roundtrip-ok? pe1 ge 0 #f)
         (roundtrip-ok? pe2 ge 1 #f)
         (header-ok? loc-e)
         (json-pad-ok? loc-e))))

;; the JSON chunk's own padding: sweep vertex counts so the raw JSON
;; length lands on every residue, and demand a space pad each time
(define pad-sweep
  (let loop ((n 3) (ok #t) (saw-pad #f))
    (if (> n 10)
        (and ok saw-pad)
        (let* ((p (make-prim '(position normal) n '(0 1 2) #f))
               (loc (glb-write! (list (desc p)))))
          (loop (+ n 1)
                (and ok (json-pad-ok? loc) (header-ok? loc))
                (or saw-pad (> (json-pad loc) 0)))))))

;; ---- refusals ---------------------------------------------------
(define refuse-ok
  (and (guard (e (#t #t))                  ; skinning is v2
         (glb-write! (list (list '(position normal joints weights)
                                 (pl-vbase pb) 3 (pl-ibase pb) 3)))
         #f)
       (guard (e (#t #t))                  ; index past the vertices
         (glb-write! (list (list '(position normal)
                                 (pl-vbase pb) 2 (pl-ibase pb) 3)))
         #f)
       (guard (e (#t #t))                  ; no POSITION
         (glb-write! (list (list '(normal uv)
                                 (pl-vbase pb) 3 (pl-ibase pb) 3)))
         #f)
       (guard (e (#t #t))                  ; unknown option
         (glb-write! (list (append (desc pb) (list 'colour 1))))
         #f)
       ;; one descriptor where a LIST of them belongs.  pa's layout
       ;; has five attributes, so the descriptor has the arity of a
       ;; descriptor LIST and only its shape gives it away -- without
       ;; that check this reaches memq on a symbol and traps.
       (guard (e (#t #t))
         (glb-write! (desc pa))
         #f)))

;; ---- glb-stride / glb-offset ------------------------------------
(define offset-ok
  (and (= (glb-stride '(position normal uv tangent color)) 64)
       (= (glb-stride '(position)) 12)
       (= (glb-offset wide 'position) 0)
       (= (glb-offset wide 'normal) 12)
       (= (glb-offset wide 'uv) 24)
       (= (glb-offset wide 'tangent) 32)
       (= (glb-offset wide 'color) 48)
       (not (glb-offset '(position normal) 'uv))))

;; ---- (f) the written file draws ---------------------------------
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

(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define pd (make-prim '(position normal) 4 '(0 1 2 2 1 3) #f))
(define loc-d (glb-write! (list (desc pd 'color (vector 0.0 0.0 1.0 1.0)))))
(define gd (gltf-parse (car loc-d) (cdr loc-d)))
(define mark (log-len))
(cmd-begin!)
(gltf-draw! gd lit (m4-identity))
(cmd-flush!)
(define draw-ok
  (and (= (count-from "drawElements:TRI:6:US" mark) 1)
       ;; the vertex upload is the interleave the file declared
       (= (count-from "bufferData:24" mark) 1)))

;; ---- re-export: the recipe docs/graphics.md gives -----------------
;; A parsed asset goes back out with no adapter beyond the accessors
;; (gfx gltf) already exports.  Two generations, still byte-exact.
(define loc-re
  (glb-write!
   (map (lambda (p)
          (list (gprim-layout p) (gprim-vbase p)
                (quotient (gprim-vbytes p) (gprim-stride p))
                (gprim-ibase p) (gprim-icount p)
                'color (gprim-color p)
                'index-u32? (gprim-index-u32? p)))
        (gltf-prims gm))))
(define gre (gltf-parse (car loc-re) (cdr loc-re)))
(define reexport-ok
  (and (= (length (gltf-prims gre)) 3)
       (roundtrip-ok? pa gre 0 #f)
       (roundtrip-ok? pb gre 1 #f)
       (roundtrip-ok? pc gre 2 #f)
       (equal? (gprim-color (list-ref (gltf-prims gre) 0))
               (vector 1.0 0.0 0.0 1.0))
       ;; the loader's own default colour survives the trip as data
       (equal? (gprim-color (list-ref (gltf-prims gre) 1))
               (vector 0.8 0.8 0.8 1.0))
       (header-ok? loc-re)
       (json-pad-ok? loc-re)))

;; ---- padding over reused staging --------------------------------
;; A second fx-init! rewinds the bump allocator over bytes the first
;; run left behind.  The BIN chunk's padding has to be zero because
;; the writer zeroes it, not because the page happened to be fresh --
;; otherwise one GLB's bytes depend on what ran before it.
(let dirty ((i 0))
  (when (< i 16384)
    (%mem-u8-set! (+ heap0 i) 255)
    (dirty (+ i 1))))
(fx-init! (js-get (js-global) "__mockcanvas"))

(define pz (make-prim '(position normal) 3 '(0 1 2) #f))
(define loc-z (glb-write! (list (desc pz))))
(define gz (gltf-parse (car loc-z) (cdr loc-z)))
(define reuse-ok
  (let* ((j (glb-json loc-z))
         (i-off (json-ref j "bufferViews" 1 "byteOffset"))
         (bin (glb-bin loc-z)))
    (and (< (car loc-z) (+ heap0 16384))     ; it really landed there
         (= (%mem-u8-ref (+ bin i-off 6)) 0) ; the odd index count's gap
         (= (%mem-u8-ref (+ bin i-off 7)) 0)
         (roundtrip-ok? pz gz 0 #f)
         (json-pad-ok? loc-z)
         (header-ok? loc-z))))

(and a-ok nomat-ok multi-ok view-ok u32-ok u16-ok big-ok noidx-ok
     minmax-ok stride-ok stride-refuse-ok pad-ok pad-sweep refuse-ok offset-ok draw-ok
     reexport-ok reuse-ok)
