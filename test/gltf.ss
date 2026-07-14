;; expect: #t
;; (gfx gltf): a GLB built byte by byte in staging memory -- one red
;; translated triangle -- parses to the right geometry, color and
;; world transform, and draws through the mock GL with a single
;; upload.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf))

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
   "{\"baseColorFactor\":[1,0,0,1],"
   "\"metallicFactor\":0.25,\"roughnessFactor\":0.5}}],"
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
       ;; the metallic-roughness factors ride along
       (near? (gprim-metallic p1) 0.25)
       (near? (gprim-roughness p1) 0.5)
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
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, generateMipmap(t){ push('genMip', t) }, texImage2D(...a){ const d = a[a.length-1]; push('texImage', d ? d.id : 'null') }, activeTexture(u){ push('activeTexture', u) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[12].toFixed(2), arr[13].toFixed(2)) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

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
;; crossfade: half rest pose, half the 90-degree pose is 45 degrees
(gltf-animate-blend! g3 0 0.0 0 0.9999 0.5)
(define jm-blend (gltf-joint-matrices g3 0))
(gltf-animate-blend! g3 0 0.0 0 0.9999 0.0)  ; k=0: all ai
(define jm-b0 (gltf-joint-matrices g3 0))
(gltf-animate-blend! g3 0 0.0 0 0.9999 1.0)  ; k=1: all aj
(define jm-b1 (gltf-joint-matrices g3 0))
(define blend-ok
  (and (< (abs (- (m4at jm-blend 1 0) 0.7071)) 0.002)
       (< (abs (- (m4at jm-blend 1 1) 0.7071)) 0.002)
       (near? (m4at jm-b0 1 0) 1.0)
       (< (abs (- (m4at jm-b1 1 0) 0.0)) 0.001)))
;; the resident palette holds the same matrices, f32 for f32
(define (m4s~ at m)
  (let loop ((i 0))
    (or (= i 16)
        (and (< (abs (- (%mem-f32-ref (+ at (* 4 i)))
                        (vector-ref m i)))
                0.001)
             (loop (+ i 1))))))
(gltf-animate! g3 0 0.5)
(define jm-box (gltf-joint-matrices g3 0))
(define pal-at (gltf-joint-palette! g3 0))
(define pal-ok
  (and (= (gltf-joint-count g3 0) 2)
       (m4s~ pal-at (vector-ref jm-box 0))
       (m4s~ (+ pal-at 64) (vector-ref jm-box 1))))

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

;; ---- fixture 4: morph targets -- a triangle that opens ----
(define json-text4
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0]}],"
   "\"nodes\":[{\"mesh\":0}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1},\"indices\":2,"
   "\"targets\":[{\"POSITION\":3}]}],\"weights\":[0.25]}],"
   "\"animations\":[{\"name\":\"open\",\"channels\":"
   "[{\"sampler\":0,\"target\":{\"node\":0,\"path\":\"weights\"}}],"
   "\"samplers\":[{\"input\":4,\"output\":5,"
   "\"interpolation\":\"LINEAR\"}]}],"
   "\"buffers\":[{\"byteLength\":132}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":6},"
   "{\"buffer\":0,\"byteOffset\":80,\"byteLength\":36},"
   "{\"buffer\":0,\"byteOffset\":116,\"byteLength\":8},"
   "{\"buffer\":0,\"byteOffset\":124,\"byteLength\":8}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
   "{\"bufferView\":3,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":4,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
   "{\"bufferView\":5,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"}]}"))
