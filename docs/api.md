# API index

Every name the libraries export, by library.  The manual explains what
each library is for and how to use it; this file exists so that a name
can be found at all.  It is generated from the `(export ...)` forms and
`test/api-index.mjs` fails if it drifts, so a name that is here is
exported and a name that is exported is here.

A capability nobody can find is one that gets written again downstream.
That is not hypothetical: of the names below, 442 appeared nowhere in
the manual when this file was first generated, and a consumer rebuilt
frustum culling, an input layer and a joint palette that all already
existed.

# aud

Sound.

## `(aud sfx)`

`audio-init!`  `audio-time`  `beep!`  `load-sound!`  `play!`  `loop-sound!`  `stop-sound!`


# gfx

Drawing, and the geometry and assets behind it.

## `(gfx collide)`

`sphere-sphere?`  `aabb-aabb?`  `sphere-aabb?`  `capsule-sphere?`  `capsule-capsule?`  `capsule-aabb?`  `ray-sphere`  `ray-aabb`  `ray-plane`  `ray-triangle`  `ray-mesh`  `sphere-aabb-push`  `sweep-sphere-aabb`  `move-and-slide`  `make-character`  `character?`  `character-pos`  `character-grounded?`  `character-move!`  `character-jump!`  `make-aabb-grid`  `grid-near`

## `(gfx fx)`

`fx-init!`  `fx-slot!`  `fx-alloc!`  `fx-mark`  `fx-release!`  `fx-buffer!`  `fx-texture!`  `fx-texture-array!`  `fx-mesh!`  `fx-mesh?`  `fx-mesh-use!`  `fx-mesh-draw!`  `fx-mesh-count`  `fx-width`  `fx-height`  `fx-target!`  `fx-target-hdr!`  `fx-target-msaa!`  `fx-resolve!`  `fx-target-mrt!`  `fx-mrt-texture`  `fx-cube-target!`  `fx-bind-cube-face!`  `fx-target?`  `fx-target-texture`  `fx-target-width`  `fx-target-height`  `fx-bind-target!`  `fx-bind-canvas!`  `fx-read-target!`  `fx-program!`  `fx-program3!`  `fx-tf-program!`  `fx-ubo!`  `fx-program?`  `fx-program-slot`  `fx-program-stride`  `fx-program-attribute-names`  `fx-program-attribute-schema`  `fx-program-istride`  `fx-program-blocks`  `fx-use!`  `fx-use-instanced!`  `fx-uniform!`  `fx-uniform?`  `fx-ticks!`  `fx-loop!`  `fx-loop-fixed!`  `fx-init-input!`  `key-down?`  `pointer-x`  `pointer-y`  `pointer-down?`  `pointer-lock!`  `pointer-locked?`  `pointer-motion!`  `fx-fullscreen!`  `fx-quad-program`  `fx-fullscreen-use!`  `fx-fullscreen-draw!`

## `(gfx gl)`

`gl-attach!`  `gl-program!`  `gl-buffer!`  `gl-uniform!`  `gl-texture!`  `gl-texture-upload!`  `gl-texture-data!`  `gl-cubemap!`  `gl-cubemap-empty!`  `gl-cube-face-fb!`  `gl-slot-object!`  `gl-target!`  `gl-target-hdr!`  `gl-target-msaa!`  `gl-cube-target!`  `gl-target-mrt!`  `cmd-bind-target!`  `cmd-bind-canvas!`  `cmd-resolve!`  `cmd-read-pixels!`  `cmd-region!`  `cmd-begin!`  `cmd-flush!`  `cmd-pos`  `cmd-draws`  `cmd-clear!`  `cmd-use-program!`  `cmd-bind-buffer!`  `cmd-buffer-data!`  `cmd-vertex-attrib!`  `cmd-vertex-attrib-h!`  `cmd-uniform1f!`  `cmd-uniform4f!`  `cmd-uniform1i!`  `cmd-uniform2f!`  `cmd-uniform3f!`  `cmd-uniform-matrix4!`  `cmd-uniform-matrix4s!`  `cmd-bind-texture!`  `cmd-unbind-texture!`  `cmd-bind-cubemap!`  `cmd-unbind-cubemap!`  `gl-texture-array!`  `gl-texture-layer!`  `gl-texture-layer-data!`  `cmd-bind-texture-array!`  `gl-gpu-timer!`  `gl-gpu-ms`  `gl-compressed-family`  `gl-texture-compressed!`  `gl-compressed-level!`  `gl-texture-base-level!`  `gl-texture-sampler!`  `cmd-depth!`  `cmd-depth-write!`  `gl-vao!`  `cmd-bind-vao!`  `cmd-unbind-vao!`  `gl-ubo!`  `gl-uniform-block!`  `cmd-bind-ubo!`  `cmd-ubo-data!`  `gl-tf-program!`  `cmd-tf-buffer!`  `cmd-tf-begin!`  `cmd-tf-end!`  `cmd-bind-index!`  `cmd-index-data!`  `cmd-draw-elements!`  `cmd-index-data32!`  `cmd-draw-elements32!`  `cmd-attrib-divisor!`  `cmd-draw-elements-instanced!`  `cmd-draw-elements-instanced32!`  `cmd-uniform-matrices!`  `cmd-uniform-matrices4s!`  `cmd-draw-arrays!`  `cmd-viewport!`  `cmd-blend!`  `GL-POINTS`  `GL-LINES`  `GL-TRIANGLES`  `GL-TRIANGLE-STRIP`

