;; expect: #t
;; (web gltf): a GLB built byte by byte in staging memory -- one red
;; translated triangle -- parses to the right geometry, color and
;; world transform, and draws through the mock GL with a single
;; upload.
(import (rnrs) (web js) (web gl) (web glsl) (web fx) (web mat)
        (web mesh) (web gltf))

;; ---- write the GLB into staging at 8192 ----
(define base 8192)
(define at 0)
(define (b! v) (%mem-u8-set! (+ base at) v) (set! at (+ at 1)))
(define (u16! v) (b! (remainder v 256)) (b! (quotient v 256)))
(define (u32! v)
  (b! (remainder v 256))
  (b! (remainder (quotient v 256) 256))
  (b! (remainder (quotient v 65536) 256))
  (b! (quotient v 16777216)))
(define (f0!) (b! 0) (b! 0) (b! 0) (b! 0))          ; 0.0f
(define (f1!) (b! 0) (b! 0) (b! 128) (b! 63))       ; 1.0f
(define (str! s)
  (string-for-each (lambda (c) (b! (char->integer c))) s))

(define json-text
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0]}],"
   "\"nodes\":[{\"mesh\":0,\"translation\":[1,2,3]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1},\"indices\":2,\"material\":0}]}],"
   "\"materials\":[{\"pbrMetallicRoughness\":"
   "{\"baseColorFactor\":[1,0,0,1]}}],"
   "\"buffers\":[{\"byteLength\":80}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":6}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}"))

(define jlen (string-length json-text))
(define jpad (remainder (- 4 (remainder jlen 4)) 4))
(define total (+ 12 8 jlen jpad 8 80))

(u32! #x46546C67)                        ; magic "glTF"
(u32! 2)
(u32! total)
(u32! (+ jlen jpad))                     ; JSON chunk
(u32! #x4E4F534A)
(str! json-text)
(let pad ((i 0)) (when (< i jpad) (b! 32) (pad (+ i 1))))
(u32! 80)                                ; BIN chunk
(u32! #x004E4942)
(f0!) (f0!) (f0!)                        ; positions: (0,0,0)
(f1!) (f0!) (f0!)                        ;            (1,0,0)
(f0!) (f1!) (f0!)                        ;            (0,1,0)
(f0!) (f0!) (f1!)                        ; normals: (0,0,1) x3
(f0!) (f0!) (f1!)
(f0!) (f0!) (f1!)
(u16! 0) (u16! 1) (u16! 2) (u16! 0)      ; indices + pad

;; ---- parse and check everything the file said ----
(define (near? a b)
  (and (fl<? (fl- a b) 0.00001) (fl<? (fl- b a) 0.00001)))

(define g (gltf-parse base total))
(define p1 (car (gltf-prims g)))
(define parse-ok
  (and (gltf? g)
       (= (length (gltf-prims g)) 1)
       (= (gprim-icount p1) 3)
       (near? (vector-ref (gprim-color p1) 0) 1.0)
       (near? (vector-ref (gprim-color p1) 1) 0.0)
       (near? (vector-ref (gprim-color p1) 3) 1.0)
       ;; the node's translation landed in the world matrix
       (near? (vector-ref (gprim-world p1) 12) 1.0)
       (near? (vector-ref (gprim-world p1) 13) 2.0)
       (near? (vector-ref (gprim-world p1) 14) 3.0)
       ;; interleaved vertices: v0 at the origin with normal +z
       (near? (%mem-f32-ref (gprim-vbase p1)) 0.0)
       (near? (%mem-f32-ref (+ (gprim-vbase p1) 12)) 0.0)
       (near? (%mem-f32-ref (+ (gprim-vbase p1) 20)) 1.0)
       ;; v1.x = 1.0
       (near? (%mem-f32-ref (+ (gprim-vbase p1) 24)) 1.0)
       ;; u16 pairs packed per word
       (= (%mem-i32-ref (gprim-ibase p1)) (+ 0 (* 65536 1)))
       (= (%mem-i32-ref (+ (gprim-ibase p1) 4)) 2)))

;; ---- a second GLB: textured triangle (TEXCOORD_0 + image) ----
(define json2
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0]}],"
   "\"nodes\":[{\"mesh\":0}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},"
   "\"indices\":3,\"material\":0}]}],"
   "\"materials\":[{\"pbrMetallicRoughness\":"
   "{\"baseColorFactor\":[1,1,1,1],\"baseColorTexture\":{\"index\":0}}}],"
   "\"textures\":[{\"source\":0}],"
   "\"images\":[{\"bufferView\":4,\"mimeType\":\"image/png\"}],"
   "\"buffers\":[{\"byteLength\":108}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24},"
   "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":104,\"byteLength\":4}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},"
   "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}"))
