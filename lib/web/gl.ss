;; Raw WebGL through a command buffer (tier 3).
;;
;; Per frame, Scheme encodes GL commands as words into the linear
;; staging memory and makes ONE bridge call; a JS replayer (embedded
;; here, injected once with js-eval) walks the words in a tight loop
;; and issues the real gl.* calls. Vertex data also lives in the
;; staging memory, so BUFFER-DATA uploads it zero-copy.
;;
;; Resources (programs, buffers, uniform locations) are JS objects and
;; cannot cross as bytes: they are created once at init time over the
;; normal FFI and kept in a slot table; commands refer to slot numbers.
;;
;;   (gl-attach! canvas)                      ; once
;;   (gl-program! 0 vs-src fs-src)            ; slots, once
;;   (gl-buffer! 1)
;;   (gl-uniform! 2 0 "u_time")
;;   ... per frame:
;;   (cmd-begin!)
;;   (cmd-clear! 0.1 0.1 0.15 1.0)
;;   (cmd-use-program! 0)
;;   (cmd-bind-buffer! 1)
;;   (cmd-buffer-data! vertex-base byte-len)  ; from staging memory
;;   (cmd-vertex-attrib! 0 2 0 0)
;;   (cmd-draw-arrays! GL-POINTS 0 n)
;;   (cmd-flush!)                             ; the one bridge call
;;
;; Layout is caller-chosen: commands go at cmd-base (set by
;; cmd-region!), vertex/user data wherever you put it.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web gl)
  (export gl-attach! gl-program! gl-buffer! gl-uniform!
          gl-texture! gl-texture-upload!
          cmd-region! cmd-begin! cmd-flush! cmd-pos
          cmd-clear! cmd-use-program! cmd-bind-buffer! cmd-buffer-data!
          cmd-vertex-attrib! cmd-uniform1f! cmd-uniform4f!
          cmd-uniform1i! cmd-uniform2f! cmd-uniform3f! cmd-uniform-matrix4!
          cmd-bind-texture! cmd-depth!
          cmd-bind-index! cmd-index-data! cmd-draw-elements!
          cmd-draw-arrays! cmd-viewport! cmd-blend!
          GL-POINTS GL-LINES GL-TRIANGLES GL-TRIANGLE-STRIP)
  (import (rnrs) (web js))

  ;; WebGL draw-mode enums
  (define GL-POINTS 0)
  (define GL-LINES 1)
  (define GL-TRIANGLES 4)
  (define GL-TRIANGLE-STRIP 5)

  ;; ---- the JS replayer, injected once ----
  (define replayer-src
    (string-append
     "globalThis.__goeteia_gl = (canvas, memory) => {"
     " const gl = canvas.getContext('webgl');"
     " const slots = [];"
     " const compile = (kind, src) => {"
     "   const s = gl.createShader(kind); gl.shaderSource(s, src); gl.compileShader(s);"
     "   if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))"
     "     throw new Error(gl.getShaderInfoLog(s));"
     "   return s; };"
     " return {"
     "  program(slot, vs, fs, attribs) {"
     "    const p = gl.createProgram();"
     "    gl.attachShader(p, compile(gl.VERTEX_SHADER, vs));"
     "    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));"
     "    if (attribs) String(attribs).split(',').forEach((n, i) => {"
     "      if (n) gl.bindAttribLocation(p, i, n); });"
     "    gl.linkProgram(p);"
     "    if (!gl.getProgramParameter(p, gl.LINK_STATUS))"
     "      throw new Error(gl.getProgramInfoLog(p));"
     "    slots[slot] = p; },"
     "  buffer(slot) { slots[slot] = gl.createBuffer(); },"
     "  uniform(slot, pslot, name) {"
     "    slots[slot] = gl.getUniformLocation(slots[pslot], name); },"
     "  texture(slot) {"
     "    const t = gl.createTexture();"
     "    gl.bindTexture(gl.TEXTURE_2D, t);"
     "    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);"
     "    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);"
     "    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);"
     "    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);"
     "    slots[slot] = t; },"
     "  textureUpload(slot, src, premul) {"
     "    if (premul) gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);"
     "    gl.bindTexture(gl.TEXTURE_2D, slots[slot]);"
     "    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA,"
     "                  gl.UNSIGNED_BYTE, src);"
     "    if (premul) gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false); },"
     "  replay(base, end) {"
     "    const u = new Uint32Array(memory.buffer);"
     "    const f = new Float32Array(memory.buffer);"
     "    let p = base >> 2; const stop = end >> 2;"
     "    while (p < stop) switch (u[p++]) {"
     "     case 1: gl.clearColor(f[p], f[p+1], f[p+2], f[p+3]); p += 4;"
     "             gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT); break;"
     "     case 2: gl.useProgram(slots[u[p++]]); break;"
     "     case 3: gl.bindBuffer(gl.ARRAY_BUFFER, slots[u[p++]]); break;"
     "     case 4: gl.bufferData(gl.ARRAY_BUFFER,"
     "               new Float32Array(memory.buffer, u[p], u[p+1] >> 2),"
     "               gl.DYNAMIC_DRAW); p += 2; break;"
     "     case 5: gl.enableVertexAttribArray(u[p]);"
     "             gl.vertexAttribPointer(u[p], u[p+1], gl.FLOAT, false, u[p+2], u[p+3]);"
     "             p += 4; break;"
     "     case 6: gl.uniform1f(slots[u[p]], f[p+1]); p += 2; break;"
     "     case 7: gl.uniform4f(slots[u[p]], f[p+1], f[p+2], f[p+3], f[p+4]); p += 5; break;"
     "     case 8: { const m = u[p] === 0 ? gl.POINTS : u[p] === 1 ? gl.LINES"
     "                : u[p] === 5 ? gl.TRIANGLE_STRIP : gl.TRIANGLES;"
     "               gl.drawArrays(m, u[p+1], u[p+2]); p += 3; break; }"
     "     case 9: gl.viewport(u[p], u[p+1], u[p+2], u[p+3]); p += 4; break;"
     "     case 10: if (u[p] === 1) { const m = u[p+1]; gl.enable(gl.BLEND);"
     "                gl.blendFunc(m === 2 ? gl.ONE : gl.SRC_ALPHA,"
     "                             m === 1 ? gl.ONE"
     "                             : gl.ONE_MINUS_SRC_ALPHA); }"
     "              else gl.disable(gl.BLEND); p += 2; break;"
     "     case 11: gl.activeTexture(gl.TEXTURE0 + u[p]);"
     "              gl.bindTexture(gl.TEXTURE_2D, slots[u[p+1]]); p += 2; break;"
     "     case 12: gl.uniform1i(slots[u[p]], u[p+1]); p += 2; break;"
     "     case 13: gl.uniform2f(slots[u[p]], f[p+1], f[p+2]); p += 3; break;"
     "     case 14: gl.uniformMatrix4fv(slots[u[p]], false,"
     "                f.subarray(p + 1, p + 17)); p += 17; break;"
     "     case 15: if (u[p] === 1) gl.enable(gl.DEPTH_TEST);"
     "              else gl.disable(gl.DEPTH_TEST); p += 1; break;"
     "     case 16: gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, slots[u[p]]);"
     "              p += 1; break;"
     "     case 17: gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,"
     "               new Uint16Array(memory.buffer, u[p], u[p+1] >> 1),"
     "               gl.DYNAMIC_DRAW); p += 2; break;"
     "     case 18: { const m = u[p] === 0 ? gl.POINTS : u[p] === 1 ? gl.LINES"
     "                : u[p] === 5 ? gl.TRIANGLE_STRIP : gl.TRIANGLES;"
     "                gl.drawElements(m, u[p+1], gl.UNSIGNED_SHORT, 0);"
     "                p += 2; break; }"
     "     case 19: gl.uniform3f(slots[u[p]], f[p+1], f[p+2], f[p+3]);"
     "              p += 4; break;"
     "     default: throw new Error('bad gl opcode');"
     "    } } }; };"))

  (define $gl #f)                       ; the replayer handle
  (define $replay #f)

  (define (gl-attach! canvas)
    (js-eval replayer-src)
    (set! $gl (js-call (js-get (js-global) "__goeteia_gl") (js-undefined)
                       canvas (js-get (js-global) "__goeteia_mem")))
    (set! $replay (js-get $gl "replay"))
    $gl)

  ;; optional 4th argument: a comma-joined attribute-name string bound
  ;; to locations 0,1,... before linking (drivers don't otherwise
  ;; guarantee declaration order)
  (define (gl-program! slot vs fs . attribs)
    (if (null? attribs)
        (js-method $gl "program" slot vs fs)
        (js-method $gl "program" slot vs fs (car attribs))))
  (define (gl-buffer! slot) (js-method $gl "buffer" slot))
  (define (gl-uniform! slot pslot name) (js-method $gl "uniform" slot pslot name))
  ;; textures: created LINEAR/CLAMP_TO_EDGE; upload takes a JS canvas
  ;; or image and may be called again to refresh (atlas growth); pass
  ;; #t as the third argument to premultiply alpha on upload (image
  ;; sprites under (cmd-blend! 'premul))
  (define (gl-texture! slot) (js-method $gl "texture" slot))
  ;; premul crosses as 1/0: a boolean would convert through js-eval,
  ;; whose nested %js-call would swallow the args already pushed
  (define (gl-texture-upload! slot src . premul)
    (if (or (null? premul) (not (car premul)))
        (js-method $gl "textureUpload" slot src)
        (js-method $gl "textureUpload" slot src 1)))

  ;; ---- the encoder: words into the staging memory ----
  (define $base 0)
  (define $p 0)
  (define (cmd-region! base) (set! $base base))
  (define (cmd-begin!) (set! $p $base))
  (define (u! v) (%mem-i32-set! $p v) (set! $p (+ $p 4)))
  (define (f! v) (%mem-f32-set! $p v) (set! $p (+ $p 4)))

  (define (cmd-clear! r g b a) (u! 1) (f! r) (f! g) (f! b) (f! a))
  (define (cmd-use-program! slot) (u! 2) (u! slot))
  (define (cmd-bind-buffer! slot) (u! 3) (u! slot))
  (define (cmd-buffer-data! offset bytes) (u! 4) (u! offset) (u! bytes))
  (define (cmd-vertex-attrib! loc size stride offset)
    (u! 5) (u! loc) (u! size) (u! stride) (u! offset))
  (define (cmd-uniform1f! slot x) (u! 6) (u! slot) (f! x))
  (define (cmd-uniform4f! slot x y z w)
    (u! 7) (u! slot) (f! x) (f! y) (f! z) (f! w))
  (define (cmd-draw-arrays! mode first count)
    (u! 8) (u! mode) (u! first) (u! count))
  (define (cmd-bind-texture! unit slot) (u! 11) (u! unit) (u! slot))
  (define (cmd-uniform1i! slot v) (u! 12) (u! slot) (u! v))
  (define (cmd-uniform2f! slot x y) (u! 13) (u! slot) (f! x) (f! y))
  (define (cmd-uniform3f! slot x y z)
    (u! 19) (u! slot) (f! x) (f! y) (f! z))
  ;; m: a 16-element flonum vector, column-major ((web mat) makes them)
  (define (cmd-uniform-matrix4! slot m)
    (u! 14) (u! slot)
    (let loop ((i 0))
      (when (< i 16)
        (f! (vector-ref m i))
        (loop (+ i 1)))))
  (define (cmd-depth! on?) (u! 15) (u! (if on? 1 0)))
  ;; indexed meshes: a buffer slot bound as the element array, u16
  ;; indices uploaded from the staging memory, one drawElements
  (define (cmd-bind-index! slot) (u! 16) (u! slot))
  (define (cmd-index-data! offset bytes) (u! 17) (u! offset) (u! bytes))
  (define (cmd-draw-elements! mode count) (u! 18) (u! mode) (u! count))
  (define (cmd-pos) $p)                 ; for overflow checks by callers
  (define (cmd-viewport! x y w h) (u! 9) (u! x) (u! y) (u! w) (u! h))
  ;; blending for translucent draws: (cmd-blend! 'alpha) src-over,
  ;; (cmd-blend! 'add) additive glow, (cmd-blend! 'premul) src-over
  ;; for premultiplied textures, (cmd-blend! 'off) opaque
  (define (cmd-blend! mode)
    (u! 10)
    (case mode
      ((add)    (u! 1) (u! 1))
      ((alpha)  (u! 1) (u! 0))
      ((premul) (u! 1) (u! 2))
      (else     (u! 0) (u! 0))))

  ;; one bridge call replays the whole frame
  (define (cmd-flush!)
    (js-call $replay $gl $base $p)))