## `(gfx glb)`

`glb-write!`  `glb-stride`  `glb-offset`

## `(gfx gltf)`

`gltf?`  `gltf-prims`  `gltf-images`  `gltf-parse`  `gltf-fetch!`  `gltf-load-textures!`  `gltf-draw!`  `gltf-textures`  `gltf-samplers`  `gltf-cameras`  `gltf-node-camera`  `gsampler?`  `gsampler-mag`  `gsampler-min`  `gsampler-wrap-s`  `gsampler-wrap-t`  `gtexref?`  `gtexref-texture`  `gtexref-image`  `gtexref-sampler`  `gtexref-texcoord`  `gtexref-factor`  `gprim-base-tex`  `gprim-mr-tex`  `gprim-normal-tex`  `gprim-emissive-tex`  `gprim-occlusion-tex`  `gprim-mrtex`  `gprim-morph-normals`  `gprim-morph-tangents`  `gprim-base-color-factor`  `gprim-node`  `gprim-skin`  `gltf-anims`  `gltf-nodes`  `gltf-skins`  `gltf-node-translation`  `gltf-node-rotation`  `gltf-node-scale`  `gltf-node-translation-set!`  `gltf-node-rotation-set!`  `gltf-node-scale-set!`  `gltf-node-count`  `gltf-node-parent`  `gltf-node-matrix?`  `gltf-animation-names`  `gltf-animation-duration`  `gltf-animate!`  `gltf-pose-at!`  `gltf-animate-blend!`  `gltf-weights!`  `gprim-morph`  `anim-machine`  `anim-machine?`  `anim-state`  `anim-goto!`  `anim-update!`  `gltf-joint-matrices`  `gltf-joint-palette!`  `gltf-joint-count`  `gltf-skin-positions!`  `gltf-skin-normals!`  `gprim-vcount`  `gltf-skin-vs`  `gltf-skin-shader`  `gltf-skin-vs3`  `gltf-skin-shader3`  `gltf-skin-program3!`  `gltf-skin-binding`  `gltf-skin-block-joints`  `gltf-skin-uniform-joints`  `gprim-vbase`  `gprim-vbytes`  `gprim-ibase`  `gprim-ibytes`  `gprim-icount`  `gprim-index-u32?`  `gprim-color`  `gprim-metallic`  `gprim-roughness`  `gprim-world`  `gltf-prim-world`  `gprim-stride`  `gprim-layout`  `gprim-tex`  `gprim-textured?`  `gprim-normal-img`  `gprim-emissive-img`  `gprim-occlusion-img`  `gprim-emissive`  `gprim-ntex`  `gprim-etex`  `gprim-otex`

## `(gfx gpu)`

`gpu-attach!`  `gpu-pipeline!`  `gpu-pipeline2!`  `gpu-pipeline2-blend!`  `gpu-buffer!`  `gpu-index!`  `gpu-uniforms!`  `gpu-storage!`  `gpu-indirect!`  `gpu-compute-group*!`  `gpu-draw-indexed-indirect!`  `gpu-draw-indirect!`  `gpu-hzb-init!`  `gpu-end-pass!`  `gpu-hzb!`  `gpu-compute-groupx!`  `gpu-texture!`  `gpu-texture-data!`  `gpu-sampler!`  `gpu-bindgroup!`  `gpu-texgroup!`  `gpu-compute!`  `gpu-compute-group!`  `gpu-begin!`  `gpu-flush!`  `gpu-clear!`  `gpu-use-pipeline!`  `gpu-bind-vbuf!`  `gpu-bind-vbuf2!`  `gpu-bind-ibuf!`  `gpu-set-group!`  `gpu-buffer-data!`  `gpu-draw!`  `gpu-draw-indexed!`  `gpu-draw-instanced!`  `gpu-dispatch!`  `gpu-bundle!`  `gpu-execute!`  `gpu-gpu-timer!`  `gpu-gpu-ms`