(define jlen2 (string-length json2))
(define jpad2 (remainder (- 4 (remainder jlen2 4)) 4))
(define total2 (+ 12 8 jlen2 jpad2 8 108))
(set! base 10240)
(set! at 0)
(u32! #x46546C67)
(u32! 2)
(u32! total2)
(u32! (+ jlen2 jpad2))
(u32! #x4E4F534A)
(str! json2)
(let pad ((i 0)) (when (< i jpad2) (b! 32) (pad (+ i 1))))
(u32! 108)
(u32! #x004E4942)
(f0!) (f0!) (f0!)                        ; positions
(f1!) (f0!) (f0!)
(f0!) (f1!) (f0!)
(f0!) (f0!) (f1!)                        ; normals
(f0!) (f0!) (f1!)
(f0!) (f0!) (f1!)
(f0!) (f0!)                              ; uvs: (0 0) (1 0) (0 1)
(f1!) (f0!)
(f0!) (f1!)
(u16! 0) (u16! 1) (u16! 2) (u16! 0)      ; indices + pad -> offset 104
(str! "PNG!")                            ; the "image" bytes

(define g2 (gltf-parse 10240 total2))
(define p2 (car (gltf-prims g2)))
(define tex-parse-ok
  (and (= (gprim-stride p2) 32)
       (= (gprim-vbytes p2) 96)
       (near? (%mem-f32-ref (+ (gprim-vbase p2) 24)) 0.0)   ; v0 u
       (near? (%mem-f32-ref (+ (gprim-vbase p2) 32 24)) 1.0); v1 u
       (not (gprim-tex p2))              ; nothing decoded yet
       (= (vector-length (gltf-images g2)) 1)
       (let ((info (vector-ref (gltf-images g2) 0)))
         (and (= (cadr info) 4)
              (string=? (caddr info) "image/png")
              (= (%mem-u8-ref (car info)) 80)))))   ; 'P'

;; ---- draw through the recording mock: one upload, then reuse ----
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, texImage2D(...a){ const d = a[a.length-1]; push('texImage', d ? d.id : 'null') }, activeTexture(u){ push('activeTexture', u) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[12].toFixed(2), arr[13].toFixed(2)) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define gllog (js-get (js-global) "__gllog"))
(define (entry i) (js->string (js-index gllog i)))
(define (log-len) (js->number (js-get gllog "length")))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-log p)
  (let ((n (log-len)))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1) (if (prefix? p (entry i)) (+ c 1) c))))))

(fx-init! (js-get (js-global) "__mockcanvas"))
(define prog (fx-program! mesh-lit-vs mesh-lit-fs))
(cmd-begin!)
(gltf-draw! g prog (m4-identity))
(cmd-flush!)
(define draw-ok
  (and (= (count-log "bufferData:18") 1)   ; 3 verts x 6 f32
       (= (count-log "bufferData:4") 1)    ; 4 u16 (3 + pad)
       (= (count-log "uniformMat4:U:u_model:16:1.00:2.00") 1)
       (= (count-log "uniform4f:U:u_color:1.0,0.0,0.0,1.0") 1)
       (= (count-log "drawElements:TRI:3:US") 1)))
