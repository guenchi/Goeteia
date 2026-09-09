;; expect: #t
;; RED ON PURPOSE: two translucent surfaces of the same colour are
;; welded into one draw even when a differently coloured translucent
;; surface lies between them in depth.
;;
;; ⭐ The premise is written down beside the weld, and it is a correct
;; argument with a missing quantifier:
;;
;;     "blending a*C + (1-a)*dst with one C and one a gives the same
;;      pixel in either order"
;;
;; That proves swapping two ADJACENT layers of one colour and one alpha
;; is a no-op.  It is used to justify merging them into a single draw,
;; which additionally requires them to BE adjacent.  ⇒ When something
;; else is composited between them, merging moves it to one side.
;;
;; ⚠️ The arithmetic, checked rather than asserted.  Three planes, each
;; alpha 0.5, on black: far red, middle blue, near red.
;;
;;     far R, mid B, near R    (0.625, 0, 0.25)   <- correct
;;     the two reds together   (0.375, 0, 0.5)  or  (0.75, 0, 0.125)
;;
;; Neither merged order is the right colour, and the error is a quarter
;; of full scale in two channels.  ⇒ This is not a rounding question.
;;
;; ⭐ The cell counts DRAWS rather than pixels, on purpose: the mock GL
;; records calls, and what is wrong is the decision to merge, which is
;; visible one step before any pixel exists.  A pixel test would need a
;; real GL and would then be measuring the blender as well.
;;
;; The controls are the two shapes that SHOULD weld -- two same-colour
;; opaque surfaces, and two same-colour translucent surfaces with
;; nothing between them -- because the weld is a real optimisation and
;; a fix that abandons it for all translucent geometry would satisfy
;; the red while costing every scene that never had this problem.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (web reactive) (gfx scene))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, UNIFORM_BUFFER:'UBUF', getUniformBlockIndex(pr,n){ return 'I:' + n }, uniformBlockBinding(pr,i,b){ push('ubb', pr.id, i, b) }, bindBufferBase(t,b,buf){ push('bbb', t, b, buf ? buf.id : 'null') }, bufferSubData(t,o,arr){ push('subData', t, arr.length) }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', typeof arr === 'number' ? 'size' + arr : arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[0].toFixed(2), arr[12].toFixed(2)) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, activeTexture(u){ push('activeTexture', u) }, bindTexture(t,tex){ push('bindTexture', tex ? tex.id : 'null') }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, texParameteri(){}, TEXTURE0:33984, TEXTURE_2D:'T2D', TEXTURE_CUBE_MAP:'TCM', drawArrays(m,f,c){ push('draw', m, f, c) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, depthMask(b){ push('depthMask', b?1:0) }, vertexAttribDivisor(l,d){ if (d > 0) push('divisor', l, d) }, drawElementsInstanced(m,c,t,o,n){ push('drawInst', m, c, n) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define gllog (js-get (js-global) "__gllog"))
(define (log-len) (js->number (js-get gllog "length")))
(define (entry i) (js->string (js-index gllog i)))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-log p)
  (let ((n (log-len)))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1) (if (prefix? p (entry i)) (+ c 1) c))))))
(define (check-from base es)
  (let loop ((i base) (es es))
    (or (null? es)
        (and (or (string=? (entry i) (car es))
                 (begin (display "mismatch at ") (display i)
                        (display ": got ") (display (entry i))
                        (display " want ") (display (car es)) (newline)
                        #f))
             (loop (+ i 1) (cdr es))))))


(fx-init! (js-get (js-global) "__mockcanvas"))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; ⚠️ Count BOTH draw kinds.  Identical geometry of one colour becomes
;; an instance group, which the mock logs as drawInst, so a counter
;; that only knew drawElements read zero for the opaque control and
;; would have been reported as "the control does not draw".  ⭐ The
;; first version did exactly that, and the zero looked like a broken
;; scene rather than a blind instrument.
(define (draws-of sc)
  (let ((e0 (count-log "drawElements")) (i0 (count-log "drawInst")))
    (cmd-begin!) (sgl-draw! sc) (cmd-flush!)
    (list 'elements (- (count-log "drawElements") e0)
          'instanced (- (count-log "drawInst") i0))))

;; ---- controls: welds that must keep happening ----
(define opaque-pair
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 10.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 -2.0) (color 1.0 0.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 2.0) (color 1.0 0.0 0.0)))))
(want 'g16-CONTROL-opaque-same-colour (draws-of opaque-pair) '(elements 0 instanced 1))

(define glass-pair
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 10.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 -2.0) (color 1.0 0.0 0.0 0.5)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 2.0) (color 1.0 0.0 0.0 0.5)))))
(want 'g16-CONTROL-glass-nothing-between (draws-of glass-pair) '(elements 1 instanced 0))

;; ---- red: a different colour between them ----
(define sandwich
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 10.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 -3.0) (color 1.0 0.0 0.0 0.5)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 0.0) (color 0.0 0.0 1.0 0.5)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 3.0) (color 1.0 0.0 0.0 0.5)))))
(want 'g16-sandwich-keeps-three-draws (draws-of sandwich) '(elements 3 instanced 0))

(if (null? fails) (display #t) (begin (display fails) (newline)))
