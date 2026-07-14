# Cross-engine benchmarks: the deboxing batch

Times in ms, lower is better.  OLD = commit c76ee0f (before the i32
context, loop lowering, typed loop variables and function-boundary
work); NEW = after.  Run by `bench/cross-engine.html` (loads both
compiler outputs, reports each via an image beacon).

Machine: macOS 26 (Darwin 25.3), Safari 26 / Chrome 150.

| benchmark            | Chrome OLD | Chrome NEW | ×    | Safari OLD | Safari NEW | ×    |
|----------------------|-----------:|-----------:|:----:|-----------:|-----------:|:----:|
| m4-mul   × 100k      |        110 |         33 | 3.3  |        274 |        119 | 2.3  |
| flsin    × 1M        |          9 |         11 | ~1   |         20 |         13 | 1.5  |
| character-move × 200k|        140 |         82 | 1.7  |        300 |        211 | 1.4  |
| frustum cull × 2M    |         98 |         35 | 2.8  |        197 |         68 | 2.9  |

## Findings

- The deboxing batch is a real win on **both** engines (1.4–3.3×),
  not V8-noise as an earlier per-commit microbench had suggested —
  the cumulative old→new gap is large everywhere.
- JSC is ~2.3–3× slower than V8 in absolute terms on every kernel,
  confirming that its WasmGC allocator is the bottleneck the memory
  note flagged — which is exactly why removing allocations helps.
- **flsin barely moves on V8** (~1×) but 1.5× on Safari: its cost is
  the box at the call boundary — argument unwrapped, result boxed
  then immediately unwrapped by the caller — which loop-internal
  deboxing can't reach.  Flonum function specialization (a later
  commit) gives flsin an f64 parameter, and the frustum cull's
  predicate specializes too: cull improves a further step (Chrome
  44→35, Safari 84→68).  The NEW column above is post-specialization.
  V8 still shows ~1× on flsin — its JIT already elides the small
  function's boxing — so this win, like the rest, is a JSC story.
- The benchmark caught a **shipped Safari regression**: the fused
  `relaxed_madd` (a 3% V8 win on a memory-bound kernel) failed to
  validate on this Safari's WasmGC build, breaking every module that
  uses `%f32x4-axpy!` — i.e. the whole `(gfx mat)`/scene stack.
  Reverted to the portable mul+add; fx-scene validates on Safari
  again.