## `(gfx ibl)`

`ibl-brdf-lut!`  `ibl-prefilter!`

## `(gfx image)`

`png-info`  `png-decode!`  `png-encode!`  `png-encode-size`  `tga-info`  `tga-decode!`  `inflate!`  `zlib-inflate!`  `crc32`  `adler32`

## `(gfx ktx)`

`ktx-parse`  `ktx?`  `ktx-width`  `ktx-height`  `ktx-level-count`  `ktx-scheme`  `ktx-etc1s?`  `ktx-uastc?`  `ktx-level-width`  `ktx-level-height`  `ktx-transcode!`  `ktx-transcode-bytes`  `ktx-uastc-level!`  `ktx-fetch!`  `ktx-upload!`  `ktx-stream!`  `ktx-alpha?`

## `(gfx mat)`

`flsin`  `flcos`  `fltan`  `flasin`  `flacos`  `flatan`  `flatan2`  `q-mul`  `q-conj`  `q-neg`  `q-dot`  `q-normalize`  `q-slerp`  `v3`  `v3-x`  `v3-y`  `v3-z`  `v3-add`  `v3-sub`  `v3-scale`  `v3-dot`  `v3-cross`  `v3-normalize`  `v3-set!`  `v3-copy!`  `v3-add!`  `v3-sub!`  `v3-scale!`  `v3-cross!`  `v3-normalize!`  `m4-identity`  `m4-mul`  `m4-scratch!`  `m4-transform`  `m4s-write!`  `m4s-read`  `m4s-identity!`  `m4s-mul!`  `m4s-trs!`  `m4s-tqs!`  `m4-translate`  `m4-scale`  `m4-rotate-x`  `m4-rotate-y`  `m4-rotate-z`  `m4-from-quat`  `m4-perspective`  `m4-ortho`  `m4-look-at`  `m4-inverse`  `m4-unproject`  `m4-frustum-planes`  `sphere-in-frustum?`  `sphere-in-frustum-xyz?`  `fl-clamp`  `fl-lerp`  `fl-damp`  `fl-turn`  `fl-smooth`

## `(gfx mesh)`

`mesh?`  `mesh-verts`  `mesh-indices`  `mesh-uvs`  `mesh-optimize!`  `mesh-remap!`  `mesh-acmr`  `mesh-vert-count`  `mesh-index-count`  `mesh-vertex-bytes`  `mesh-index-bytes`  `mesh-index-u32?`  `mesh-write!`  `mesh-vertex-bytes-f16`  `mesh-write-f16!`  `mesh-vertex-bytes-uv`  `mesh-write-uv!`  `mesh-tangents`  `mesh-vertex-bytes-tan`  `mesh-write-tan!`  `mesh-bounds`  `mesh-plane`  `mesh-box`  `mesh-sphere`  `mesh-cylinder`  `mesh-torus`  `mesh-heightmap`  `mesh-lit-vs`  `mesh-lit-fs`  `mesh-tex-vs`  `mesh-tex-fs`  `mesh-normal-vs`  `mesh-normal-fs`  `mesh-pbr-vs`  `mesh-pbr-fs`

## `(gfx meshopt)`

`meshopt-vertex!`  `meshopt-index!`  `meshopt-index-sequence!`  `meshopt-filter-oct!`  `meshopt-filter-quat!`  `meshopt-filter-exp!`

## `(gfx post)`

`post-quad!`  `post-pass!`  `make-blur`  `blur-run!`  `blur-texture`  `make-bloom`  `bloom-run!`  `bloom-texture`  `bloom-composite!`  `make-fxaa`  `fxaa-run!`  `make-grade`  `grade-run!`  `make-dof`  `dof-run!`

## `(gfx raster)`

