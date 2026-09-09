;; A fixture, not a test: the control for
;; test/defect-r01-scanner-block-comment.ss.  The scanner already skips
;; `;` comments, so the decoy below is invisible to it.
(library (probe lined-import)
  (export lined)
  ;; an example in prose: (import (nonexistent lib))
  (import (rnrs))
  (define (lined) 7))
