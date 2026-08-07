;; expect: #t
;; The big joint palette: skins past the 32-matrix uniform array
;; draw through a std140 uniform block instead.
;;
;; The two carriers are one combinator with two palette
;; declarations, and the choice is the PROGRAM's: a program built
;; with gltf-skin-shader3 declares a Skin block and draws through
;; cmd-ubo-data!/cmd-bind-ubo!, one built with gltf-skin-shader
;; declares uniform mat4 u_joints[32] and draws exactly as before.
;; Neither consults registration order, and a small asset is legal
;; on either.
;;
;; The fixture is a 40-joint chain of pure unit translations, so
;; every palette matrix has a closed form (joint k sits at x = k+1)
;; and a loader that truncated the skeleton at 32 -- or an upload
;; that assumed anything but std140's 64-byte mat4 stride -- shows
;; up as a wrong number rather than as a blank screen.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf))

;; ---- the recording mock GL: as elsewhere, plus the UBO calls ----
(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', UNIFORM_BUFFER:'UBUF', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){}, generateMipmap(t){}, texImage2D(...a){}, activeTexture(u){}, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform2f(loc,x,y){}, createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, getUniformBlockIndex(p,n){ return 'I:'+n }, uniformBlockBinding(p,i,b){ push('ubb', p.id, i, b) }, bindBufferBase(t,b,buf){ push('bbb', t, b, buf ? buf.id : 'null') }, bufferSubData(t,o,arr){ push('subData', arr.length); globalThis.__sub = Array.from(new Float32Array(arr.buffer, arr.byteOffset, arr.length >> 2)) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':t==='UBUF'?'bindUBO':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', typeof arr === 'number' ? 'size'+arr : arr.length) }, enableVertexAttribArray(l){}, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){}, uniform3f(loc,x,y,z){}, uniform4f(loc,...a){}, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length); if (loc.id === 'U:u_joints') globalThis.__umat = Array.from(arr) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){} } } }")

(define gllog (js-get (js-global) "__gllog"))
(define (entry i) (js->string (js-index gllog i)))
(define (log-len) (js->number (js-get gllog "length")))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-log-from p from)
  (let ((n (log-len)))
    (let loop ((i from) (c 0))
      (if (= i n)
          c
          (loop (+ i 1) (if (prefix? p (entry i)) (+ c 1) c))))))
;; index of the first entry at or after `from` with this prefix, or
;; -1.  Order inside one draw is the whole point here: an upload
;; that landed AFTER the draw would feed the previous frame's pose.
(define (find-log-from p from)
  (let ((n (log-len)))
    (let loop ((i from))
      (cond ((= i n) -1)
            ((prefix? p (entry i)) i)
            (else (loop (+ i 1)))))))

;; the staging arena comes AFTER fx-init!: fx-init! rewinds the bump
;; allocator, so anything allocated before it gets handed out a
;; second time
(fx-init! (js-get (js-global) "__mockcanvas"))

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

;; ---- a chain of nj joints, each one unit further along +x ----
;; node 0 carries the mesh and the skin; nodes 1..nj are the chain,
;; every one translated (1,0,0) from its parent.  No
;; inverseBindMatrices, so the bind matrices are the identity and
;; palette[k] is exactly the global of joint k: a translation by
;; (k+1, 0, 0).
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

;; the vertices reference the HIGH end of the skeleton, so a
;; skeleton silently clipped to 32 joints would point them at
;; matrices that are not there
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

(define loc40 (chain-glb! 40))
(define loc29 (chain-glb! 29))

(define g40 (gltf-parse (car loc40) (cdr loc40)))
(define g29 (gltf-parse (car loc29) (cdr loc29)))

;; ---- the loader accepts what the big palette can hold ----
(define parse-40-ok (= (gltf-joint-count g40 0) 40))