`make-rcam`  `rcam`  `rcam?`  `rcam-az`  `rcam-el`  `rcam-dist`  `rcam-roll`  `rcam-fov`  `rcam-target-x`  `rcam-target-y`  `rcam-target-z`  `rcam-shift-u`  `rcam-shift-v`  `rcam-near`  `rcam-far`  `rcam->list`  `list->rcam`  `rcam-basis`  `rcam-basis!`  `rcam-eye`  `rcam-eye!`  `rcam-view`  `rcam-view!`  `rcam-project`  `rcam-project!`  `rcam-ray`  `rcam-ray!`  `rattr?`  `rattr-count`  `rattr-ncomp`  `rattr-ref`  `rattr-f32`  `rattr-f64`  `rattr-vector`  `rattr-proc`  `ridx?`  `ridx-count`  `ridx-ref`  `ridx-u16`  `ridx-u32`  `ridx-vector`  `ridx-range`  `ridx-proc`  `make-rmesh`  `rmesh?`  `rmesh-positions`  `rmesh-indices`  `rmesh-vertex-count`  `rmesh-tri-count`  `rmesh-tri`  `raster-scratch-bytes`  `project-vertices!`  `proj-x`  `proj-y`  `proj-depth`  `tri-spans!`  `tri-spans-capacity`  `make-rmask`  `rmask?`  `rmask-base`  `rmask-width`  `rmask-height`  `rmask-bytes`  `rmask-clear!`  `rmask-ref`  `rmask-set!`  `rmask-count`  `render-mask!`  `render-mask-add!`  `mask-iou`  `make-rframe`  `rframe?`  `rframe-base`  `rframe-width`  `rframe-height`  `rframe-bytes`  `rframe-clear!`  `render-frame!`  `frame-tri`  `frame-depth`  `frame-invd`  `frame-bary!`  `frame-interp!`  `frame-mask!`  `frame-point-visible?`  `make-rimg`  `rimg?`  `rimg-base`  `rimg-width`  `rimg-height`  `rimg-bytes`  `rimg-clear!`  `rimg-ref`  `rimg-set!`  `rimg-texel!`  `rimg-nearest!`  `rimg-bilinear!`  `render-textured!`  `shade-textured!`  `frame-texel`  `frame-texel!`  `frame-splat!`  `frame-diff`

## `(gfx reflect)`

`reflect-plane-matrix`  `reflect-range`  `m4-crop-rect`

## `(gfx retarget)`

`retarget-clip!`  `retarget-write-glb!`  `retarget-report`  `retarget-normalize-name`  `retarget-glb-node-names`

## `(gfx scene)`

`sgl`  `$sgl-build`  `sgl-scene?`  `sgl-draw!`

## `(gfx sdf)`

`sdf-from-canvas!`

## `(gfx sgpu)`

`sgl-gpu`  `$sgpu-build`  `sgpu-init!`  `sgpu-draw!`  `sgpu-scene?`  `sgpu-occlusion!`

## `(gfx sprite)`

`atlas?`  `make-atlas`  `atlas-measurer`  `atlas-line-height`  `batch?`  `make-batch`  `batch-atlas`  `batch-begin!`  `sprite!`  `rect!`  `draw-text!`  `batch-draw!`  `load-image!`  `sheet?`  `make-sheet`  `sheet-width`  `sheet-height`  `sheet-batch?`  `make-sheet-batch`  `sheet-batch-sheet`  `sheet!`  `sheet-draw!`

## `(gfx stats)`

`make-stats`  `stats-draw!`

## `(gfx uastc)`

`uastc-block!`  `uastc-decode!`  `uastc-block-mode`

## `(gfx wgsl)`

`wgsl->string`  `wgsl-compute->string`  `wgsl-layout`  `wgsl-check`

## `(gfx xr)`

`xr-supported?`  `xr-start!`  `xr-end!`  `xr-framebuffer`  `xr-eye-count`  `xr-eye-viewport!`  `xr-eye-vp`

## `(gfx zstd)`

`zstd-decode!`  `zstd-frame-size`


# lng

Language: dispatch, machines, effects -- how a program is organised, not what it draws.

## `(lng effect)`

`make-effect`  `effect?`  `effect-kind`  `effect-source`  `effect-priority`  `effect-phase`  `effect-payload`  `effect->datum`  `datum->effect`  `resolve`  `collect-effects`

## `(lng generic)`

`make-generic`  `generic?`  `generic-name`  `generic-arity`  `classifiers`  `add-handler!`  `add-handlers!`  `remove-handler!`  `generic-default!`  `generic-check!`  `generic-handlers`  `dispatch-trace`

