;; expect: #t
;; What the scene graph puts in an index buffer, read back from the
;; upload itself.
;;
;; Two things are pinned here.  First, the VALUES: $sgl-weld shifts each
;; part's indices by the running vertex base, and it used to read the
;; source a WORD at a time and split the pair with remainder and
;; quotient.  A word whose high half reaches 8192 is 2^29 or more, past
;; this runtime's fixnum ceiling of 536870911, so the read wrapped -- for
;; a high half of 9000 and a low of 1234 the word comes back as
;; -483916590 and the halves as -7383 and -64302.  Each packed word was
;; decoded on its own, so what broke was every PAIR whose high half had
;; reached 8192 -- not everything after the first one.  For source
;; indices #(1234 9000 1 2) the first pair is wrong and the second,
;; 1 + 65536*2, is still inside the fixnum range and comes back fine.
;; Either way nothing said so.  The store side of the same
;; pairing was fixed in 101ade9; both ends are bytewise now.
;;
;; Second, the WIDTH.  The graph was u16 everywhere: a mesh past 65536
;; vertices was accepted in silence and drawn with UNSIGNED_SHORT, so
;; every index above the boundary named some other vertex.  The mesh
;; layer had carried u32 all along, and so had the command layer for
;; NON-instanced draws (cmd-index-data32!, cmd-draw-elements32!) -- the
;; instanced draw had no 32-bit form at all and hardcoded
;; UNSIGNED_SHORT, so `cmd-draw-elements-instanced32!` is new with this
;; change rather than merely wired up.  These check that a geometry is
;; uploaded and drawn at the width its vertex count calls for, down
;; both draw paths.
;;
;; Expected values are computed HERE, from mesh-indices and a vertex base
;; this file adds up, never by asking the weld what it wrote.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (web reactive) (gfx scene))

(js-eval "globalThis.__gllog = []; globalThis.__idx = []; globalThis.__draws = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', UNSIGNED_INT:'UI', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, UNIFORM_BUFFER:'UBUF', getUniformBlockIndex(pr,n){ return 'I:' + n }, uniformBlockBinding(pr,i,b){ push('ubb', pr.id, i, b) }, bindBufferBase(t,b,buf){ push('bbb', t, b, buf ? buf.id : 'null') }, bufferSubData(t,o,arr){ push('subData', t, arr.length) }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ if (t==='EAB' && typeof arr !== 'number') { globalThis.__idx.push({v:Array.from(arr), w:arr.BYTES_PER_ELEMENT}); } push('bufferData', typeof arr === 'number' ? 'size' + arr : arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[0].toFixed(2), arr[12].toFixed(2)) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, activeTexture(u){ push('activeTexture', u) }, bindTexture(t,tex){ push('bindTexture', tex ? tex.id : 'null') }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, texParameteri(){}, TEXTURE0:33984, TEXTURE_2D:'T2D', TEXTURE_CUBE_MAP:'TCM', drawArrays(m,f,c){ push('draw', m, f, c) }, drawElements(m,c,t,o){ globalThis.__draws.push({n:c, t:t, inst:0, m:m}); push('drawElements', m, c, t) }, depthMask(b){ push('depthMask', b?1:0) }, vertexAttribDivisor(l,d){ if (d > 0) push('divisor', l, d) }, drawElementsInstanced(m,c,t,o,n){ globalThis.__draws.push({n:c, t:t, inst:n, m:m}); push('drawInst', m, c, n) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define idx (js-get (js-global) "__idx"))
(define draws (js-get (js-global) "__draws"))
(define (uploads) (js->number (js-get idx "length")))
(define (upload-n i) (js->number (js-get (js-index idx i) "v")))
(define (upload-len i)
  (js->number (js-get (js-get (js-index idx i) "v") "length")))
;; -1 means "no such upload".  These answer 0 rather than reaching into
;; nothing: a missing upload should fail an assertion by name, not take
;; the whole file down with a JS TypeError and no message at all.
(define (upload-width i)
  (if (< i 0) 0 (js->number (js-get (js-index idx i) "w"))))
(define (upload-ref i k)
  (if (< i 0) -1 (js->number (js-index (js-get (js-index idx i) "v") k))))
(define (draw-count) (js->number (js-get draws "length")))
(define (draw-n i) (js->number (js-get (js-index draws i) "n")))
(define (draw-type i) (js->string (js-get (js-index draws i) "t")))
(define (draw-inst i) (js->number (js-get (js-index draws i) "inst")))
;; The primitive mode.  Recorded because the four draw calls (two
;; widths x instanced or not) each name it separately, and nothing used
;; to read it back: turning GL-TRIANGLES into GL-LINES in the wide
;; instanced branch alone left this file, test/scene.ss, test/gl.ss,
;; test/fx.ss and test/stats.ss all green while wide instanced meshes
;; drew as lines.  A draw call is four numbers and the tests were
;; checking three of them.
(define (draw-mode i) (js->string (js-get (js-index draws i) "m")))
;; The instance buffer is an ARRAY_BUFFER, so it never lands in __idx --
;; that one only records ELEMENT_ARRAY_BUFFER uploads.  Counting it needs
;; the raw log.  (An earlier version of part 9 asserted on `uploads`
;; instead and therefore could not fail: forcing a recompute on every
;; frame left it green, because the quantity it measured was not the one
;; the property is about.)
(define gllog (js-get (js-global) "__gllog"))
(define (log-length) (js->number (js-get gllog "length")))
(define (log-count-since from prefix)
  (let ((plen (string-length prefix)))
    (let loop ((i from) (c 0))
      (if (= i (log-length))
          c
          (let* ((e (js->string (js-index gllog i)))
                 (hit (and (>= (string-length e) plen)
                           (string=? prefix (substring e 0 plen)))))
            (loop (+ i 1) (if hit (+ c 1) c)))))))

(define (buffer-uploads-since from)
  (let loop ((i from) (c 0))
    (if (= i (log-length))
        c
        (let* ((e (js->string (js-index gllog i)))
               (hit (and (>= (string-length e) 10)
                         (string=? "bufferData" (substring e 0 10)))))
          (loop (+ i 1) (if hit (+ c 1) c))))))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))

(fx-init! (js-get (js-global) "__mockcanvas"))

(define (flat x z) 0.0)

;; the first upload at or after `from` whose element count is n, or -1
(define (upload-with from n)
  (let loop ((i from))
    (cond ((= i (uploads)) -1)
          ((= (upload-len i) n) i)
          (else (loop (+ i 1))))))