(cmd-begin!)
(gltf-draw! g prog (m4-identity))
(cmd-flush!)
(define reuse-ok
  (and (= (count-log "bufferData") 2)      ; still the first frame's two
       (= (count-log "drawElements:TRI:3:US") 2)))

;; ---- a third GLB: two bones and a rotation channel ----
(define json3
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0,1]}],"
   "\"nodes\":[{\"mesh\":0,\"skin\":0},"
   "{\"children\":[2]},"
   "{\"translation\":[0,1,0]}],"
   "\"skins\":[{\"joints\":[1,2],\"inverseBindMatrices\":5}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1,\"JOINTS_0\":2,\"WEIGHTS_0\":3},"
   "\"indices\":4}]}],"
   "\"animations\":[{\"name\":\"spin\","
   "\"channels\":[{\"sampler\":0,"
   "\"target\":{\"node\":2,\"path\":\"rotation\"}}],"
   "\"samplers\":[{\"input\":6,\"output\":7,"
   "\"interpolation\":\"LINEAR\"}]}],"
   "\"buffers\":[{\"byteLength\":308}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":12},"
   "{\"buffer\":0,\"byteOffset\":84,\"byteLength\":48},"
   "{\"buffer\":0,\"byteOffset\":132,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":140,\"byteLength\":128},"
   "{\"buffer\":0,\"byteOffset\":268,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":276,\"byteLength\":32}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":3,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
   "{\"bufferView\":4,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":2,\"type\":\"MAT4\"},"
   "{\"bufferView\":6,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":7,\"componentType\":5126,\"count\":2,\"type\":\"VEC4\"}]}"))
(define jlen3 (string-length json3))
(define jpad3 (remainder (- 4 (remainder jlen3 4)) 4))
(define total3 (+ 12 8 jlen3 jpad3 8 308))
(define (fq!) (b! 243) (b! 4) (b! 53) (b! 63))      ; 0.70710678f
(define (ident16!)
  (let m ((i 0))
    (when (< i 16)
      (if (or (= i 0) (= i 5) (= i 10) (= i 15)) (f1!) (f0!))
      (m (+ i 1)))))