## `(lng machine)`

`make-machine`  `machine?`  `machine-state`  `machine-ctx`  `machine-spec`  `machine-events`  `machine-transitions`  `machine-step`  `machine->datum`  `datum->machine`

## `(lng pred)`

`define-classifier`  `classifier?`  `classifier-name`  `classifier-tags`  `classify`  `classify-as`  `declare-subtag!`  `subtag?`  `descendants`  `classifier-watch!`  `declare-subset!`  `subset?`


# sim

The half that is not drawing: who exists, what runs each tick, who hears what.

## `(sim entity)`

`make-entities`  `entity-spawn!`  `entity-alive?`  `entity-destroy!`  `entity-set!`  `entity-ref`  `entity-each`  `entity-count`  `entity-capacity`

## `(sim events)`

`make-bus`  `bus-on!`  `bus-off!`  `bus-emit!`  `bus-clear!`  `bus-depth-limit`

## `(sim grid)`

`grid-cell`  `grid-origin`  `grid-in-cell?`

## `(sim random)`

`make-rng`  `random-integer!`  `random-real!`  `random-range!`

## `(sim schedule)`

`make-schedule`  `schedule-add!`  `schedule-remove!`  `schedule-run!`  `schedule-systems`

## `(sim step)`

`make-fixed-step`  `fixed-step-advance!`  `fixed-step-alpha`  `fixed-step-time`  `fixed-step-reset!`


# web

The page: markup, styling, reactivity, transport.

## `(web args)`

`args-count`  `args-ref`  `args-list`

## `(web canvas)`

`canvas-measurer`

## `(web component)`

`styled`  `styled-css`  `define-component`

## `(web css)`

`css->string`  `num->css`  `palette->root`

## `(web dom)`

`window`  `document`  `body`  `get-element-by-id`  `query-selector`  `create-element`  `make-text`  `append-child!`  `replace-child!`  `insert-before!`  `remove-child!`  `remove-all-children!`  `set-inner-html!`  `inner-text`  `set-text!`  `set-attribute!`  `set-style!`  `computed-style`  `computed-px`  `add-event-listener!`  `console-log`  `alert`

## `(web fetch)`

`fetch`  `fetch-direct?`  `http-get`  `http-post`  `response-status`  `response-ok?`  `response-text`  `response-header`

## `(web frac)`

`frac-digits`

## `(web fs)`

`fs-exists?`  `fs-size`  `fs-slurp!`  `fs-spit!`  `fs-slurp-string`  `fs-spit-string!`

## `(web glyphs)`

`glyphs!`  `glyphs-mixed!`  `glyphs-group?`  `glyphs-track!`  `glyphs-step!`  `glyphs-dodge!`  `glyphs-rebuild!`

## `(web html)`

`sxml->html`  `html->document`  `html-escape`  `raw`  `raw?`

## `(web js)`

`js-ref?`  `js-global`  `js-undefined`  `js-eq?`  `js-truthy?`  `js-get`  `js-set!`  `js-call`  `js-method`  `js-new`  `js-index`  `string->js`  `js->string`  `number->js`  `js->number`  `->js`  `js-eval`  `js-await`  `js-callback-error!`

## `(web json)`

`string->json`  `json->string`  `json-ref`  `json-array?`  `json-array->list`

## `(web react)`

`react-component`  `props-ref`

## `(web reactive)`

`signal`  `signal-ref`  `signal-set!`  `signal-update!`  `effect`  `dispose-effect!`  `on-cleanup`  `root`  `batch`  `untracked`

## `(web rpc)`

`rpc`  `rpc!`  `rpc-get`  `rpc-serialize`  `rpc-parse`

## `(web scroll)`

`make-vscroll`  `vscroll?`  `vscroll-element`  `vscroll-count`  `vscroll-append!`  `vscroll-render!`

## `(web sexpr)`

`sexpr->string`  `string->sexpr`

## `(web sse)`

`sse-connect!`  `sse-close!`

## `(web sx)`

`sx`  `sx-mount`  `sx-list`  `$sx-build`

## `(web typeset)`

`prepare`  `prepared?`  `prepared-width`  `layout`  `layout?`  `layout-height`  `layout-line-count`  `layout-lines`  `line?`  `line-text`  `line-width`  `line-y`  `string-fold-cp`

## `(web utf8)`

`utf8-well-formed?`

## `(web ws)`

`ws-connect!`  `ws-send!`  `ws-close!`  `ws-open?`