;; every welded index equals its source index plus that part's base.
;; `parts` is a list of (indices . vertex-count) in weld order.
(define (welded-matches? up parts)
  (let loop ((ps parts) (k 0) (v0 0) (bad -1))
    (if (or (null? ps) (>= bad 0))
        bad
        (let* ((ix (caar ps)) (n (cdar ps)) (m (vector-length ix)))
          (let scan ((j 0))
            (cond ((= j m) (loop (cdr ps) (+ k m) (+ v0 n) bad))
                  ((= (upload-ref up (+ k j)) (+ (vector-ref ix j) v0))
                   (scan (+ j 1)))
                  (else (loop '() (+ k m) v0 (+ k j)))))))))

(define (report-mismatch up parts at)
  (display "  first mismatch at ") (display at)
  (display ": buffer has ") (display (upload-ref up at))
  (newline))

;; ---- 1. the boundary the packed-word read fell over ------------------
;; A control and the first failing value, at ODD positions, in a part big
;; enough to carry them: 8191 must have worked all along, 8192 is where
;; the packed word passes 2^29.  Both halves of every pair are compared,
;; because a wrong odd half took the even half of the same word with it.

(define (indexed-part segs rings odd-value)
  (let* ((m (mesh-sphere 1.0 segs rings))
         (ix (mesh-indices m)))
    ;; positions 1 and 3 are odd, so they land in the high half of the
    ;; first two packed words
    (vector-set! ix 1 odd-value)
    (vector-set! ix 3 odd-value)
    m))

(define control (indexed-part 128 80 8191))
(define failing (indexed-part 128 80 8192))
(define tiny (mesh-sphere 1.0 8 4))

(check "the parts really carry the values this is about"
       (and (= 8191 (vector-ref (mesh-indices control) 1))
            (= 8192 (vector-ref (mesh-indices failing) 1))
            (> (mesh-vert-count control) 8192)))

(define (weld-two a b)
  (let ((before (uploads)))
    (let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                              (look-at 0.0 0.0 0.0)))
                   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                   (mesh (@ (geometry ,a) (color 1.0 0.0 0.0)))
                   (mesh (@ (geometry ,b)
                            (position 3.0 0.0 0.0) (color 1.0 0.0 0.0))))))
      (cmd-begin!) (sgl-draw! sc) (cmd-flush!))
    before))

(define (check-pair label a b)
  (let* ((before (weld-two a b))
         (total (+ (mesh-index-count a) (mesh-index-count b)))
         (up (upload-with before total)))
    (check (string-append label ": the pair welded into one upload") (>= up 0))
    (when (>= up 0)
      (check (string-append label ": the welded buffer is u16")
             (= 2 (upload-width up)))
      (let ((bad (welded-matches?
                  up (list (cons (mesh-indices a) (mesh-vert-count a))
                           (cons (mesh-indices b) (mesh-vert-count b))))))
        (check (string-append label ": every index is source plus base")
               (< bad 0))
        (when (>= bad 0) (report-mismatch up '() bad))))))

;; the failing value FIRST, and then behind another part -- an odd half
;; is wrong wherever it sits, but only the second case exercises a
;; non-zero vertex base on top of it
(check-pair "control 8191, first" control tiny)
(check-pair "failing 8192, first" failing tiny)
(check-pair "failing 8192, second" tiny failing)

;; ---- 2. one draw, of the right kind ----------------------------------

(define draws-before (draw-count))
(define big (mesh-sphere 1.0 128 80))
(define up-before (uploads))
(weld-two big tiny)

(check "a welded pair draws exactly once, not instanced"
       (and (= 1 (- (draw-count) draws-before))
            (= 0 (draw-inst draws-before))
            (string=? "TRI" (draw-mode draws-before))))
(check "and it draws as many indices as the two sources have"
       (= (draw-n draws-before)
          (+ (mesh-index-count big) (mesh-index-count tiny))))
(check "with UNSIGNED_SHORT, the width this pair calls for"
       (string=? "US" (draw-type draws-before)))

;; ---- 3. the width rule, at its boundary ------------------------------
;; A u16 index names 0..65535, so 65536 vertices still fit and 65537 do
;; not.  The single-mesh case sits exactly on it.

(define at-boundary (mesh-heightmap 1.0 1.0 255 255 flat))   ; 65536
(define under (mesh-heightmap 1.0 1.0 254 256 flat))         ; 65535
(define over (mesh-heightmap 1.0 1.0 300 220 flat))          ; 66521

(check "the three meshes sit where this test needs them"
       (and (= 65536 (mesh-vert-count at-boundary))
            (= 65535 (mesh-vert-count under))
            (> (mesh-vert-count over) 65536)))
(define just-over (mesh-heightmap 1.0 1.0 0 65536 flat))     ; 65537

;; ONE past the boundary, not a thousand.  `over` is 66521 vertices,
;; so moving the threshold from "> 65536" to "> 65537" left every row
;; here green -- measured -- while a mesh of exactly 65537 vertices
;; would have been indexed as u16, whose largest index is 65535.  That
;; is silent corruption, and the fixture that was supposed to guard
;; against it sat 985 vertices away from the edge.
(check "and the mesh layer draws the line in the same place"
       (and (not (mesh-index-u32? at-boundary))
            (not (mesh-index-u32? under))
            (= 65537 (mesh-vert-count just-over))
            (mesh-index-u32? just-over)
            (mesh-index-u32? over)))

(define (draw-one m)
  (let ((d (draw-count)) (u (uploads)))
    (let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                              (look-at 0.0 0.0 0.0)))
                   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                   (mesh (@ (geometry ,m) (color 1.0 0.0 0.0))))))
      (cmd-begin!) (sgl-draw! sc) (cmd-flush!))
    (cons d u)))

(define b1 (draw-one at-boundary))
(check "exactly 65536 vertices still go out as u16"
       (and (string=? "US" (draw-type (car b1)))
            (string=? "TRI" (draw-mode (car b1)))
            (= 2 (upload-width (upload-with (cdr b1)
                                            (mesh-index-count at-boundary))))))
(check "...and its largest index is exactly 65535"
       (let* ((up (upload-with (cdr b1) (mesh-index-count at-boundary)))
              (ix (mesh-indices at-boundary)))
         (let loop ((k 0) (best 0))
           (if (= k (vector-length ix))
               (= best 65535)
               (loop (+ k 1) (max best (upload-ref up k)))))))

(define b2 (draw-one over))
(check "past the boundary the draw asks for UNSIGNED_INT"
       (string=? "UI" (draw-type (car b2))))
;; Mode on the NON-instanced wide path too.  It was asserted only on the
;; narrow and the instanced draws, so `(cmd-draw-elements32! GL-LINES
;; ...)` -- the one branch nothing else in the file reaches -- drew wide
;; meshes as lines through the whole suite.  Four draw calls, and the
;; mode has to be read back on each of the four.
(check "...and it is still a triangle mesh"
       (string=? "TRI" (draw-mode (car b2))))
(check "and the index buffer goes up four bytes wide"
       (= 4 (upload-width (upload-with (cdr b2) (mesh-index-count over)))))

;; the values, not just the width: a u32 index buffer that had been
;; truncated to u16 would still be four bytes wide
(check "every u32 index arrives as the mesh wrote it"
       (let* ((up (upload-with (cdr b2) (mesh-index-count over)))
              (ix (mesh-indices over))
              (n (vector-length ix)))
         ;; the whole buffer is 396000 entries; compare the ones that
         ;; carry the property -- the first and last runs, and every
         ;; entry naming a vertex past the u16 boundary
         (let loop ((k 0) (ok #t))
           (cond ((not ok) #f)
                 ((= k n) #t)
                 ((or (< k 64) (> k (- n 64))
                      (> (vector-ref ix k) 65535))
                  (loop (+ k 1) (= (upload-ref up k) (vector-ref ix k))))
                 (else (loop (+ k 1) ok))))))


;; ---- 4. the same boundary, on the welded side ------------------------
;; The welded output's width follows the TOTAL, not any one part.  Two
;; halves that are each comfortably u16 can add up past the boundary, and
;; before the width followed the total the sum was written u16 anyway --
;; every index above 65535 truncated to its low two bytes, silently.

(define half-a (mesh-heightmap 1.0 1.0 127 255 flat))   ; 32768
(define half-b (mesh-heightmap 1.0 1.0 127 255 flat))   ; 32768
(define speck (mesh-plane 1.0 1.0))                     ; 4

(check "two halves that are each u16 and together sit on the boundary"
       (and (= 32768 (mesh-vert-count half-a))
            (= 32768 (mesh-vert-count half-b))
            (= 65536 (+ (mesh-vert-count half-a) (mesh-vert-count half-b)))))

(define (weld-three a b c)
  (let ((before (uploads)) (d (draw-count)))
    (let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                              (look-at 0.0 0.0 0.0)))
                   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                   (mesh (@ (geometry ,a) (color 0.0 1.0 0.0)))
                   (mesh (@ (geometry ,b)
                            (position 3.0 0.0 0.0) (color 0.0 1.0 0.0)))
                   (mesh (@ (geometry ,c)
                            (position 6.0 0.0 0.0) (color 0.0 1.0 0.0))))))
      (cmd-begin!) (sgl-draw! sc) (cmd-flush!))
    (cons before d)))

;; First the pair alone: 32768 + 32768 = 65536 exactly, which a u16
;; index still names, so the welded output must stay two bytes wide.
;; Without this case the boundary is only pinned on the mesh layer's
;; side, and moving the weld's own test from `>` to `>=` -- widening
;; everything at exactly 65536 -- passed every other assertion here.
(define w2-before (uploads))
(define w2-draw (draw-count))
(weld-two half-a half-b)
(define w2-total (+ (mesh-index-count half-a) (mesh-index-count half-b)))
(define w2-up (upload-with w2-before w2-total))

(check "a welded total of exactly 65536 stays u16"
       (and (>= w2-up 0) (= 2 (upload-width w2-up))))
(check "...and draws as UNSIGNED_SHORT"
       (and (string=? "US" (draw-type w2-draw))
            (string=? "TRI" (draw-mode w2-draw))))
(check "...with 65535 as its largest index, the most a u16 can name"
       (and (>= w2-up 0)
            (let loop ((k 0) (best 0))
              (if (= k w2-total)
                  (= best 65535)
                  (loop (+ k 1) (max best (upload-ref w2-up k)))))))
(when (>= w2-up 0)
  (let ((bad (welded-matches?
              w2-up
              (list (cons (mesh-indices half-a) (mesh-vert-count half-a))
                    (cons (mesh-indices half-b) (mesh-vert-count half-b))))))
    (check "...and every index of it is source plus base" (< bad 0))
    (when (>= bad 0) (report-mismatch w2-up '() bad))))

;; 32768 + 32768 + 4 = 65540 vertices.  A u16 index names 0..65535, so
;; 65536 vertices are the most it can address and this is FOUR past
;; that, not one -- "one past" would be 65537, which is the case the
;; single-mesh width rule above pins.  The rule here is > 65536.
(define w3 (weld-three half-a half-b speck))
(define w3-total (+ (mesh-index-count half-a) (mesh-index-count half-b)
                    (mesh-index-count speck)))
(define w3-up (upload-with (car w3) w3-total))

(check "the three welded into one upload" (>= w3-up 0))
(check "a welded total past the boundary goes out u32"
       (and (>= w3-up 0) (= 4 (upload-width w3-up))))
(check "and its draw asks for UNSIGNED_INT"
       (and (string=? "UI" (draw-type (cdr w3)))
            (string=? "TRI" (draw-mode (cdr w3)))))
(when (>= w3-up 0)
  (let ((bad (welded-matches?
              w3-up
              (list (cons (mesh-indices half-a) (mesh-vert-count half-a))
                    (cons (mesh-indices half-b) (mesh-vert-count half-b))
                    (cons (mesh-indices speck) (mesh-vert-count speck))))))
    (check "every welded index is source plus base, past 65535 included"
           (< bad 0))
    (when (>= bad 0) (report-mismatch w3-up '() bad))))

;; the point of the width rule: indices above what a u16 can name really
;; are in there, so a u16 output would have had to truncate them
(check "the welded buffer really does name vertices past 65535"
       (and (>= w3-up 0)
            (let loop ((k 0))
              (cond ((= k w3-total) #f)
                    ((> (upload-ref w3-up k) 65535) #t)
                    (else (loop (+ k 1)))))))

;; ---- 5. sources of different widths in one group ---------------------
;; A u32 part and a u16 part weld together.  Each source is read at the
;; width it was written -- the u32 one four bytes at a time, the u16 one
;; two -- and both go out at the group's width.  Reading either at the
;; other's stride puts every index of that part somewhere else.

(define wide (mesh-heightmap 1.0 1.0 300 220 flat))     ; 66521, u32
(define narrow (mesh-sphere 1.0 8 4))                   ; 45, u16

(check "the group really is mixed-width"
       (and (mesh-index-u32? wide) (not (mesh-index-u32? narrow))))

(define mixed-before (uploads))
(define mixed-draw (draw-count))
(weld-two wide narrow)
(define mixed-total (+ (mesh-index-count wide) (mesh-index-count narrow)))
(define mixed-up (upload-with mixed-before mixed-total))

(check "a mixed-width group welds" (>= mixed-up 0))
(check "the welded output takes the wider width"
       (and (>= mixed-up 0) (= 4 (upload-width mixed-up))))
(when (>= mixed-up 0)
  (let ((bad (welded-matches?
              mixed-up
              (list (cons (mesh-indices wide) (mesh-vert-count wide))
                    (cons (mesh-indices narrow) (mesh-vert-count narrow))))))
    (check "each part is read at its own width and shifted correctly"
           (< bad 0))
    (when (>= bad 0) (report-mismatch mixed-up '() bad))))


;; ---- 6. the textured writer path, at the same width ------------------
;; A textured node writes its vertices through mesh-write-uv! instead of
;; mesh-write!, and never welds -- textured nodes are a separate group.
;; The index buffer is the same buffer either way, so the width has to
;; follow the same rule down that path too; asserting it on the lit path
;; alone would leave half the writers unchecked.

(define tex-slot (fx-texture!))
(define tex-draw (draw-count))
(define tex-up (uploads))
(let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                          (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (mesh (@ (geometry ,over) (texture ,tex-slot))))))
  (cmd-begin!) (sgl-draw! sc) (cmd-flush!))

(check "a textured u32 mesh draws as UNSIGNED_INT too"
       (string=? "UI" (draw-type tex-draw)))
(check "and its index buffer is four bytes wide"
       (= 4 (upload-width (upload-with tex-up (mesh-index-count over)))))


;; ---- 7. the other order of a mixed-width group -----------------------
;; The u32 part was always FIRST, so a read that only consulted the
;; width for the leading part -- (and (= i0 0) (geo-u32? ...)) -- passed
;; everything above.  Which side of the group a part sits on is its own
;; dimension, exactly as it was for the 8192 boundary earlier in this
;; file, and testing one order is testing half of it.

(define rev-before (uploads))
(weld-two narrow wide)
(define rev-total (+ (mesh-index-count narrow) (mesh-index-count wide)))
(define rev-up (upload-with rev-before rev-total))

(check "a mixed-width group welds with the u32 part second" (>= rev-up 0))
(when (>= rev-up 0)
  (let ((bad (welded-matches?
              rev-up
              (list (cons (mesh-indices narrow) (mesh-vert-count narrow))
                    (cons (mesh-indices wide) (mesh-vert-count wide))))))
    (check "...and the trailing u32 part is still read four bytes at a time"
           (< bad 0))
    (when (>= bad 0) (report-mismatch rev-up '() bad))))

;; ---- 7b. the third material group, PBR -----------------------------
;; A scene sorts its meshes into three groups -- lit, textured, pbr --
;; and each one draws through its own pass.  Part 6 makes the argument
;; for the textured pass ("asserting the width on the lit path alone
;; would leave half the writers unchecked") and then stops at two of
;; three: no case in THIS file built a pbr node, so the INDEX WIDTH was
;; pinned on two passes and assumed on the third.
;;
;; Only the width.  test/scene.ss has built a pbr node all along and
;; asserts u_metallic and u_roughness on it -- measured: deleting the
;; u_metallic send turns that file red.  An earlier version of this
;; comment said the pbr branch was reachable by nothing at all, which
;; came from taking a review finding's "this mutation survives every
;; pinned scene assertion" at face value: the mutation was run against
;; this file only, and the half of the claim that was about the OTHER
;; files was never checked.  A claim that nothing else covers something
;; is a claim about the whole suite, and checking it means running the
;; whole suite.
;;
;; A pbr mesh is spelled by giving it metallic/roughness, and it needs a
;; probe in the scene; the geometry here is past 65536 vertices so the
;; width question is asked down this pass too.
(define pbr-sky (fx-texture!))
(define pbr-lut (fx-texture!))
(define pbr-draw (draw-count))
(define pbr-up (uploads))
(define pbr-log (log-length))
(let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                          (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (probe (@ (sky ,pbr-sky) (lut ,pbr-lut) (mips 5)))
               (mesh (@ (geometry ,wide) (metallic 1.0) (roughness 0.3))))))
  (cmd-begin!) (sgl-draw! sc) (cmd-flush!))

(check "a pbr node draws"
       (> (draw-count) pbr-draw))
(check "a wide pbr geometry asks for UNSIGNED_INT, like the other two passes"
       (string=? "UI" (draw-type pbr-draw)))
(check "...as triangles"
       (string=? "TRI" (draw-mode pbr-draw)))
(check "...and its index buffer went up four bytes wide"
       (= 4 (upload-width (upload-with pbr-up (mesh-index-count wide)))))
;; and the uniforms that only this material sends.  Counting them is
;; what makes the branch's disappearance visible: u_color goes out for
;; lit and textured nodes, u_albedo/u_metallic/u_roughness only here.
(check "a pbr draw sends the pbr uniforms, not the lit one"
       (and (= 1 (log-count-since pbr-log "uniform4f:U:u_albedo"))
            (= 1 (log-count-since pbr-log "uniform1f:U:u_metallic"))
            (= 1 (log-count-since pbr-log "uniform1f:U:u_roughness"))
            (= 0 (log-count-since pbr-log "uniform4f:U:u_color"))))

;; ---- 7c. a mirrored mesh is still inside the frustum ---------------
;; A radius has no sign and a scale does.  The culling bound used to be
;; the node's bound times its scale PRODUCT, so `(scale -10.0)` gave a
;; radius of -17.3, and the frustum test -- which asks whether the
;; centre is within r of each plane -- then demanded the centre be 17.3
;; INSIDE every plane.  A mirrored mesh vanished.  Mirroring by a
;; negative scale is an ordinary thing to do, and nothing anywhere drew
;; a node with one.
;;
;; The three magnitudes matter: at -1.0 the mesh still draws (the
;; camera is far enough that even a demand of 1.7 is met), which is why
;; a small negative scale is not a test.  The case has to be one where
;; the wrong sign changes the answer.
(define (draws-of sc)
  (let ((b (draw-count)))
    (cmd-begin!) (sgl-draw! sc) (cmd-flush!)
    (- (draw-count) b)))
(define (scaled-box k)
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 2 2 2)) (color 1.0 0.0 0.0) (scale ,k)))))
(check "a mesh scaled +10 draws" (= 1 (draws-of (scaled-box 10.0))))
(check "and so does the same mesh scaled -10"
       (= 1 (draws-of (scaled-box -10.0))))
(check "...and -1.0, which would pass even with the sign bug"
       (= 1 (draws-of (scaled-box -1.0))))

;; ---- 7d. what an instance group's cache key has to cover ----------
;; The group redraws from cache when "nothing moved", and what it means
;; by that is the sum of the nodes' TRANSFORM generations.  The buffer
;; it is reusing holds more than transforms: it holds the per-instance
;; RGBA too.  A colour hole deliberately does not bump the transform
;; generation -- colour does not move the model matrix and bumping it
;; would rebuild one for nothing -- so a signal-driven colour changed,
;; the key did not, and the group redrew last frame's colours forever.
;;
;; Of the eleven per-instance dynamic fields (seven transform, four
;; colour) the cases above drive the seven; these drive the four.
(define (colour-hole-frames make-scene change!)
  (let ((sc (make-scene)))
    (cmd-begin!) (sgl-draw! sc) (cmd-flush!)
    (let ((before (log-length)))
      (change!)
      (cmd-begin!) (sgl-draw! sc) (cmd-flush!)
      (buffer-uploads-since before))))

(define cr (signal 1.0))
(define cg (signal 1.0))
(define cb (signal 1.0))
(define ca (signal 1.0))
(check "a changed instance colour repacks the group (r)"
       (> (colour-hole-frames
           (lambda ()
             (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
                  (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                  (mesh (@ (geometry (sphere 1.0 8 4)) (color-r ,(signal-ref cr))))
                  (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)))))
           (lambda () (signal-set! cr 0.25)))
          0))
(check "...and g, b, a, which are separate holes"
       (and (> (colour-hole-frames
                (lambda ()
                  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
                       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                       (mesh (@ (geometry (sphere 1.0 8 4)) (color-g ,(signal-ref cg))))
                       (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)))))
                (lambda () (signal-set! cg 0.25))) 0)
            (> (colour-hole-frames
                (lambda ()
                  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
                       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                       (mesh (@ (geometry (sphere 1.0 8 4)) (color-b ,(signal-ref cb))))
                       (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)))))
                (lambda () (signal-set! cb 0.25))) 0)
            ;; ...and NOT alpha.  It used to be asserted here, with the
            ;; same "the instance buffer was repacked" question as the
            ;; other three, and that question is wrong for it: a node
            ;; whose alpha can move is kept OUT of the instance group
            ;; entirely, because the group's pass is fixed when the
            ;; scene is built and that pass never blends.  So there is
            ;; no instance buffer to repack, and asserting there is one
            ;; would pin the defect rather than the fix.  Alpha's own
            ;; property -- the pass changes with it -- is 7d-1b below.
            #t))

;; ---- 7d-1b. alpha is not just another colour channel ---------------
;; The case above drives `color-a` through a signal and asserts that the
;; instance buffer was repacked.  It was -- and that is not enough: the
;; PASS a node draws in is decided when the scene is built, from the
;; alpha it had then.  A node that starts opaque is put in the opaque
;; instanced group and stays there; the new alpha rides along in the
;; buffer while blending is never turned on and depth writes are never
;; turned off.  So it fades in the numbers and not on the screen.
;;
;; Three of the four colour channels really are interchangeable.  The
;; fourth chooses a render pass, and the case above treated it as the
;; other three -- it asserted the thing all four share and stopped
;; before the thing only alpha does.
(define a-sig (signal 1.0))
(define a-scene
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (sphere 1.0 8 4)) (color-a ,(signal-ref a-sig))))
       (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)))))
(begin (cmd-begin!) (sgl-draw! a-scene) (cmd-flush!))
(define a-mark (log-length))
(signal-set! a-sig 0.25)
(begin (cmd-begin!) (sgl-draw! a-scene) (cmd-flush!))
(check "a node whose alpha drops starts blending"
       (> (log-count-since a-mark "gEnable:BL") 0))
(check "...and stops writing depth"
       (> (log-count-since a-mark "depthMask:0") 0))
;; the should-GREEN half: alpha that stays at 1.0 must not cost the
;; opaque pass anything -- "move everything to the blended pass" also
;; satisfies the two checks above
(define b-sig (signal 1.0))
(define b-scene
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (sphere 1.0 8 4)) (color-a ,(signal-ref b-sig))))
       (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)))))
