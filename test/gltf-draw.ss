;; expect: #t
;; gltf-draw! contract checks through the recording mock GL.
;; Two GLBs whose primitives collide at stride 64 with DIFFERENT
;; layouts:
;;   K  skinned:  position normal uv joints weights
;;   S  static:   position normal uv tangent color
;; A stride check alone cannot tell them apart -- drawing S with the
;; skinned program would feed tangents to a_joints and collapse the
;; mesh silently.  gltf-draw! must match the program's attribute
;; names against gprim-layout and refuse the mismatch.
;; And: after gltf-load-textures! every primitive must own a value
;; for the optional material slots (1x1 flat-normal/white defaults),
;; so a program declaring u_nmap never samples a stale unit from the
;; previous primitive or unit 0's base color.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf))

(define base (fx-alloc! 8192))
(define at 0)
(define orig 0)
(define (b! v) (%mem-u8-set! (+ base at) v) (set! at (+ at 1)))
(define (u16! v) (b! (remainder v 256)) (b! (quotient v 256)))
(define (u32! v)
  (b! (remainder v 256))
  (b! (remainder (quotient v 256) 256))
  (b! (remainder (quotient v 65536) 256))
  (b! (quotient v 16777216)))
(define (f32! v) (%mem-f32-set! (+ base at) v) (set! at (+ at 4)))
(define (v3! x y z) (f32! x) (f32! y) (f32! z))
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

;; ---- K: skinned triangle (stride 64) ----
(define k-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"scenes\":[{\"nodes\":[0,1]}],"
    "\"nodes\":[{\"mesh\":0,\"skin\":0,\"translation\":[50,0,0]},"
    "{\"name\":\"j\"}],"
    "\"skins\":[{\"joints\":[1]}],"
    "\"meshes\":[{\"primitives\":[{\"attributes\":"
    "{\"POSITION\":0,\"JOINTS_0\":1,\"WEIGHTS_0\":2},\"indices\":3}]}],"
    "\"buffers\":[{\"byteLength\":116}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":12},"
    "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":48},"
    "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"},"
    "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
    "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}")
   116
   (lambda ()
     (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
     (let j ((i 0)) (when (< i 12) (b! 0) (j (+ i 1))))
     (let w ((i 0))
       (when (< i 3)
         (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 0.0)
         (w (+ i 1))))
     (u16! 0) (u16! 1) (u16! 2) (u16! 0))))

;; ---- S: static tangent+color triangle (also stride 64) ----
(define s-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"scenes\":[{\"nodes\":[0]}],"
    "\"nodes\":[{\"mesh\":0}],"
    "\"meshes\":[{\"primitives\":[{\"attributes\":"
    "{\"POSITION\":0,\"TEXCOORD_0\":1,\"TANGENT\":2,\"COLOR_0\":3},"
    "\"indices\":4}]}],"
    "\"buffers\":[{\"byteLength\":128}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":24},"
    "{\"buffer\":0,\"byteOffset\":60,\"byteLength\":48},"
    "{\"buffer\":0,\"byteOffset\":108,\"byteLength\":12},"
    "{\"buffer\":0,\"byteOffset\":120,\"byteLength\":6}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},"
    "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"},"
    "{\"bufferView\":3,\"componentType\":5121,\"normalized\":true,"
    "\"count\":3,\"type\":\"VEC4\"},"
    "{\"bufferView\":4,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}")
   128
   (lambda ()
     (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
     (f32! 0.0) (f32! 0.0) (f32! 1.0) (f32! 0.0)
     (f32! 0.0) (f32! 1.0)
     (let t ((i 0))
       (when (< i 3)
         (f32! 1.0) (f32! 0.0) (f32! 0.0) (f32! 1.0)
         (t (+ i 1))))
     (let c ((i 0)) (when (< i 12) (b! 255) (c (+ i 1))))
     (u16! 0) (u16! 1) (u16! 2) (u16! 0))))

(define gk (gltf-parse (car k-loc) (cdr k-loc)))
(define gs (gltf-parse (car s-loc) (cdr s-loc)))

(define stride-collision                  ; the ambiguity is real
  (and (= (gprim-stride (car (gltf-prims gk))) 64)
       (= (gprim-stride (car (gltf-prims gs))) 64)
       (not (equal? (gprim-layout (car (gltf-prims gk)))
                    (gprim-layout (car (gltf-prims gs)))))))