(set! base 12288)
(set! at 0)
(u32! #x46546C67)
(u32! 2)
(u32! total3)
(u32! (+ jlen3 jpad3))
(u32! #x4E4F534A)
(str! json3)
(let pad ((i 0)) (when (< i jpad3) (b! 32) (pad (+ i 1))))
(u32! 308)
(u32! #x004E4942)
(f0!) (f0!) (f0!)                        ; positions
(f1!) (f0!) (f0!)
(f0!) (f1!) (f0!)
(f0!) (f0!) (f1!)                        ; normals
(f0!) (f0!) (f1!)
(f0!) (f0!) (f1!)
(b! 1) (b! 0) (b! 0) (b! 0)              ; joints u8: all on joint 1
(b! 1) (b! 0) (b! 0) (b! 0)
(b! 1) (b! 0) (b! 0) (b! 0)
(f1!) (f0!) (f0!) (f0!)                  ; weights: 1 0 0 0
(f1!) (f0!) (f0!) (f0!)
(f1!) (f0!) (f0!) (f0!)
(u16! 0) (u16! 1) (u16! 2) (u16! 0)      ; indices + pad -> 140
(ident16!) (ident16!)                    ; inverse binds: identity
(f0!) (f1!)                              ; keyframe times 0, 1
(f0!) (f0!) (f0!) (f1!)                  ; quat identity
(f0!) (f0!) (fq!) (fq!)                  ; quat: 90 deg about z

(define g3 (gltf-parse 12288 total3))
(define p3 (car (gltf-prims g3)))
(define (m4at ms k i) (vector-ref (vector-ref ms k) i))
(define skin-parse-ok
  (and (= (gprim-stride p3) 64)
       (= (gprim-vbytes p3) 192)
       (near? (%mem-f32-ref (+ (gprim-vbase p3) 32)) 1.0)   ; joint idx
       (near? (%mem-f32-ref (+ (gprim-vbase p3) 48)) 1.0)   ; weight
       (equal? (gltf-animation-names g3) '("spin"))))
;; the rest pose: joint 1 is translated up by its node
(gltf-animate! g3 0 0.0)
(define jm0 (gltf-joint-matrices g3 0))
(define pose0-ok
  (and (= (vector-length jm0) 2)
       (near? (m4at jm0 0 0) 1.0)        ; root: identity
       (near? (m4at jm0 0 13) 0.0)
       (near? (m4at jm0 1 0) 1.0)        ; child: T(0,1,0)
       (near? (m4at jm0 1 13) 1.0)))
;; approaching t=1 the child has turned 90 degrees about z
;; (t = duration itself wraps to the loop start)
(gltf-animate! g3 0 0.9999)
(define jm1 (gltf-joint-matrices g3 0))
(define pose1-ok
  (and (< (abs (- (m4at jm1 1 0) 0.0)) 0.001)
       (< (abs (- (m4at jm1 1 1) 1.0)) 0.001)
       (near? (m4at jm1 1 13) 1.0)))
;; halfway: 45 degrees (nlerp = slerp at the midpoint); and looping
(gltf-animate! g3 0 0.5)
(define jm-half (gltf-joint-matrices g3 0))
(gltf-animate! g3 0 2.0)                 ; wraps to t=0
(define jm-wrap (gltf-joint-matrices g3 0))
(define pose-mid-ok
  (and (< (abs (- (m4at jm-half 1 0) 0.7071)) 0.001)
       (near? (m4at jm-wrap 1 0) 1.0)))
;; draw through the skin shader: one joint-array upload per prim
(define sprog (fx-program! gltf-skin-vs mesh-tex-fs))
(cmd-begin!)
(gltf-draw! g3 sprog (m4-identity))
(cmd-flush!)
(define skin-draw-ok
  (and (= (count-log "uniformMat4:U:u_joints:32") 1)   ; 2 mats x 16
       (= (count-log "attrib:3,4,F,false,64,32") 1)
       (= (count-log "attrib:4,4,F,false,64,48") 1)
       (= (count-log "bufferData:48") 1)))             ; 3 verts x 16 f32

;; ---- decode the image (sync-thenable mocks) and draw textured ----
(js-eval "globalThis.__syncThen = (v) => ({ then(f) { const r = f(v); return (r && r.then) ? r : globalThis.__syncThen(r); } }); globalThis.Blob = function(parts, opts) { this.mime = opts.type; this.len = parts[0].length; }; globalThis.createImageBitmap = (b) => globalThis.__syncThen({ id: 'BMP', mime: b.mime, len: b.len })")
(define loaded #f)
(gltf-load-textures! g2 (lambda (g) (set! loaded #t)))
(define tex-load-ok
  (and loaded
       (number? (gprim-tex p2))
       (= (count-log "texImage:BMP") 1)))

(define tprog (fx-program! mesh-tex-vs mesh-tex-fs))
(cmd-begin!)
(gltf-draw! g2 tprog (m4-identity))
(cmd-flush!)
(define tex-draw-ok
  (and (= (count-log "bufferData:24") 1)      ; 3 verts x 8 f32
       (= (count-log "attrib:2,2,F,false,32,24") 1)
       (= (count-log "uniform1i:U:u_tex:0") 1)
       (= (count-log "drawElements:TRI:3:US") 4)))

;; the guard rail: a 24-byte program cannot draw a 32-byte primitive
(define mismatch-ok
  (guard (e (#t #t))
    (gltf-draw! g2 prog (m4-identity))
    #f))

(and parse-ok tex-parse-ok skin-parse-ok pose0-ok pose1-ok pose-mid-ok
     skin-draw-ok draw-ok reuse-ok tex-load-ok tex-draw-ok mismatch-ok)