(begin (cmd-begin!) (sgl-draw! b-scene) (cmd-flush!))
(define b-mark (log-length))
(signal-set! b-sig 1.0)
(begin (cmd-begin!) (sgl-draw! b-scene) (cmd-flush!))
(check "an alpha that stays at 1.0 does not turn blending on"
       (= 0 (log-count-since b-mark "gEnable:BL")))
;; ...and the other should-green half, which the one above does NOT
;; cover: a LITERAL opaque alpha must still be instanced.  The case
;; above uses a signal, so it is excluded either way -- measured:
;; making every `color-a` node non-groupable left it green.  The
;; question "did the fix go too far" can only be asked by a node the
;; fix is not supposed to touch.
(define c-draw (draw-count))
(begin
  (cmd-begin!)
  (sgl-draw! (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                             (look-at 0.0 0.0 0.0)))
                  (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                  (mesh (@ (geometry (sphere 1.0 8 4)) (color-a 1.0)))
                  (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)
                           (color-a 1.0)))))
  (cmd-flush!))
(check "a literal opaque alpha is still instanced"
       (= 2 (draw-inst c-draw)))

;; ---- 7d-2. a reactive colour survives WELDING too ------------------
;; The colour generation was added to the instance group's cache key and
;; nowhere else.  Welding asks a different question -- "is this node
;; static?" -- and answered it from the TRANSFORM generation alone, so a
;; mesh whose colour is signal-driven counted as static, got baked into
;; a welded geometry with its colour of the moment, and the node the
;; effect keeps updating was thrown away.  The colour never changed
;; again.
;;
;; The cases above cannot reach it: they use two IDENTICAL sphere
;; specs, so instancing takes the nodes before the weld ever sees them.
;; This one uses two DIFFERENT shapes, which is exactly what welding is
;; for -- one rule, two consumers, and the fix had gone into one.
(define wc-log (log-length))
(define wc-red (signal 0.8))
(define wc-scene
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (sphere 1.0 8 4)) (position -1.5 0.0 0.0)
                (color-r ,(signal-ref wc-red))))
       (mesh (@ (geometry (box 1.0 1.0 1.0)) (position 1.5 0.0 0.0)))))