;; ---- the recording mock GL (as in test/gltf.ss) ----
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, generateMipmap(t){ push('genMip', t) }, texImage2D(...a){ push('texImage', a.length) }, activeTexture(u){ push('activeTexture', u) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[12].toFixed(2)) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

;; image decode, synchronously: the loader only needs a thenable
(js-eval "globalThis.Blob = function(){}; globalThis.__imgn = 0; globalThis.createImageBitmap = () => ({ then: f => { f({id:'IMG'+(++globalThis.__imgn)}); return {then(){}} } })")

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

(define skin-prog (fx-program! gltf-skin-vs mesh-tex-fs))

;; K through the matching skinned program: draws
(cmd-begin!)
(gltf-draw! gk skin-prog (m4-identity))
(cmd-flush!)
(define k-draw-ok (= (count-log "drawElements:TRI:3:US") 1))

;; S through the SAME-STRIDE skinned program: must refuse
(define s-mismatch-ok
  (guard (e (#t #t))
    (cmd-begin!)
    (gltf-draw! gs skin-prog (m4-identity))
    (cmd-flush!)
    #f))

;; ---- optional material slots default after load-textures ----
(define s-vs
  '((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    (attribute vec2 a_uv)
    (attribute vec4 a_tangent)
    (attribute vec4 a_color)
    (uniform mat4 u_mvp)
    (uniform mat4 u_model)
    (varying vec2 v_uv)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (set! v_uv a_uv))))
(define s-fs
  '((precision mediump float)
    (uniform sampler2D u_nmap)
    (uniform vec4 u_color)
    (varying vec2 v_uv)
    (define (main) void
      (set! gl_FragColor (* (texture2D u_nmap v_uv) u_color)))))
(define s-prog (fx-program! s-vs s-fs))

(define done #f)
(gltf-load-textures! gs (lambda (g2) (set! done #t)))

;; every optional slot owns a value -- including base color, whose
;; unit 0 would otherwise keep the previous primitive's image.  But
;; the fallback must not erase the ASSET-level fact: gprim-textured?
;; still answers "did the material declare a base color image", the
;; question a renderer picks a shader with.  gs's material declares
;; none.
(define defaults-ok
  (let ((p (car (gltf-prims gs))))
    (and done
         (gprim-ntex p) (gprim-etex p) (gprim-otex p)
         (gprim-tex p)                  ; a bindable fallback ...
         (not (gprim-textured? p)))))   ; ... but not a real image

(cmd-begin!)
(gltf-draw! gs s-prog (m4-identity))
(cmd-flush!)
(define nmap-bound-ok                     ; u_nmap points at unit 1
  (= (count-log "uniform1i:U:u_nmap:1") 1))

;; ---- a combinator-built program pairs with the loader's layout ----
;; mesh-lit-vs has no a_uv, but the loader always carries a uv slot
;; once anything past position+normal is present, so the combinator
;; must produce the same canonical layout the loader emits.
(define lit-skin-prog
  (fx-program! (gltf-skin-shader mesh-lit-vs) mesh-lit-fs))
(define combinator-layout-ok
  (guard (e (#t #f))
    (cmd-begin!)
    (gltf-draw! gk lit-skin-prog (m4-identity))
    (cmd-flush!)
    #t))

;; ---- a fragment shader without u_tex must not be forced one ----
;; the documented normal-map pairing declares u_nmap and no u_tex;
;; an asset whose material has a baseColorTexture must still draw.
(define td-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"scenes\":[{\"nodes\":[0]}],"
    "\"nodes\":[{\"mesh\":0}],"
    "\"meshes\":[{\"primitives\":[{\"attributes\":"
    "{\"POSITION\":0,\"TEXCOORD_0\":1},\"indices\":2,\"material\":0}]}],"
    "\"materials\":[{\"pbrMetallicRoughness\":"
    "{\"baseColorTexture\":{\"index\":0}}}],"
    "\"textures\":[{\"source\":0}],"
    "\"images\":[{\"bufferView\":3,\"mimeType\":\"image/png\"}],"
    "\"buffers\":[{\"byteLength\":72}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":24},"
    "{\"buffer\":0,\"byteOffset\":60,\"byteLength\":6},"
    "{\"buffer\":0,\"byteOffset\":68,\"byteLength\":4}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},"
    "{\"bufferView\":2,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]}")
   72
   (lambda ()
     (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
     (f32! 0.0) (f32! 0.0) (f32! 1.0) (f32! 0.0)
     (f32! 0.0) (f32! 1.0)
     (u16! 0) (u16! 1) (u16! 2) (u16! 0)
     (u32! #xFFFFFFFF))))
(define gt (gltf-parse (car td-loc) (cdr td-loc)))
(define tex-vs
  '((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    (attribute vec2 a_uv)
    (uniform mat4 u_mvp)
    (uniform mat4 u_model)
    (varying vec2 v_uv)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (set! v_uv a_uv))))
(define nmap-only-fs                      ; declares u_nmap, NOT u_tex
  '((precision mediump float)
    (uniform sampler2D u_nmap)
    (uniform vec4 u_color)
    (varying vec2 v_uv)
    (define (main) void
      (set! gl_FragColor (* (texture2D u_nmap v_uv) u_color)))))
(define nmap-only-prog (fx-program! tex-vs nmap-only-fs))
(define t-done #f)
(gltf-load-textures! gt (lambda (g2) (set! t-done #t)))
;; gt's material DOES declare a base color image
(define textured-pred-ok
  (and t-done (gprim-textured? (car (gltf-prims gt)))))

(define base-tex-optional-ok
  (and t-done
       (guard (e (#t #f))
         (cmd-begin!)
         (gltf-draw! gt nmap-only-prog (m4-identity))
         (cmd-flush!)
         #t)))

;; ---- an animated UNSKINNED node moves what gets drawn ----
;; the world matrix a primitive draws with must come from the
;; runtime node tree, not from a snapshot taken at parse time.
(define an-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"scenes\":[{\"nodes\":[0]}],"
    "\"nodes\":[{\"children\":[1],\"translation\":[0,0,0]},"
    "{\"mesh\":0,\"translation\":[100,0,0]}],"
    "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0},"
    "\"indices\":1}]}],"
    "\"animations\":[{\"name\":\"slide\","
    "\"samplers\":[{\"input\":2,\"output\":3,"
    "\"interpolation\":\"LINEAR\"}],"
    "\"channels\":[{\"sampler\":0,\"target\":"
    "{\"node\":0,\"path\":\"translation\"}}]}],"
    "\"buffers\":[{\"byteLength\":76}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6},"
    "{\"buffer\":0,\"byteOffset\":44,\"byteLength\":8},"
    "{\"buffer\":0,\"byteOffset\":52,\"byteLength\":24}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
    "{\"bufferView\":2,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
    "{\"bufferView\":3,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"}]}")
   76
   (lambda ()
     (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
     (u16! 0) (u16! 1) (u16! 2) (u16! 0)
     (f32! 0.0) (f32! 1.0)
     (v3! 0.0 0.0 0.0) (v3! 10.0 0.0 0.0))))
(define ga (gltf-parse (car an-loc) (cdr an-loc)))
(define lit-prog (fx-program! mesh-lit-vs mesh-lit-fs))
(gltf-animate! ga 0 0.5)                  ; node slides to x = 5
(cmd-begin!)
(gltf-draw! ga lit-prog (m4-identity))
(cmd-flush!)
;; the mesh sits UNDER the animated node at a fixed local offset of
;; 100, so a $node-global that ignored the parent chain would report
;; 100 and a snapshot world would report 100 as well -- only walking
;; the runtime parents gives 105
(define animated-world-ok
  (= (count-log "uniformMat4:U:u_model:16:105.00") 1))

;; a program that legitimately omits u_model must draw on the
;; unskinned path too, not only on the skinned one
(define no-model-vs
  '((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    (uniform mat4 u_mvp)
    (varying vec3 v_n)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (set! v_n a_normal))))
(define no-model-fs
  '((precision mediump float)
    (uniform vec4 u_color)
    (varying vec3 v_n)
    (define (main) void (set! gl_FragColor u_color))))
(define no-model-prog (fx-program! no-model-vs no-model-fs))
(define no-u-model-ok
  (guard (e (#t #f))
    (cmd-begin!)
    (gltf-draw! ga no-model-prog (m4-identity))
    (cmd-flush!)
    #t))

;; ---- a node expressed as a matrix ----
;; a matrix node keeps its transform in a slot the pose arena does
;; not snapshot and no channel writes; $node-local reads it in
;; preference to TRS, which is what makes reset harmless.  These
;; two cases pin that down: an animated parent moving a
;; matrix-transformed child, and a clip that touches the matrix
;; node itself (glTF forbids animating one, so the channel is
;; ignored -- but ignoring it must not zero the transform).
(define mx-loc
  (glb!
   (string-append
    "{\"asset\":{\"version\":\"2.0\"},\"scene\":0,"
    "\"scenes\":[{\"nodes\":[0]}],"
    "\"nodes\":[{\"children\":[1],\"translation\":[0,0,0]},"
    "{\"mesh\":0,"
    "\"matrix\":[1,0,0,0, 0,1,0,0, 0,0,1,0, 20,0,0,1]}],"
    "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0},"
    "\"indices\":1}]}],"
    "\"animations\":[{\"name\":\"slide\","
    "\"samplers\":[{\"input\":2,\"output\":3,"
    "\"interpolation\":\"LINEAR\"}],"
    "\"channels\":[{\"sampler\":0,\"target\":"
    "{\"node\":0,\"path\":\"translation\"}}]},"
    "{\"name\":\"onmatrix\","
    "\"samplers\":[{\"input\":2,\"output\":3,"
    "\"interpolation\":\"LINEAR\"}],"
    "\"channels\":[{\"sampler\":0,\"target\":"
    "{\"node\":1,\"path\":\"translation\"}}]}],"
    "\"buffers\":[{\"byteLength\":76}],"
    "\"bufferViews\":["
    "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},"
    "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6},"
    "{\"buffer\":0,\"byteOffset\":44,\"byteLength\":8},"
    "{\"buffer\":0,\"byteOffset\":52,\"byteLength\":24}],"
    "\"accessors\":["
    "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},"
    "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"},"
    "{\"bufferView\":2,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},"
    "{\"bufferView\":3,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"}]}")
   76
   (lambda ()
     (v3! 0.0 0.0 0.0) (v3! 1.0 0.0 0.0) (v3! 0.0 1.0 0.0)
     (u16! 0) (u16! 1) (u16! 2) (u16! 0)
     (f32! 0.0) (f32! 1.0)
     (v3! 0.0 0.0 0.0) (v3! 10.0 0.0 0.0))))
(define gm (gltf-parse (car mx-loc) (cdr mx-loc)))
(gltf-animate! gm 0 0.5)                  ; parent slides to 5
(cmd-begin!)
(gltf-draw! gm lit-prog (m4-identity))
(cmd-flush!)
(define matrix-node-ok                    ; 20 (matrix) + 5 (parent)
  (= (count-log "uniformMat4:U:u_model:16:25.00") 1))

;; the clip that touches the matrix node, through the reset path
(gltf-animate! gm 0 0.0)                  ; parent back to 0
(gltf-animate! gm 1 0.5)                  ; the clip that touches it
(cmd-begin!)
(gltf-draw! gm lit-prog (m4-identity))
(cmd-flush!)
(define matrix-reset-ok
  (= (count-log "uniformMat4:U:u_model:16:20.00") 1))

(define (near2? a b)
  (and (fl<? (fl- a b) 0.001) (fl<? (fl- b a) 0.001)))

;; gprim-world is the BIND pose; gltf-prim-world is what draws.
;; A custom renderer needs the second, so the split has to be
;; reachable and the two must actually differ under animation.
(define prim-world-split-ok
  (let ((p (car (gltf-prims ga))))
    (and (near2? (vector-ref (gprim-world p) 12) 100.0)
         (near2? (vector-ref (gltf-prim-world ga p) 12) 105.0))))

;; ... and for a SKINNED primitive it must agree with what
;; gltf-draw! does, which is to ignore the node transform entirely
;; (the palette already carries the pose).  Returning the node's
;; global here would make a custom renderer transform twice.
(define skinned-prim-world-ok
  (let ((p (car (gltf-prims gk))))
    (and (near2? (vector-ref (gltf-prim-world gk p) 12) 0.0)
         (near2? (vector-ref (gltf-prim-world gk p) 0) 1.0)
         (near2? (vector-ref (gltf-prim-world gk p) 5) 1.0))))

(and stride-collision k-draw-ok s-mismatch-ok defaults-ok
     nmap-bound-ok combinator-layout-ok base-tex-optional-ok
     animated-world-ok matrix-node-ok matrix-reset-ok
     prim-world-split-ok skinned-prim-world-ok
     no-u-model-ok textured-pred-ok)
