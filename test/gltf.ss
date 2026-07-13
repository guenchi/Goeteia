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

;; ---- draw through the recording mock: one upload, then reuse ----
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[12].toFixed(2), arr[13].toFixed(2)) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

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

(and parse-ok draw-ok reuse-ok)