(begin (cmd-begin!) (sgl-draw! wc-scene) (cmd-flush!))
(define wc-after-1 (log-length))
(signal-set! wc-red 0.2)
(begin (cmd-begin!) (sgl-draw! wc-scene) (cmd-flush!))
(check "a signal-driven colour still moves when the mesh could be welded"
       (> (log-count-since wc-after-1 "uniform4f:U:u_color:0.2") 0))
(check "...and the first frame really did send the old value"
       (> (log-count-since wc-log "uniform4f:U:u_color:0.8") 0))

;; ---- 7d-3. the other three ways a colour reaches the GPU ----------
;; WHICH PATHS THESE CASES WALK, written down because the last two
;; defects were both "the fix went into one consumer of five".  A
;; colour reaches a draw by five routes, and they are chosen by the
;; INPUT, not by anything the caller says:
;;
;;   1  instanced group   two nodes share a literal geometry   7d
;;   2  welded            static lit singles, different shapes 7d-2
;;   3  plain single lit  a lone lit node                      here
;;   4  textured          the node has a texture               here
;;   5  pbr               the node has metallic/roughness      here
;;
;; 1 and 2 each had the defect; 3, 4 and 5 are correct today and were
;; unguarded, which is the same position 2 was in an hour ago. Counting
;; the routes is what makes that sentence writable -- "I tested the
;; colour" cannot be checked, "I tested five of five routes" can.
(define (colour-moves? make bump want)
  (let ((sc (make)))
    (cmd-begin!) (sgl-draw! sc) (cmd-flush!)
    (let ((a (log-length)))
      (bump)
      (cmd-begin!) (sgl-draw! sc) (cmd-flush!)
      (> (log-count-since a want) 0))))

