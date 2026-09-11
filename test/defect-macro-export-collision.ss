;; expect: ((1 0) (2 9))
;; RED ON PURPOSE, and a SILENT miscompile rather than a refusal: two
;; libraries export a macro under the same spelling, the second imported
;; under a rename.  *macros* is keyed by bare spelling and add-macro!
;; conses both, so assq finds whichever was registered last, and BOTH
;; mk and mk2 reach the second library's macro.  Two macros with
;; distinct export names are correct, so it is the collision, not macro
;; exports.  Chez answers ((1 0) (2 9)); today both use (b)'s.  Each
;; entry of *macros* already carries the scope it was written in
;; (apply-macro needs it); the fix is to select by the (library, name)
;; identity the pre-expansion table holds, not by assq on spelling.
(import (rnrs))
(begin
  (library (a) (export mk) (import (rnrs)) (define-syntax mk (syntax-rules () ((_ x) (list x 0)))))
  (library (b) (export mk) (import (rnrs)) (define-syntax mk (syntax-rules () ((_ x) (list x 9)))))
  (import (a) (rename (b) (mk mk2))))
(display (list (mk 1) (mk2 2)))