;; ... and refuses what it cannot, saying by how much
(define reject-257-ok
  (let ((l (chain-glb! 257)))
    (guard (e (#t #t))
      (gltf-parse (car l) (cdr l))
      #f)))

;; ---- the palette itself: closed form, all 40 of them ----
(define pal40 (gltf-joint-palette! g40 0))
(define (m4s-at at i) (%mem-f32-ref (+ at (* 4 i))))
(define (near? a b) (< (abs (- a b)) 0.001))
;; joint k is a pure translation by (k+1, 0, 0): the basis is the
;; identity and the fourth column carries the offset
(define (chain-matrix-ok? at k)
  (and (near? (m4s-at at 0) 1.0) (near? (m4s-at at 5) 1.0)
       (near? (m4s-at at 10) 1.0) (near? (m4s-at at 15) 1.0)
       (near? (m4s-at at 1) 0.0) (near? (m4s-at at 4) 0.0)
       (near? (m4s-at at 12) (+ k 1.0))
       (near? (m4s-at at 13) 0.0)
       (near? (m4s-at at 14) 0.0)))
(define palette-40-ok
  (let loop ((k 0))
    (or (= k 40)
        (and (chain-matrix-ok? (+ pal40 (* k 64)) k)
             (loop (+ k 1))))))
;; the boxed reference path agrees with the resident one -- two
;; independent computations of the same skeleton
(define jm40 (gltf-joint-matrices g40 0))
(define joint-matrices-40-ok
  (and (= (vector-length jm40) 40)
       (near? (vector-ref (vector-ref jm40 39) 12) 40.0)
       (near? (vector-ref (vector-ref jm40 0) 12) 1.0)))

;; ---- the combinator's big-palette flavour ----
(define big-vs (gltf-skin-shader3 mesh-tex-vs))
(define big-src (glsl300-vs->string big-vs))
(define (contains? s sub)
  (let ((sl (string-length s)) (bl (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i bl) sl) #f)
            ((string=? (substring s i (+ i bl)) sub) #t)
            (else (loop (+ i 1)))))))
(define shader3-ok
  (and (contains? big-src "layout(std140) uniform Skin { ")
       (contains? big-src "highp mat4 u_joints[256]; ")
       ;; the ACCESS syntax is what must not change: a body written
       ;; against the small palette compiles against the big one
       (contains? big-src "u_joints[int(a_joints.x)]")
       (contains? big-src "u_joints[int(a_joints.w)]")
       ;; no leftover plain uniform array
       (not (contains? big-src "uniform highp mat4 u_joints[32]"))
       (equal? (glsl-uniform-blocks big-vs)
               (list (list 'Skin (list (list 'array 'mat4 256)
                                       'u_joints))))
       ;; the attribute interleave is the same one the small
       ;; flavour produces -- same loader layout, same fs pairing
       (equal? (map car (glsl-attributes big-vs))
               (map car (glsl-attributes (gltf-skin-shader mesh-tex-vs))))
       (equal? (glsl-varyings big-vs)
               (glsl-varyings (gltf-skin-shader mesh-tex-vs)))
       ;; the built-in is derived from the combinator, not copied
       (equal? gltf-skin-vs3 big-vs)))

;; the small flavour is untouched: still ESSL 1.00, still 32
(define shader1-untouched-ok
  (let ((s (glsl->string (gltf-skin-shader mesh-tex-vs))))
    (and (contains? s "uniform mat4 u_joints[32]; ")
         (not (contains? s "Skin")))))

;; a uniform block form has no ESSL 1.00 spelling, so building the
;; big shader with fx-program! must fail rather than emit nonsense
(define (errors? th) (guard (e (#t #t)) (th) #f))
(define needs-essl3-ok (errors? (lambda () (glsl->string big-vs))))

;; the injected block name is reserved in the input, like every
;; other name the combinator injects
(define reserved-block-ok
  (and (errors? (lambda ()
                  (gltf-skin-shader3
                   '((attribute vec3 a_pos)
                     (uniform-block Skin (mat4 u_other))
                     (define (main) void
                       (set! gl_Position (vec4 a_pos (fl 1))))))))
       ;; a block of another name is the caller's business
       (not (errors? (lambda ()
                       (gltf-skin-shader3
                        '((attribute vec3 a_pos)
                          (uniform-block Env (mat4 u_vp))
                          (define (main) void
                            (set! gl_Position
                                  (* u_vp (vec4 a_pos (fl 1))))))))))))

;; ---- the programs ----
(define big-prog (gltf-skin-program3! mesh-tex-vs mesh-tex-fs))
(define small-prog (fx-program! gltf-skin-vs mesh-tex-fs))

;; the block is wired to gltf-skin-binding at build time, once
(define wiring-ok
  (and (= gltf-skin-binding 1)
       (= (count-log-from "ubb:P1:I:Skin:1" 0) 1)
       (equal? (fx-program-blocks big-prog) '(Skin))
       (equal? (fx-program-blocks small-prog) '())
       ;; mutually exclusive: the block member has no uniform
       ;; location, the array does
       (not (fx-uniform? big-prog 'u_joints))
       (fx-uniform? small-prog 'u_joints)))

;; ---- the big draw: upload, bind, then draw ----
(define mark1 (log-len))
(cmd-begin!)
(gltf-draw! g40 big-prog (m4-identity))
(cmd-flush!)

(define i-sub (find-log-from "subData:" mark1))
(define i-bind (find-log-from "bbb:" mark1))
(define i-draw (find-log-from "drawElements:" mark1))
(define big-draw-ok
  (and (= (count-log-from "drawElements:TRI:3:US" mark1) 1)
       ;; 40 matrices x 64 bytes, and not one byte more: the block
       ;; is 256 slots but only the live joints ship
       (= (count-log-from "subData:2560" mark1) 1)
       (= (count-log-from "bbb:UBUF:1:" mark1) 1)
       ;; both before the draw they belong to
       (>= i-sub 0) (>= i-bind 0) (>= i-draw 0)
       (< i-sub i-draw) (< i-bind i-draw)
       ;; and nothing went out through the old carrier
       (= (count-log-from "uniformMat4:U:u_joints" mark1) 0)))

;; the buffer itself is the full block: a shorter one would be too
;; small for the mat4[256] the shader declares
(define ubo-size-ok (= (count-log-from "bufferData:size16384" 0) 1))

;; the bytes that reached the buffer ARE the palette, in order
(define sub (js-get (js-global) "__sub"))
(define (subf i) (js->number (js-index sub i)))
(define big-payload-ok
  (and (= (js->number (js-get sub "length")) 640)   ; 40 x 16 floats
       (let loop ((k 0))
         (or (= k 40)
             (and (near? (subf (+ (* k 16) 12)) (+ k 1.0))
                  (near? (subf (+ (* k 16) 0)) 1.0)
                  (loop (+ k 1)))))))

;; ---- a 29-joint asset is legal on the big program too ----
(define mark2 (log-len))
(cmd-begin!)
(gltf-draw! g29 big-prog (m4-identity))
(cmd-flush!)
(define small-asset-big-program-ok
  (and (= (count-log-from "drawElements:TRI:3:US" mark2) 1)
       (= (count-log-from "subData:1856" mark2) 1)   ; 29 x 64
       (= (count-log-from "bbb:UBUF:1:" mark2) 1)))
(define sub29 (js-get (js-global) "__sub"))

;; ---- degeneracy: the same skeleton down the other path ----
(define mark3 (log-len))
(cmd-begin!)
(gltf-draw! g29 small-prog (m4-identity))
(cmd-flush!)
(define small-draw-ok
  (and (= (count-log-from "drawElements:TRI:3:US" mark3) 1)
       (= (count-log-from "uniformMat4:U:u_joints:464" mark3) 1) ; 29x16
       ;; the small path touches no uniform buffer at all
       (= (count-log-from "subData:" mark3) 0)
       (= (count-log-from "bbb:" mark3) 0)))

;; two carriers, one skeleton: float for float, same values in the
;; same order.  A repack (a std140 stride assumed to be anything but
;; 64 bytes) shows up here even when both lengths look plausible.
(define umat (js-get (js-global) "__umat"))
(define cross-path-ok
  (and (= (js->number (js-get umat "length")) 464)
       (= (js->number (js-get sub29 "length")) 464)
       (let loop ((i 0))
         (or (= i 464)
             (and (near? (js->number (js-index umat i))
                         (js->number (js-index sub29 i)))
                  (loop (+ i 1)))))))

;; ---- the one combination that cannot work is refused by name ----
(define oversize-refused-ok
  (errors? (lambda ()
             (cmd-begin!)
             (gltf-draw! g40 small-prog (m4-identity))
             (cmd-flush!))))

;; a program with the loader's attributes but NO palette at all is
;; refused too, rather than drawing an unposed mesh
(define no-palette-prog
  (fx-program! (filter (lambda (f)
                         (not (and (pair? f) (eq? (car f) 'uniform)
                                   (eq? (caddr f) 'u_joints))))
                       gltf-skin-vs)
               mesh-tex-fs))
(define no-palette-refused-ok
  (errors? (lambda ()
             (cmd-begin!)
             (gltf-draw! g29 no-palette-prog (m4-identity))
             (cmd-flush!))))

(display (and parse-40-ok reject-257-ok
              palette-40-ok joint-matrices-40-ok
              shader3-ok shader1-untouched-ok needs-essl3-ok
              reserved-block-ok wiring-ok
              big-draw-ok ubo-size-ok big-payload-ok
              small-asset-big-program-ok small-draw-ok
              cross-path-ok
              oversize-refused-ok no-palette-refused-ok))