(define p3-tex (fx-texture!))
(define p3-sky (fx-texture!))
(define p3-lut (fx-texture!))
(define p3-r (signal 0.8))
(check "a lone lit node's signal colour moves"
       (colour-moves?
        (lambda ()
          (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (mesh (@ (geometry (sphere 1.0 8 4)) (color-r ,(signal-ref p3-r))))))
        (lambda () (signal-set! p3-r 0.2))
        "uniform4f:U:u_color:0.2"))
(define p4-r (signal 0.8))
(check "a textured node's signal colour moves"
       (colour-moves?
        (lambda ()
          (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (mesh (@ (geometry (sphere 1.0 8 4)) (texture ,p3-tex)
                        (color-r ,(signal-ref p4-r))))))
        (lambda () (signal-set! p4-r 0.2))
        "uniform4f:U:u_color:0.2"))
(define p5-r (signal 0.8))
(check "a pbr node's signal albedo moves"
       (colour-moves?
        (lambda ()
          (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (probe (@ (sky ,p3-sky) (lut ,p3-lut) (mips 5)))
               (mesh (@ (geometry (sphere 1.0 8 4)) (metallic 1.0) (roughness 0.3)
                        (color-r ,(signal-ref p5-r))))))
        (lambda () (signal-set! p5-r 0.2))
        "uniform4f:U:u_albedo:0.2"))