(define jlen4 (string-length json-text4))
(define jpad4 (remainder (- 4 (remainder jlen4 4)) 4))
(define total4 (+ 12 8 jlen4 jpad4 8 132))
(set! base 14336)
(set! at 0)
(u32! #x46546C67) (u32! 2) (u32! total4)
(u32! (+ jlen4 jpad4)) (u32! #x4E4F534A)
(str! json-text4)
(let pad ((i 0)) (when (< i jpad4) (b! 32) (pad (+ i 1))))
(u32! 132) (u32! #x004E4942)
(f0!) (f0!) (f0!)                        ; positions
(f1!) (f0!) (f0!)
(f0!) (f1!) (f0!)
(f0!) (f0!) (f1!)                        ; normals x3
(f0!) (f0!) (f1!)
(f0!) (f0!) (f1!)
(u16! 0) (u16! 1) (u16! 2) (u16! 0)      ; indices + pad
(f1!) (f0!) (f0!)                        ; target: v0 moves +x
(f0!) (f0!) (f0!)
(f0!) (f0!) (f0!)
(f0!) (f1!)                              ; times 0 1
(f0!) (f1!)                              ; weight values 0 1

(define g4 (gltf-parse 14336 total4))
(define p4 (car (gltf-prims g4)))
(define morph-parse-ok
  (and (gprim-morph p4)
       (near? (vector-ref (vector-ref (gprim-morph p4) 2) 0) 0.25)
       (equal? (gltf-animation-names g4) '("open"))))
;; the first draw applies the mesh's initial weights: v0.x = 0.25
(define mprog (fx-program! mesh-lit-vs mesh-lit-fs))
(cmd-begin!)
(gltf-draw! g4 mprog (m4-identity))
(cmd-flush!)
(define morph0-ok (near? (%mem-f32-ref (gprim-vbase p4)) 0.25))
;; the weights animation drives it: t = 0.5 -> 0.5
(gltf-animate! g4 0 0.5)
(cmd-begin!) (gltf-draw! g4 mprog (m4-identity)) (cmd-flush!)
(define morph-anim-ok (near? (%mem-f32-ref (gprim-vbase p4)) 0.5))
;; and by hand; the other components and vertices stay put
(gltf-weights! p4 '(1.0))
(cmd-begin!) (gltf-draw! g4 mprog (m4-identity)) (cmd-flush!)
(define morph-hand-ok
  (and (near? (%mem-f32-ref (gprim-vbase p4)) 1.0)
       (near? (%mem-f32-ref (+ (gprim-vbase p4) 4)) 0.0)
       (near? (%mem-f32-ref (+ (gprim-vbase p4) 24)) 1.0)))

;; ---- the animation state machine, over the spin clip ----
;; two states on the same clip still exercise the bookkeeping: each
;; state runs its own clock, and the fade blends the two samples
(define am (anim-machine g3 '((a . 0) (b . 0)) 1.0))
(anim-update! am 0.75)                   ; a's clock at 0.75 of 0..90:
(define am-jm1 (gltf-joint-matrices g3 0)); nlerp puts m00 at 0.36811
(define am-run-ok
  (and (anim-machine? am)
       (eq? (anim-state am) 'a)
       (< (abs (- (m4at am-jm1 1 0) 0.36811)) 0.002)))
;; a quarter into the fade: a has wrapped to 0 deg, b's own nlerp
;; sits near 22 deg, and the blend leans a quarter toward b
(anim-goto! am 'b)
(anim-update! am 0.25)
(define am-jm2 (gltf-joint-matrices g3 0))
(define am-fade-ok
  (and (eq? (anim-state am) 'b)
       (< (abs (- (m4at am-jm2 1 0) 0.99558)) 0.003)))
;; this update completes the fade exactly: pure b, wrapped to 0 deg
(anim-update! am 0.75)
(define am-jm3 (gltf-joint-matrices g3 0))
(define am-done-ok (< (abs (- (m4at am-jm3 1 0) 1.0)) 0.001))
;; a goto with its own fade of 0: the switch is instant
(anim-goto! am 'a 0.0)
(anim-update! am 0.5)
(define am-jm4 (gltf-joint-matrices g3 0))
(define am-instant-ok
  (and (eq? (anim-state am) 'a)
       (< (abs (- (m4at am-jm4 1 0) 0.7071)) 0.002)))
;; a goto to the state already playing is a no-op
(anim-goto! am 'a)
(anim-update! am 0.25)                   ; the clock just keeps going
(define am-jm5 (gltf-joint-matrices g3 0))
(define am-noop-ok
  (< (abs (- (m4at am-jm5 1 0) 0.36811)) 0.002))  ; 0.75 again

;; ---- fixture 5: KHR_mesh_quantization -- u16 positions (the tiny
;; node scale carries them) and normalized i8 normals ----
(define json5
  (string-append
   "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
   "\"scenes\":[{\"nodes\":[0]}],"
   "\"extensionsUsed\":[\"KHR_mesh_quantization\"],"
   "\"nodes\":[{\"mesh\":0,\"scale\":[0.5,0.5,0.5],"
   "\"translation\":[1,2,3]}],"
   "\"meshes\":[{\"primitives\":[{\"attributes\":"
   "{\"POSITION\":0,\"NORMAL\":1},\"indices\":2}]}],"
   "\"buffers\":[{\"byteLength\":44}],"
   "\"bufferViews\":["
   "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":24,\"byteStride\":8},"
   "{\"buffer\":0,\"byteOffset\":24,\"byteLength\":12,\"byteStride\":4},"
   "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}],"
   "\"accessors\":["
   "{\"bufferView\":0,\"componentType\":5123,\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":1,\"componentType\":5120,\"normalized\":true,"
   "\"count\":3,\"type\":\"VEC3\"},"
   "{\"bufferView\":2,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}"))
(define jlen5 (string-length json5))
(define jpad5 (remainder (- 4 (remainder jlen5 4)) 4))
(define total5 (+ 12 8 jlen5 jpad5 8 44))
(set! base 16384)
(set! at 0)
(u32! #x46546C67) (u32! 2) (u32! total5)
(u32! (+ jlen5 jpad5)) (u32! #x4E4F534A)
(str! json5)
(let pad ((i 0)) (when (< i jpad5) (b! 32) (pad (+ i 1))))
(u32! 44) (u32! #x004E4942)
;; POSITION u16 x3 + 2 pad, per vertex (stride 8)
(u16! 0) (u16! 0) (u16! 0) (b! 0) (b! 0)
(u16! 16384) (u16! 0) (u16! 0) (b! 0) (b! 0)
(u16! 0) (u16! 16384) (u16! 0) (b! 0) (b! 0)
;; NORMAL i8 x3 + 1 pad (stride 4): (0,0,127) (-127,0,0) (64,0,0)
(b! 0) (b! 0) (b! 127) (b! 0)
(b! 129) (b! 0) (b! 0) (b! 0)
(b! 64) (b! 0) (b! 0) (b! 0)
(u16! 0) (u16! 1) (u16! 2)                ; indices
(b! 0) (b! 0)                             ; pad to 44

(define g5 (gltf-parse 16384 total5))
(define p5 (car (gltf-prims g5)))
(define vb5 (gprim-vbase p5))
(define quant-ok
  (and (near? (%mem-f32-ref vb5) 0.0)               ; v0.x = 0
       (near? (%mem-f32-ref (+ vb5 24)) 16384.0)    ; v1.x = raw u16
       (near? (%mem-f32-ref (+ vb5 52)) 16384.0)    ; v2.y (vbase+48+4)
       ;; normalized i8 normals: 127/127, -127/127, 64/127
       (near? (%mem-f32-ref (+ vb5 20)) 1.0)        ; v0.nz
       (near? (%mem-f32-ref (+ vb5 36)) -1.0)       ; v1.nx (24+12)
       (< (abs (- (%mem-f32-ref (+ vb5 60)) 0.503937)) 0.0001) ; v2.nx (48+12)
       ;; the tiny scale + offset ride the node's world matrix
       (near? (vector-ref (gprim-world p5) 0) 0.5)
       (near? (vector-ref (gprim-world p5) 12) 1.0)
       (near? (vector-ref (gprim-world p5) 13) 2.0)))

(and parse-ok tex-parse-ok skin-parse-ok pose0-ok pose1-ok pose-mid-ok
     blend-ok pal-ok morph-parse-ok morph0-ok morph-anim-ok
     morph-hand-ok quant-ok
     am-run-ok am-fade-ok am-done-ok am-instant-ok am-noop-ok
     skin-draw-ok draw-ok reuse-ok tex-load-ok tex-draw-ok mismatch-ok)
