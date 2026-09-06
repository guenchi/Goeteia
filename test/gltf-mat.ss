;; expect: #t
;; The material model past a base colour: texture REFERENCES rather
;; than image indices.  A reference names the glTF texture (so the
;; textures[] and samplers[] arrays can be handed back to a writer
;; intact), the image it resolves to, its sampler, the UV set it
;; reads and its scalar (normalTexture.scale / occlusionTexture.
;; strength).  The file also carries a second UV set, a camera and
;; morph targets with NORMAL deltas, so the reader keeps what a
;; re-export needs.
;;
;; The image bytes are fake; the decode path is mocked the way
;; test/gltf.ss mocks it.  Every number asserted below was written
;; into the JSON by hand a few lines above it.
;;
;; Copyright (c) 2026 guenchi.  MIT license; see LICENSE.
(import (rnrs) (gfx gl) (gfx fx) (gfx mat) (gfx gltf) (gfx glb) (web js))

(define base (fx-alloc! 8192))
(define at 0)
(define (b! v) (%mem-u8-set! (+ base at) v) (set! at (+ at 1)))
(define (u16! v) (b! (remainder v 256)) (b! (quotient v 256)))
(define (u32! v)
  (u16! (remainder v 65536)) (u16! (quotient v 65536)))
(define (f32! v) (%mem-f32-set! (+ base at) v) (set! at (+ at 4)))
(define (v3! x y z) (f32! x) (f32! y) (f32! z))
(define (str! s)
  (let ((bv (string->utf8 s)))
    (let loop ((i 0))
      (when (< i (bytevector-length bv)) (b! (bytevector-u8-ref bv i)) (loop (+ i 1))))))

;; ---- BIN layout ----
;; 0   pos 36 | 36 nrm 36 | 72 uv0 24 | 96 uv1 24 | 120 tan 48 | 168 idx 6+2
;; 176 dpos 36 | 212 dnrm 36 | 248 dtan 36 | 284 img 4
(define binlen 288)

(define (json-for roots)
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[" roots "]}],"
   "\"nodes\":[{\"mesh\":0},{\"mesh\":1},{\"mesh\":2},{\"camera\":0,\"name\":\"eye\"}],"
   "\"cameras\":[{\"type\":\"perspective\",\"perspective\":{\"yfov\":0.8,\"znear\":0.1}}],"
   "\"meshes\":["
   ;; A: both UV sets, normals and tangents, a material with every slot,
   ;; two morph targets: one with every delta, one with NORMAL alone
   "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2,\"TEXCOORD_1\":3,\"TANGENT\":4},"
   "\"indices\":5,\"material\":0,\"targets\":[{\"POSITION\":6,\"NORMAL\":7,\"TANGENT\":8},{\"NORMAL\":7}]}],\"weights\":[0.5,0.25]},"
   ;; B: TEXCOORD_1 without TEXCOORD_0 -- the uv slot is still padded in
   "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"TEXCOORD_1\":3},\"indices\":5}]},"
   ;; C: TEXCOORD_0 only, no material -- the layout every older asset has
   "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"TEXCOORD_0\":2},\"indices\":5}]}],"
   "\"materials\":[{"
   "\"pbrMetallicRoughness\":{\"baseColorFactor\":[1,1,1,1],"
   "\"baseColorTexture\":{\"index\":0},"
   "\"metallicRoughnessTexture\":{\"index\":1}},"
   "\"normalTexture\":{\"index\":2,\"scale\":0.6},"
   "\"emissiveTexture\":{\"index\":3},"
   "\"occlusionTexture\":{\"index\":4,\"strength\":0.8,\"texCoord\":1}}],"
   ;; five textures over ONE image: sampler 0, sampler 1, NO sampler,
   ;; the EMPTY sampler, and a duplicate of the second pair
   "\"textures\":[{\"source\":0,\"sampler\":0},{\"source\":0,\"sampler\":1},{\"source\":0},"
   "{\"source\":0,\"sampler\":2},{\"source\":0,\"sampler\":1}],"
   "\"samplers\":[{\"magFilter\":9729,\"minFilter\":9987,\"wrapS\":10497,\"wrapT\":10497},"
   "{\"magFilter\":9728,\"minFilter\":9728,\"wrapS\":33071,\"wrapT\":33071},{}],"
   "\"images\":[{\"bufferView\":9,\"mimeType\":\"image/png\"}],"
   "\"buffers\":[{\"byteLength\":288}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":120,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":168,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":176,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":212,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":248,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":284,\"byteLength\":4}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},"
   "{\"bufferView\":3,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":5,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":7,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":8,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]}"))