;; ---- 7e. sharing a geometry must not make a mesh opaque ------------
;; Instancing groups by geometry identity alone, and the translucent
;; partition happens later -- so two translucent meshes that happen to
;; share a literal spec took the instanced pass, which never turns
;; blending on.  The user-visible rule was "adding a second identical
;; mesh makes the first one opaque", which nobody could guess.
(define (blend-of make-scene)
  (let ((before (log-length)))
    (cmd-begin!) (sgl-draw! (make-scene)) (cmd-flush!)
    (log-count-since before "gEnable:BL")))
(check "one translucent mesh blends"
       (= 1 (blend-of (lambda ()
              (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
                   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                   (mesh (@ (geometry (sphere 1.0 8 4)) (color 1.0 0.0 0.0 0.5))))))))
(check "and two of them sharing one geometry still blend"
       (= 1 (blend-of (lambda ()
              (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
                   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                   (mesh (@ (geometry (sphere 1.0 8 4)) (color 1.0 0.0 0.0 0.5)))
                   (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)
                            (color 1.0 0.0 0.0 0.5))))))))
(check "an opaque pair sharing one geometry is still instanced"
       (let ((d (draw-count)))
         (cmd-begin!)
         (sgl-draw! (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                                    (look-at 0.0 0.0 0.0)))
                         (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                         (mesh (@ (geometry (sphere 1.0 8 4)) (color 1.0 0.0 0.0)))
                         (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)
                                  (color 1.0 0.0 0.0)))))
         (cmd-flush!)
         (= 2 (draw-inst d))))

