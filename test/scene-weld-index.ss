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
(check "and the mesh layer draws the line in the same place"
       (and (not (mesh-index-u32? at-boundary))
            (not (mesh-index-u32? under))
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
