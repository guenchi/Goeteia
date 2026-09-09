;; A fixture, not a test.  See test/defect-r01-scanner-block-comment.ss.
;;
;; The (import ...) inside the block comment is not an import: the
;; reader discards the whole comment.  A dependency scanner that does
;; not know about #| |# sees it first and takes it for the real one.
(library (probe commented-import)
  (export answer)
  #| an example in prose: (import (nonexistent lib)) |#
  (import (rnrs))
  (define (answer) 42))