;; ---- 7f. which attributes take a signal, and which say so ----------
;; The manual said "each unquoted attribute becomes a hole".  It is true
;; of the per-component spellings and of nothing else: the expander only
;; builds a hole for an attribute with ONE value, so in
;; `(position 1.0 ,sig 0.0)` the unquote is simply evaluated and the
;; signal object goes straight to $sgl-fl -- an illegal cast, which is
;; not an error a caller can guard but a stop.  Users were being told to
;; write it.
;;
;; One case per MECHANISM, not per attribute: the eight three-argument
;; spellings share one helper, so one of them covers the class.  `color`
;; gets its own pair -- its fourth component has a second path of its
;; own, and that is exactly the path the last fix went in without.
(define (refuses? thunk) (guard (e (#t #t)) (thunk) #f))
(define (builds? thunk) (guard (e (#t #f)) (thunk) #t))
(check "a three-argument spelling refuses a signal, by name"
       (refuses? (lambda ()
         (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
              (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
              (mesh (@ (geometry (sphere 1.0 8 4))
                       (position 1.0 ,(signal-ref cr) 0.0)))))))
(check "...and the four-argument colour's alpha does too"
       (refuses? (lambda ()
         (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
              (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
              (mesh (@ (geometry (sphere 1.0 8 4))
                       (color 1.0 0.0 0.0 ,(signal-ref cr))))))))
(check "...and a lod switch distance"
       (refuses? (lambda ()
         (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
              (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
              (lod (@ (switch ,(signal-ref cr)))
                   (mesh (@ (geometry (sphere 1.0 8 4))))
                   (mesh (@ (geometry (box 1 1 1)))))))))
;; the should-GREEN half, with the inputs the refusal must not touch:
;; literals everywhere, and the documented `,mesh` injection -- which
;; IS a hole and must keep working.  (Refusing it was the first version
;; of this fix, and test/scene.ss alone did not notice: the file that
;; uses `,mesh` is this one.)
(check "literal numbers still build"
       (builds? (lambda ()
         (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
              (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
              (lod (@ (switch 5.0))
                   (mesh (@ (geometry (sphere 1.0 8 4)) (position 1.0 2.0 0.0)
                            (color 1.0 0.0 0.0 0.5)))
                   (mesh (@ (geometry (box 1 1 1)))))))))
(check "and (geometry ,mesh), which is a hole and is documented"
       (builds? (lambda ()
         (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
              (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
              (mesh (@ (geometry ,(mesh-sphere 1.0 8 4))))))))

;; ---- 7g. an instance group's key must cover LOD membership ---------
;; Third time for this shape: the group redraws from cache when
;; "nothing moved", and what it counts as moving is the camera plus its
;; members' transform and colour generations.  WHICH members are drawn
;; is a fourth thing -- a level of a lod is packed only while it is the
;; active one -- and it can change while all three of those stand still,
;; because the level that becomes active may itself be static.
;;
;; The scene below has a lod whose far level is a box, and a plain box
;; elsewhere: the two share a geometry, so they form an instance group.
;; While the near level is active the group holds one instance.  Moving
;; the lod's probe past the switch makes the far box active -- and its
;; position is a literal, so no generation moved, so the group replayed
;; its one-instance count and THE OBJECT DISAPPEARED.
(define lod-z (signal 0.0))
(define lod-scene
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)
                  (far 100.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (lod (@ (switch 15.0))
            (mesh (@ (geometry (sphere 1.0 10 5))
                     (position-z ,(signal-ref lod-z))))
            (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 -40.0))))
       (mesh (@ (geometry (box 1 1 1)) (position 3.0 0.0 0.0)))))
(begin (cmd-begin!) (sgl-draw! lod-scene) (cmd-flush!))
(define lod-near (draw-count))
(check "with the near level active the box group holds one instance"
       (= 1 (draw-inst (- lod-near 2))))
(signal-set! lod-z -40.0)
(begin (cmd-begin!) (sgl-draw! lod-scene) (cmd-flush!))
(check "when the far level becomes active it joins the group"
       (= 2 (draw-inst lod-near)))
;; the should-GREEN half: a scene with no lod at all must still take the
;; cached path -- "recompute every frame" also satisfies the check above
(define nolod-a (log-length))
(define nolod-scene
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1))))
       (mesh (@ (geometry (box 1 1 1)) (position 3.0 0.0 0.0)))))
(begin (cmd-begin!) (sgl-draw! nolod-scene) (cmd-flush!))
(define nolod-b (log-length))
(begin (cmd-begin!) (sgl-draw! nolod-scene) (cmd-flush!))
(check "an unchanged scene with no lod still redraws from cache"
       (= 0 (buffer-uploads-since nolod-b)))
;; ...and the should-green case that is actually inside the fix's reach:
;; a scene WITH a lod that does not change level must still take the
;; cached path.  The one above cannot see the difference -- it has no
;; lod, so the cell is never touched either way -- and bumping the
;; generation every frame instead of only on a change left it green.
;; A should-green case has to use an input the change can touch.
(define still-lod
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)
                  (far 100.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (lod (@ (switch 15.0))
            (mesh (@ (geometry (sphere 1.0 10 5))))
            (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 -40.0))))
       (mesh (@ (geometry (box 1 1 1)) (position 3.0 0.0 0.0)))))
(begin (cmd-begin!) (sgl-draw! still-lod) (cmd-flush!))
(define still-mark (log-length))
(begin (cmd-begin!) (sgl-draw! still-lod) (cmd-flush!))
(check "a lod that does not switch keeps its cached instance set"
       (= 0 (buffer-uploads-since still-mark)))

;; ---- 7h. the blended pass sorts by DEPTH, not by distance ----------
;; Back-to-front means farthest along the view direction first.  The key
;; was the squared distance from the eye, and those two agree only while
;; everything sits on the camera's axis -- which is exactly what the one
;; existing ordering case does, so the two answers were never allowed to
;; differ.
;;
;; Here they differ on purpose: the red sphere is NEARER in depth
;; (z = -5 against -6) and FARTHER in radial distance (4² + 5² = 41
;; against 36), so a distance sort draws it first and a depth sort draws
;; it second.  Only the second is back-to-front.  The two spheres carry
;; different segment counts so the log can tell them apart.
(define near-idx (mesh-index-count (mesh-sphere 1.0 8 4)))
(define far-idx (mesh-index-count (mesh-sphere 1.0 10 5)))
(define blend-a (draw-count))
(begin
  (cmd-begin!)
  (sgl-draw!
   (sgl (camera (@ (fov 0.9) (position 0.0 0.0 0.0) (look-at 0.0 0.0 -1.0)
                   (far 100.0)))
        (light (@ (direction 0.0 1.0 0.0) (ambient 1.0)))
        (mesh (@ (geometry (sphere 1.0 8 4)) (position 4.0 0.0 -5.0)
                 (color 1.0 0.0 0.0 0.5)))
        (mesh (@ (geometry (sphere 1.0 10 5)) (position 0.0 0.0 -6.0)
                 (color 0.0 0.0 1.0 0.5)))))
  (cmd-flush!))
(check "the deeper translucent node draws first, however far off-axis"
       (and (= 2 (- (draw-count) blend-a))
            (= far-idx (draw-n blend-a))
            (= near-idx (draw-n (+ blend-a 1)))))
;; the should-GREEN half, inside the same code: two translucent nodes ON
;; the axis must still come out far-first.  A "sort the other way" fix
;; passes the case above and fails this one.
(define axis-a (draw-count))
(begin
  (cmd-begin!)
  (sgl-draw!
   (sgl (camera (@ (fov 0.9) (position 0.0 0.0 0.0) (look-at 0.0 0.0 -1.0)
                   (far 100.0)))
        (light (@ (direction 0.0 1.0 0.0) (ambient 1.0)))
        (mesh (@ (geometry (sphere 1.0 8 4)) (position 0.0 0.0 -5.0)
                 (color 1.0 0.0 0.0 0.5)))
        (mesh (@ (geometry (sphere 1.0 10 5)) (position 0.0 0.0 -9.0)
                 (color 0.0 0.0 1.0 0.5)))))
  (cmd-flush!))
(check "...and on-axis ordering is unchanged"
       (and (= far-idx (draw-n axis-a))
            (= near-idx (draw-n (+ axis-a 1)))))

;; ---- 7i. a camera may look straight down ---------------------------
;; The view basis is built with a fixed up vector of (0,1,0), and a
;; camera looking along Y makes `cross(up, eye - target)` the zero
;; vector; normalizing it gives NaN, and every entry of the MVP that
;; touches it follows.  The draw call still goes out -- nothing errors
;; -- and the mesh simply does not appear.  A top-down view is an
;; ordinary thing to want, and every camera in the suite happened to be
;; tilted, so the two answers were never allowed to differ.
;;
;; The cameras below are written out rather than passed in: a camera's
;; (position x y z) does not take an unquote at all -- the expander
;; only makes a hole for a single-valued attribute, so `,px` arrives as
;; the literal form and is refused.  (It never worked; before this
;; batch it stopped the runtime instead of saying so.)
(define (mvp-nan-since from)
  (let loop ((i from) (n 0))
    (if (= i (log-length))
        n
        (let ((e (js->string (js-index gllog i))))
          (loop (+ i 1)
                (if (and (>= (string-length e) 19)
                         (string=? "uniformMat4:U:u_mvp" (substring e 0 19))
                         (let scan ((j 0))
                           (cond ((> (+ j 3) (string-length e)) #f)
                                 ((string=? "NaN" (substring e j (+ j 3))) #t)
                                 (else (scan (+ j 1))))))
                    (+ n 1) n))))))
(define cam-down (log-length))
(begin (cmd-begin!)
       (sgl-draw! (sgl (camera (@ (fov 0.9) (position 0.0 10.0 0.0)
                                  (look-at 0.0 0.0 0.0) (far 100.0)))
                       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                       (mesh (@ (geometry (box 1 1 1)) (position 0.0 5.0 0.0)))))
       (cmd-flush!))
(check "a camera looking straight down has a finite mvp"
       (= 0 (mvp-nan-since cam-down)))
(define cam-up (log-length))
(begin (cmd-begin!)
       (sgl-draw! (sgl (camera (@ (fov 0.9) (position 0.0 0.0 0.0)
                                  (look-at 0.0 5.0 0.0) (far 100.0)))
                       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                       (mesh (@ (geometry (box 1 1 1)) (position 0.0 5.0 0.0)))))
       (cmd-flush!))
(check "...and one looking straight up"
       (= 0 (mvp-nan-since cam-up)))
;; should-GREEN, inside the same code: an ordinary camera and one a hair
;; off vertical both already worked, and a fix that swapped the up
;; vector unconditionally would change what they produce.
(define cam-tilt (log-length))
(begin (cmd-begin!)
       (sgl-draw! (sgl (camera (@ (fov 0.9) (position 0.0 10.0 0.01)
                                  (look-at 0.0 0.0 0.0) (far 100.0)))
                       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
                       (mesh (@ (geometry (box 1 1 1)) (position 0.0 5.0 0.0)))))
       (cmd-flush!))
(check "a camera a hair off vertical still has a finite mvp"
       (= 0 (mvp-nan-since cam-tilt)))

;; ---- 8. the instanced path, at u32 --------------------------------
;; Instancing groups nodes by geo IDENTITY, and an injected mesh gets a
;; fresh geo every time -- so every node above was ineligible and the
;; instanced branch, including the command this change added, had no
;; coverage at all.  Two nodes sharing a LITERAL geometry spec share one
;; cached geo, which is what makes them an instance group.

(define inst-draw (draw-count))
(define inst-up (uploads))
(let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                          (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (mesh (@ (geometry (sphere 1.0 300 220)) (color 1.0 0.0 0.0)))
               (mesh (@ (geometry (sphere 1.0 300 220))
                        (position 3.0 0.0 0.0) (color 1.0 0.0 0.0))))))
  (cmd-begin!) (sgl-draw! sc) (cmd-flush!))

;; Named "as ONE instanced call", so all three numbers in that sentence
;; are asserted: one draw added, two instances in it, and the geometry's
;; whole index count in that one call.  "> 1 instances and at least one
;; draw" is satisfied by emitting the draw twice, by passing n + 1, and
;; by passing an index count of 1 -- the reading the name promises is
;; strictly narrower than the reading a bound gives.
(check "the two nodes drew as one instanced call"
       (and (= 1 (- (draw-count) inst-draw))
            (= 2 (draw-inst inst-draw))
            (string=? "TRI" (draw-mode inst-draw))
            (= (mesh-index-count (mesh-sphere 1.0 300 220))
               (draw-n inst-draw))))
(check "an instanced u32 geometry asks for UNSIGNED_INT"
       (string=? "UI" (draw-type inst-draw)))
(check "...and it is still a triangle mesh, not lines"
       (string=? "TRI" (draw-mode inst-draw)))
(check "and its index buffer went up four bytes wide"
       (= 4 (upload-width
             (upload-with inst-up
                          (mesh-index-count (mesh-sphere 1.0 300 220))))))

;; the u16 side of the same path, so the branch is pinned both ways
(define inst16-draw (draw-count))
(let ((sc (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0)
                          (look-at 0.0 0.0 0.0)))
               (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
               (mesh (@ (geometry (sphere 1.0 8 4)) (color 0.0 0.0 1.0)))
               (mesh (@ (geometry (sphere 1.0 8 4))
                        (position 3.0 0.0 0.0) (color 0.0 0.0 1.0))))))
  (cmd-begin!) (sgl-draw! sc) (cmd-flush!))

