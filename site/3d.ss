;; 3d.html — authored in Scheme, rendered to HTML by Goeteia.
;; A static page: the whole document is SXML data, so there is no
;; browser-side half and nothing to mount.
(import (web html) (web css) (web component) (chrome))

(define body
  (list
   `(header
     (div (@ (class "head-row"))
       (h1 "3D for the AI era")
       (span (@ (class "era")) "video" ,(raw "&nbsp;") "in," ,(raw "&nbsp;")
             "game" ,(raw "&nbsp;") "asset" ,(raw "&nbsp;") "out"))
     (p (@ (class "lede"))
        "A martial-arts clip instead of a motion-capture stage. A character "
        "turnaround instead of a month of sculpting and rigging."))

   `(section
     (p "AI is already good at producing reference imagery — designs, "
        "turntables, motion video. It is still bad at producing what a game "
        "engine actually eats: a rigged, skinned, textured, animated character. "
        "That gap is the industry's chokepoint, and closing it does not need a "
        "bigger model. It needs a pipeline where every step is checkable by a "
        "machine — because an AI can only iterate where it can " (em "verify") ". "
        "That pipeline is what this stack is built for."))

   `(section
     ,(layer "1" "The loop is the machine"
            '("Propose, project, compare, correct — every stage below is that "
              "same shape."))
     (div (@ (class "layer-body"))
       (p "The accuracy of the result comes from the loop, not from any single "
          "estimate. An initial guess only decides how many iterations it takes, "
          "and an iteration here is milliseconds of CPU math.")
       (ul (@ (class "points"))
         (li (b "Data all the way down.") " The mesh is bytes you can read, the "
             "skeleton is a tree you can walk, the shader is a list you can "
             "rewrite — and the rendered frame comes back out as bytes too. "
             "That is what makes the loop closable at all; it is the "
             (a (@ (href "why.html")) "homoiconic argument") " pointed at "
             "geometry.")
         (li (b "No eyes required until the very end.") " A human is asked for "
             "the judgement a program genuinely cannot make, and for nothing "
             "before it."))))

   `(section
     ,(layer "2" "Skeleton from video"
            '("Give it a turntable or a few views."))
     (div (@ (class "layer-body"))
       (ul (@ (class "points"))
         (li (b "The camera comes from the silhouette.") " Rasterize the mesh's "
             "outline on the CPU, compare against the reference mask, search. "
             "No gradients, no GPU.")
         (li (b "The joints come from reprojection.") " 2D keypoints from any "
             "off-the-shelf pose model initialize the skeleton; then the loop "
             "refines it — hypothesize joints, project them into the view, "
             "measure the pixel residual, adjust.")
         (li (b "Anatomy is a regularizer, not a hope.") " Left/right symmetry "
             "and constant bone length are not assumptions to wish for; they "
             "collapse the search space.")
         (li (b "Depth ambiguity dies under multiple frames.") " One skeleton "
             "has to explain all of them at once."))))

   `(section
     ,(layer "3" "Texture from reference"
            '("Projection baking, and then the loop again."))
     (div (@ (class "layer-body"))
       (p "Baking sprays the reference views onto the mesh and down into UV "
          "space: the correspondence between a pixel in a view and a texel in "
          "the atlas is one perspective projection — pure arithmetic. So the "
          "correction runs backwards through the same projection. "
          (em "The left cheek is too dark") " becomes exactly which texels to "
          "change.")
       (ul (@ (class "points"))
         (li (b "A texture lint stands guard underneath.") " UV coverage, dead "
             "islands, seam color mismatch, whole-image misalignment — "
             "generated garbage is rejected by a program before any human looks "
             "at it."))))

   `(section
     ,(layer "4" "Skinning under feedback"
            '("Weights are bytes that can change between one frame and the "
              "next."))
     (div (@ (class "layer-body"))
       (p "No re-export, no reimport, no engine restart. Pose the character at "
          "a reference frame, compare the deformed silhouette, nudge the "
          "weights, watch the result in the same second.")
       (ul (@ (class "points"))
         (li (b "And behind the eye, validators.") " Bone lengths must not "
             "stretch, symmetry must hold, no vertex's normal may collapse. "
             "Wrong skinning is caught by an assertion, not by QA three weeks "
             "later."))))

   `(section
     ,(layer "5" "Motion capture without the stage"
            '("One video of a martial artist, instead of an actor in a marker "
              "suit."))
     (div (@ (class "layer-body"))
       (p "With the skeleton pinned, per-frame solving is the easy direction: "
          "bone lengths are locked, only rotations remain. Frames chain into "
          "clips, temporal smoothing eats the jitter, and validators check what "
          "matters — feet on the ground, bones constant, amplitude in range. "
          "The source library stops being " (em "actors we can hire") " and "
          "becomes " (em "every video ever shot") ".")
       (p "And the output is not frozen capture data. A clip here is editable "
          "text: compress the strike from six frames to three, exaggerate the "
          "windup — then " (em "measure") " that the timing changed the way the "
          "director asked. Optical capture delivers data you clean; this "
          "delivers material you keep working.")))

   `(section
     ,(layer "6" "Why this stack, specifically"
            '("The loop has hard prerequisites. They are exactly what "
              "shipped."))
     (div (@ (class "layer-body"))
       (ul (@ (class "points"))
         (li (b "A complete glTF 2.0 skeletal pipeline that verifies headless.")
             " Joint matrices, vertex streams and animation samplers are all "
             "assertable from a terminal.")
         (li (b "Drawing that refuses layout mismatches.") " A program that "
             "does not match the mesh is an error naming both sides, not a "
             "frame of triangle soup with nothing in the console.")
         (li (b "Shaders are data.") " Lighting is written once as an "
             "s-expression; the skinned variant is derived from it "
             "mechanically, by a combinator that checks its own output — "
             "so a fitting loop can rewrite rendering the same way it "
             "rewrites geometry.")
         (li (b "Pixel readback.") " The machine can see the frame it just "
             "rendered — which is the half of the loop everything else "
             "depends on.")
         (li (b "Second-scale compilation, and an asset memory writable at "
                "runtime.") " Together they close the iteration to something an "
             "agent can drive thousands of times a day — with the solver "
             "arithmetic (inverse trig, constant-rate slerp) already in the "
             "box."))
       (p "The API detail lives in the "
          (a (@ (href "manual.html#3d-and-webgl")) "manual") "; the point of "
          "this page is what the pieces add up to. The agent that drives them "
          "is " (a (@ (href "agent.html")) "3d-builder") ".")))

   `(section
     ,(layer "7" "Built for a fleet, not a seat"
            '("Throughput is bounded by how parallel the environment lets the "
              "agents be."))
     (div (@ (class "layer-body"))
       (p "The traditional 3D stack is physically hostile to concurrent AI "
          "work: one editor instance, a gigabyte install, binary assets that "
          "git cannot merge. Ten agents on one project means nine waiting.")
       (ul (@ (class "points"))
         (li (b "The entire product is text.") " Scenes, shaders, meshes, "
             "animation logic — so ten agents mean ten git worktrees, each with "
             "its own second-scale compiles and headless assertions, on one "
             "laptop, converging by ordinary merge.")
         (li (b "Review is a program, not a meeting.") " Mutation tests tell you "
             "whether an assertion can actually fail — and nothing in the loop "
             "needs a window."))))

   `(section
     ,(layer "8" "Light enough to be everywhere"
            '("The whole compiler crosses the wire in under 60KB "
              "(431KB of wasm, before compression) and runs in the page."))
     (div (@ (class "layer-body"))
       (ul (@ (class "points"))
         (li (b "The workbench is a browser tab.") " A Chromebook or a tablet "
             "is enough to model, skin and iterate.")
         (li (b "Shipped artifacts are hundreds of kilobytes.") " Not a "
             "thirty-megabyte engine runtime — which is the difference between "
             (em "works in a product page on a phone") " and "
             (em "works after a loading bar") ".")
         (li (b "Disposable 3D, at conversation scale.") " Generating, "
             "compiling and running all happen on one surface, so an AI can "
             "hand you an interactive 3D demo the way it hands you a paragraph "
             "— made to answer one question, then thrown away."))))

   `(section
     ,(layer "9" "Where it stands"
            '("Not a roadmap slide."))
     (div (@ (class "layer-body"))
       (p "The camera-from-silhouette solver, the projection baker and the "
          "texture lint exist, and they hold themselves to round-trip fixtures: "
          "synthetic views baked back to the atlas and compared, recovered "
          "cameras checked against ground truth — every claim a computable "
          "assertion.")
       (p "The per-frame pose solver is in progress. Lighting-from-reference "
          "and the feedback protocol for vision models come next.")
       (div (@ (class "callout"))
         (span (@ (class "k")) "The discipline, unchanged as it grows")
         (p "Nothing ships on the strength of looking right. It ships when a "
            "program agrees."))))))

;; a numbered layer: the badge, heading and subhead carry their css;
;; the nine layers intern to one class (the body is a sibling block).
;; Same component as the Why page — kept per-page so each source is
;; readable on its own.
(define-component (layer n title sub)
  (style
    (display flex) (gap (em 1 10)) (align-items baseline)
    (".n" (flex none) (font-family (var mono)) (font-weight 700) (font-size (em 1 5))
          (color "#fff") (background (var lapis))
          (width (em 1 90)) (height (em 1 90)) (border-radius (pct 50))
          (display inline-flex) (align-items center) (justify-content center))
    ("h2" (font-size (em 1 50)) (font-weight 600) (margin 0))
    (".sub" (color (var dim)) (font-size (em 0 95)) (margin-top (em 0 15))))
  (div
    (span (@ (class "n")) ,n)
    (div (h2 ,title) (div (@ (class "sub")) ,@sub))))

(define threed-styles
  `((header (padding (em 5) 0 (em 2 50)))
    (".head-row" (display flex) (align-items baseline) (justify-content flex-start)
                 (gap (em 0 70)) (flex-wrap wrap))
    (h1
     (font-size (em 3)) (margin 0) (font-weight 650) (letter-spacing (em 0 2))
     (background "linear-gradient(120deg, var(--lapis), var(--azure))")
     (-webkit-background-clip text) (background-clip text) (color transparent))
    (".era" (font-family (var mono)) (font-size (em 0 85)) (color (var dim)))
    (".lede" (color (var dim)) (font-size (em 1 20)) (margin-top (em 0 80)) (max-width (em 34)))
    (section (padding (em 2 40) 0) (border-top (px 1) solid (var line)))
    (p (color (var ink)))
    (code (font-family (var mono)) (color (var lapis)) (font-size (em 0 90))
          (background "#eef1f9") (padding (em 0 10) (em 0 38)) (border-radius (px 5)))
    ;; numbered layers (the badge/heading are the component above)
    (".layer-body" (margin-left (em 3)))
    ("ul.points" (list-style none) (padding 0) (margin (em 1 10) 0 0))
    ("ul.points > li"
     (position relative) (padding-left (em 1 30)) (margin (em 0 90) 0) (color (var ink)))
    ("ul.points > li::before"
     (content "\"→\"") (position absolute) (left 0) (color (var azure)) (font-weight 700))
    ("ul.points b" (color (var ink)))
    (".callout"
     (margin (em 1 40) 0 0) (padding (em 1 30) (em 1 50))
     (background (var bg2)) (border (px 1) solid (var line))
     (border-left (px 4) solid (var lapis)) (border-radius 0 (px 12) (px 12) 0)
     (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6))))
    (".callout .k" (color (var lapis)) (font-weight 700) (font-size (em 0 80))
                   (letter-spacing (em 0 8)) (text-transform uppercase))
    (".callout p" (margin (em 0 50) 0 0) (font-size (em 1 8)))))

(define page-css
  (string-append (css->string (base-styles 52))
                 (css->string threed-styles)
                 (css->string (styled-css))
                 (css->string (footer-styles))))

(write-file "3d.html"
  (render-page "3D for the AI era — Goeteia"
               (string-append "Video in, game asset out. AI can already make "
                              "reference imagery; it cannot make a rigged, "
                              "skinned, textured, animated character. Goeteia "
                              "closes that gap with a propose-project-compare-"
                              "correct loop: skeleton from video, texture from "
                              "reference, skinning under feedback, and motion "
                              "capture with no stage — every step checkable by "
                              "a machine, on a stack that is all text, "
                              "parallel across agents, and small enough to run "
                              "in a browser tab.")
               page-css
               '3d "site/3d.ss" body))