(define (write-bin!)
(v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)   ; pos
(v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0)   ; nrm
(f32! 0.0) (f32! 0.0) (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 1.0)   ; uv0
(f32! 0.5) (f32! 0.5) (f32! 0.25) (f32! 0.75) (f32! 0.125) (f32! 0.875)   ; uv1
(let t ((i 0)) (when (< i 3) (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 1.0) (t (+ i 1))))   ; tan
(u16! 0) (u16! 1) (u16! 2) (u16! 0)                     ; idx + pad
(v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0) (v3! 0.0 0.0 1.0)   ; dpos
(v3! 0.1 0.2 0.3) (v3! 0.1 0.2 0.3) (v3! 0.1 0.2 0.3)   ; dnrm
(v3! 0.4 0.5 0.6) (v3! 0.4 0.5 0.6) (v3! 0.4 0.5 0.6)   ; dtan
(u32! #xFFFFFFFF))                                      ; fake image
;; a whole GLB into staging: header, JSON, BIN; -> (base . total)
(define (write-glb! json-text)
  (let* ((jlen (string-length json-text))
         (jpad (remainder (- 4 (remainder jlen 4)) 4))
         (total (+ 12 8 jlen jpad 8 binlen))
         (start at))
    (u32! #x46546C67) (u32! 2) (u32! total)
    (u32! (+ jlen jpad)) (u32! #x4E4F534A)
    (str! json-text)
    (let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
    (u32! binlen) (u32! #x004E4942)
    (write-bin!)
    (cons (+ base start) total)))
(define loc (write-glb! (json-for "0,1,2,3")))
(define loc-a (write-glb! (json-for "0,3")))   ; mesh A alone, for the draw below

(define (near? a b) (< (abs (- a b)) 1e-6))
(define (f32@ p off) (%mem-f32-ref (+ (gprim-vbase p) off)))

(define g (gltf-parse (car loc) (cdr loc)))
(define pa (car (gltf-prims g)))
(define pb (cadr (gltf-prims g)))
(define pc (caddr (gltf-prims g)))

;; ---- the sampler and texture tables come through verbatim ----
(define samplers-ok
  (let ((ss (gltf-samplers g)))
    (and (= (vector-length ss) 3)
         ;; the empty sampler: filters unknown, wraps at the spec default
         (not (gsampler-mag (vector-ref ss 2)))
         (not (gsampler-min (vector-ref ss 2)))
         (= (gsampler-wrap-s (vector-ref ss 2)) 10497)
         (= (gsampler-wrap-t (vector-ref ss 2)) 10497)
         (= (gsampler-mag (vector-ref ss 0)) 9729)
         (= (gsampler-min (vector-ref ss 0)) 9987)
         (= (gsampler-wrap-s (vector-ref ss 0)) 10497)
         (= (gsampler-wrap-t (vector-ref ss 0)) 10497)
         (= (gsampler-mag (vector-ref ss 1)) 9728)
         (= (gsampler-min (vector-ref ss 1)) 9728)
         (= (gsampler-wrap-s (vector-ref ss 1)) 33071)
         (= (gsampler-wrap-t (vector-ref ss 1)) 33071))))

(define textures-ok
  (equal? (gltf-textures g) '#((0 . 0) (0 . 1) (0 . #f) (0 . 2) (0 . 1))))

;; ---- five references, each naming texture / image / sampler / uv set / scalar ----
(define (ref-is? r tex img smp uv factor)
  (and r
       (= (gtexref-texture r) tex)
       (= (gtexref-image r) img)
       (eqv? (gtexref-sampler r) smp)
       (= (gtexref-texcoord r) uv)
       (near? (gtexref-factor r) factor)))

(define refs-ok
  (and (ref-is? (gprim-base-tex pa) 0 0 0 0 1.0)
       (ref-is? (gprim-mr-tex pa) 1 0 1 0 1.0)
       (ref-is? (gprim-normal-tex pa) 2 0 #f 0 0.6)
       (ref-is? (gprim-emissive-tex pa) 3 0 2 0 1.0)
       (ref-is? (gprim-occlusion-tex pa) 4 0 1 1 0.8)))

;; the older image-index accessors are projections of the references
(define legacy-ok
  (and (= (gprim-normal-img pa) 0)
       (= (gprim-emissive-img pa) 0)
       (= (gprim-occlusion-img pa) 0)
       (not (gprim-base-tex pc)) (not (gprim-mr-tex pc))
       (not (gprim-normal-tex pc)) (not (gprim-normal-img pc))))

;; ---- the second UV set rides at the end of the interleave ----
(define uv1-ok
  (and (equal? (gprim-layout pa) '(position normal uv tangent uv1))
       (= (gprim-stride pa) 56)
       (= (glb-offset '(position normal uv tangent uv1) 'uv1) 48)
       (= (glb-offset '(position normal uv uv1) 'uv1) 32)
       (near? (f32@ pa 24) 0.0)         ; uv0 v0
       (near? (f32@ pa 32) 1.0)         ; tangent v0
       (near? (f32@ pa 48) 0.5)         ; uv1 v0
       (near? (f32@ pa 52) 0.5)
       (near? (f32@ pa (+ 56 48)) 0.25) ; uv1 v1
       (near? (f32@ pa (+ 56 52)) 0.75)))

;; TEXCOORD_1 alone: the uv slot is still there, zeroed, so the
;; "anything past normal carries uv" contract holds
(define uv1-only-ok
  (and (equal? (gprim-layout pb) '(position normal uv uv1))
       (= (gprim-stride pb) 40)
       (near? (f32@ pb 24) 0.0) (near? (f32@ pb 28) 0.0)
       (near? (f32@ pb 32) 0.5) (near? (f32@ pb 36) 0.5)))

;; the layout every older asset has is untouched
(define uv0-ok
  (and (equal? (gprim-layout pc) '(position normal uv))
       (= (gprim-stride pc) 32)))

;; ---- cameras and the node that carries one ----
(define camera-ok
  (let ((cs (gltf-cameras g)))
    (and (= (vector-length cs) 1)
         (eq? (vector-ref (vector-ref cs 0) 0) 'perspective)
         (near? (vector-ref (vector-ref cs 0) 1) 0.8)   ; yfov
         (not (vector-ref (vector-ref cs 0) 2))         ; aspect omitted
         (near? (vector-ref (vector-ref cs 0) 3) 0.1)   ; znear
         (not (vector-ref (vector-ref cs 0) 4))         ; zfar omitted
         (= (gltf-node-camera g 3) 0)
         (not (gltf-node-camera g 0)))))

;; ---- morph NORMAL deltas are kept alongside the POSITION deltas ----
(define morph-ok
  (let ((mo (gprim-morph pa)))
    (and mo
         (= (vector-length (vector-ref mo 1)) 2)              ; two targets
         (near? (vector-ref (vector-ref mo 2) 0) 0.5)         ; weights as written
         (near? (vector-ref (vector-ref mo 2) 1) 0.25)
         (near? (vector-ref (vector-ref (vector-ref mo 1) 0) 2) 1.0)   ; target 0 moves +z
         (near? (vector-ref (vector-ref (vector-ref mo 1) 1) 2) 0.0)   ; target 1 has no POSITION: zero delta
         (let ((dn (gprim-morph-normals pa)))
           (and dn (= (vector-length dn) 2)
                (let ((d (vector-ref dn 0)))
                  (and (= (vector-length d) 9)
                       (near? (vector-ref d 0) 0.1) (near? (vector-ref d 1) 0.2) (near? (vector-ref d 8) 0.3)))
                (near? (vector-ref (vector-ref dn 1) 4) 0.2)))    ; the NORMAL-only target keeps its normals
         (let ((dt (gprim-morph-tangents pa)))
           (and dt (= (vector-length dt) 2)
                (near? (vector-ref (vector-ref dt 0) 3) 0.4)
                (not (vector-ref dt 1))))                          ; no TANGENT in target 1: a hole
         (not (gprim-morph-normals pc))
         (not (gprim-morph-tangents pc)))))

;; ---- GL textures: one per (image . sampler) pair, sampler state applied ----
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:64, height:64, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { TEXTURE0:33984, TEXTURE_2D:3553, TEXTURE_MIN_FILTER:10241, TEXTURE_MAG_FILTER:10240, TEXTURE_WRAP_S:10242, TEXTURE_WRAP_T:10243, LINEAR:9729, NEAREST:9728, LINEAR_MIPMAP_LINEAR:9987, CLAMP_TO_EDGE:33071, REPEAT:10497, RGBA:6408, UNSIGNED_BYTE:5121, VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, generateMipmap(t){ push('genMip', t) }, texImage2D(...a){ const d = a[a.length-1]; push('texImage', d ? d.id : 'null') }, activeTexture(u){ push('activeTexture', u) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){}, bindBuffer(t,b){}, bufferData(t,arr,u){}, enableVertexAttribArray(l){}, vertexAttribPointer(...a){}, uniform1f(){}, uniform3f(){}, uniform4f(){}, uniformMatrix4fv(){}, drawElements(){}, viewport(){}, enable(){}, clearColor(){}, clear(){} } } }; globalThis.__syncThen = (v) => ({ then(f) { const r = f(v); return (r && r.then) ? r : globalThis.__syncThen(r); } }); globalThis.Blob = function(parts, opts) { this.mime = opts.type; this.len = parts[0].length; }; globalThis.createImageBitmap = (b) => globalThis.__syncThen({ id: 'BMP', mime: b.mime, len: b.len })")
(fx-init! (js-get (js-global) "__mockcanvas"))
(define (count-log s)
  (let* ((log (js-get (js-global) "__gllog"))
         (n (js->number (js-get log "length"))))
    (let loop ((i 0) (c 0))
      (if (= i n) c
          (loop (+ i 1)
                (if (string=? (js->string (js-index log i)) s) (+ c 1) c))))))
(define loaded #f)
(gltf-load-textures! g (lambda (g) (set! loaded #t)))
;; the log, folded per texture object: every texParam is attributed to
;; the texture bound just before it, so sampler state can be checked
;; on the OBJECT it was meant for, not counted globally
(define (params-by-texture)
  (let* ((log (js-get (js-global) "__gllog"))
         (n (js->number (js-get log "length"))))
    (let loop ((i 0) (cur #f) (acc '()))
      (if (= i n) acc
          (let ((e (js->string (js-index log i))))
            (cond ((and (> (string-length e) 12) (string=? (substring e 0 12) "bindTexture:"))
                   (loop (+ i 1) (substring e 12 (string-length e)) acc))
                  ((and cur (> (string-length e) 9) (string=? (substring e 0 9) "texParam:"))
                   (let ((cell (assoc cur acc)))
                     (if cell
                         (begin (set-cdr! cell (cons (substring e 9 (string-length e)) (cdr cell))) (loop (+ i 1) cur acc))
                         (loop (+ i 1) cur (cons (list cur (substring e 9 (string-length e))) acc)))))
                  (else (loop (+ i 1) cur acc))))))))
(define creation '("10241:9987" "10240:9729" "10242:33071" "10243:33071"))   ; what texture() sets
(define (has-all? ps wants) (let loop ((w wants)) (or (null? w) (and (member (car w) ps) (loop (cdr w))))))
(define (objects-with pred) (length (filter (lambda (c) (pred (cdr c))) (params-by-texture))))
(define gl-ok
  (and loaded
       (= (count-log "texImage:BMP") 4)        ; four distinct (image . sampler) pairs; the duplicate shares
       ;; sampler 1 landed on exactly one object, as NEAREST + CLAMP
       (= 1 (objects-with (lambda (ps) (and (has-all? ps '("10240:9728" "10241:9728" "10242:33071" "10243:33071"))
                                            (= (length ps) 8)))))
       ;; sampler 0 landed on exactly one object, LINEAR/mipmap + REPEAT
       (= 1 (objects-with (lambda (ps) (and (has-all? ps '("10240:9729" "10241:9987" "10242:10497" "10243:10497"))
                                            (= (length ps) 8)))))
       ;; the EMPTY sampler: wraps at the spec default, filters left alone
       (= 1 (objects-with (lambda (ps) (and (has-all? ps '("10242:10497" "10243:10497"))
                                            (not (member "10240:9728" ps))
                                            (= (length ps) 6)))))
       ;; no sampler at all: the creation parameters and nothing else --
       ;; the fallbacks look the same, so this is "at least one"
       (>= (objects-with (lambda (ps) (and (has-all? ps creation) (= (length ps) 4)))) 1)
       (number? (gprim-mrtex pa))                    ; the fifth GL slot is filled
       (not (= (gprim-tex pa) (gprim-mrtex pa)))     ; and is not the base texture
       (= (gprim-otex pa) (gprim-mrtex pa))))        ; the duplicate pair shares its object

;; ---- the sampler state sits on the object each SLOT binds ----
;; A draw binds base/normal/emissive/occlusion to units 0..3 whenever
;; the program declares their samplers; the texture object bound to
;; each unit is read off the log, and its parameter history must be
;; the one its slot's sampler prescribes.  Counting histories across
;; all objects (above) cannot tell a swap; this can.
(define slot-vs
  '((attribute vec3 a_pos) (attribute vec3 a_normal) (attribute vec2 a_uv)
    (attribute vec4 a_tangent) (attribute vec2 a_uv1)
    (uniform mat4 u_mvp) (varying vec2 v_uv)
    (define (main) void (set! gl_Position (* u_mvp (vec4 a_pos (fl 1)))) (set! v_uv a_uv))))
(define slot-fs
  '((precision mediump float)
    (uniform sampler2D u_tex) (uniform sampler2D u_nmap) (uniform sampler2D u_emap) (uniform sampler2D u_omap)
    (varying vec2 v_uv)
    (define (main) void
      (set! gl_FragColor (+ (+ (texture2D u_tex v_uv) (texture2D u_nmap v_uv))
                            (+ (texture2D u_emap v_uv) (texture2D u_omap v_uv)))))))
(define slot-prog (fx-program! slot-vs slot-fs))
(define ga (gltf-parse (car loc-a) (cdr loc-a)))   ; mesh A alone: one layout, one program
(define loaded-a #f)
(gltf-load-textures! ga (lambda (g) (set! loaded-a #t)))
(define draw-from (js->number (js-get (js-get (js-global) "__gllog") "length")))
(cmd-begin!)
(gltf-draw! ga slot-prog (m4-identity))
(cmd-flush!)
;; the object bound to a unit: the bindTexture right after activeTexture:<TEXTURE0+unit>
(define (bound-to unit)
  (let* ((log (js-get (js-global) "__gllog")) (n (js->number (js-get log "length")))
         (want (string-append "activeTexture:" (number->string (+ 33984 unit)))))
    (let loop ((i draw-from))
      (cond ((>= (+ i 1) n) #f)
            ((string=? (js->string (js-index log i)) want)
             (let ((e (js->string (js-index log (+ i 1)))))
               (and (> (string-length e) 12) (string=? (substring e 0 12) "bindTexture:")
                    (substring e 12 (string-length e)))))
            (else (loop (+ i 1)))))))
(define (params-of id) (let ((c (assoc id (params-by-texture)))) (if c (cdr c) '())))
(define (exactly? ps wants) (and (= (length ps) (length wants)) (has-all? ps wants)))
(define slots-ok
  (let ((base (bound-to 0)) (nrm (bound-to 1)) (emi (bound-to 2)) (occ (bound-to 3)))
    (and loaded-a base nrm emi occ
         (exactly? (params-of base) (append creation '("10240:9729" "10241:9987" "10242:10497" "10243:10497")))  ; sampler 0
         (exactly? (params-of nrm) creation)                                                                 ; no sampler: creation only
         (exactly? (params-of emi) (append creation '("10242:10497" "10243:10497")))                          ; {}: wraps only
         (exactly? (params-of occ) (append creation '("10240:9728" "10241:9728" "10242:33071" "10243:33071")))  ; sampler 1
         (not (string=? base occ)) (not (string=? nrm emi)))))

(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)
(let ((all (list (report "samplers" samplers-ok) (report "textures" textures-ok)
                 (report "refs" refs-ok) (report "legacy" legacy-ok)
                 (report "uv1" uv1-ok) (report "uv1-only" uv1-only-ok) (report "uv0" uv0-ok)
                 (report "camera" camera-ok) (report "morph" morph-ok) (report "gl" gl-ok)
                 (report "slots" slots-ok))))
  (let loop ((l all)) (or (null? l) (and (car l) (loop (cdr l))))))