(check "an instanced u16 geometry still asks for UNSIGNED_SHORT"
       (and (= 1 (- (draw-count) inst16-draw))
            (= 2 (draw-inst inst16-draw))
            (string=? "TRI" (draw-mode inst16-draw))
            (= (mesh-index-count (mesh-sphere 1.0 8 4)) (draw-n inst16-draw))
            (string=? "US" (draw-type inst16-draw))))

;; ---- 9. the SECOND frame, which is a different branch --------------
;; An instance group draws through one of two paths: the set is
;; recomputed and the count comes from that pass, or nothing moved and
;; the cached count is redrawn.  Every case above builds a scene and
;; draws it once, so only the first was ever reached -- replacing the
;; cached count with a literal 1 left the whole file green while the
;; second frame of any unchanged scene dropped an instance.  Same scene,
;; two frames: the second must repeat the first exactly.

(define f2-scene
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (sphere 1.0 8 4)) (color 0.0 1.0 0.0)))
       (mesh (@ (geometry (sphere 1.0 8 4))
                (position 3.0 0.0 0.0) (color 0.0 1.0 0.0)))))
(define f2-a (draw-count))
(begin (cmd-begin!) (sgl-draw! f2-scene) (cmd-flush!))
(define f2-b (draw-count))
(define f2-log-after-first (log-length))
(begin (cmd-begin!) (sgl-draw! f2-scene) (cmd-flush!))

(check "an unchanged scene's second frame redraws the same instanced call"
       (and (= 1 (- f2-b f2-a))
            (= 1 (- (draw-count) f2-b))
            (= (draw-inst f2-a) (draw-inst f2-b))
            (= 2 (draw-inst f2-b))
            (= (draw-n f2-a) (draw-n f2-b))
            (string=? (draw-type f2-a) (draw-type f2-b))
            ;; "the same call" means every argument of it.  The mode was
            ;; recorded and then not compared, so a branch that differed
            ;; ONLY between the two frames -- `(if up? GL-TRIANGLES
            ;; GL-LINES)` -- passed: the first frame's assertions saw
            ;; triangles and this one never looked.  Comparing four of
            ;; the five arguments is what "exactly" was hiding.
            (string=? (draw-mode f2-a) (draw-mode f2-b))
            (string=? "TRI" (draw-mode f2-b))))

;; ...and it uploaded nothing to do it.  Note what this does and does
;; not say.  It says NO BUFFER UPLOAD happened on the second frame, and
;; that is enough to catch the regression this part exists for: making
;; the group recompute every frame repacks and re-uploads, and turns
;; this line red while every other line in the file stays green.
;;
;; It does NOT say the group failed to recompute.  A recompute whose
;; upload was suppressed would repack staging memory and still pass
;; here.  That stronger property has no projection in the GL trace --
;; culling and packing touch only scratch memory, which the mock never
;; sees -- so it is not asserted rather than asserted by a stand-in.
;; The name says the measured thing, because a name is read far more
;; often than the code under it.
(check "and the second frame uploaded no buffer at all"
       (= 0 (buffer-uploads-since f2-log-after-first)))

(= fails 0)
