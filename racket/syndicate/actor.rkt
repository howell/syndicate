#lang racket/base

(provide actor
         dataspace
         ;; background
         state

         until
         forever

         assert!
         retract!
         patch!
         send!
         return!
         return/no-link-result!
         perform-core-action!

         ;; forall

         actor-body->spawn-action

         patch-without-linkage

         ;;----------------------------------------
         (struct-out actor-state)
         pretty-print-actor-state

         (for-syntax analyze-pattern)
         syndicate-actor-prompt-tag-installed?

         (struct-out predicate-match)
         match-value/captures
         )

(require (for-syntax racket/base))
(require (for-syntax racket/sequence))
(require "support/dsl.rkt")
(require "support/struct.rkt")
(require "pretty.rkt")
(require "treap.rkt")

(define&provide-dsl-helper-syntaxes "state/until/forever form"
  [on
   on-event
   during
   assert
   query

   asserted
   retracted
   message
   rising-edge

   exists
   ])

(require (for-syntax racket/match))
(require (for-syntax racket/list))
(require (for-syntax syntax/parse))
(require (for-syntax syntax/stx))

(require racket/set)
(require racket/match)

(require (except-in "core.rkt" assert dataspace)
         (rename-in "core.rkt" [assert core:assert] [dataspace core:dataspace]))
(require "trie.rkt")
(require "mux.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Actor State

;; A Variables is a (Vectorof Any), storing the explicit state
;; variables of an actor.

;; An Aggregates is a (Hashtable Nat Any), storing implicit state of
;; an actor, including queried and implicit aggregates.

;; A Script is a (-> Variables). It is to be executed inside
;; the special syndicate-hll prompt, and so may have Instruction
;; side-effects.

;; An Instruction is one of
;; - (patch-instruction Patch (Void -> Instruction))
;; - (action-instruction Action (Void -> Instruction))
;; - (return-instruction (Option (Listof Any)))
;; - (spawn-instruction LinkageKind (Symbol Symbol -> Spawn) (Void -> Instruction))
;; - (script-complete-instruction Variables)
;; and represents a side-effect for an actor to take in its
;; interactions with the outside world.
;;
;; A LinkageKind is one of
;; - 'call, a blocking, exception-linked connection
;; - 'actor, a non-blocking, non-exception-linked connection
;; - 'dataspace, a non-blocking, nested, non-exception-linked connection
;;
;; Patch Instructions are issued when the actor uses `assert!` and
;; `retract!`. Action instructions are issued when the actor uses
;; `perform-core-action!`, and return instructions when `return!` is
;; called. Script-complete instructions are automatically issued when
;; a Script terminates successfully.
;;
;; Spawn instructions are issued when `actor`, `dataspace`, and `state`
;; are used, directly or indirectly. (TODO: `background`?) The
;; spawn-action-producing function is given the IDs of the spawned and
;; spawning actors, and is to return an action which spawns the new
;; actor, which in turn engages in the appropriate linkage protocol
;; with the spawning actor. The (Void -> Instruction) continuation is
;; released when the spawned actor terminates (for blocking variants)
;; or immediately following the spawn (for non-blocking variants).
;;
;; (Background is done differently, with a new continuation for the
;; background script, and a self-send to activate it. (TODO))
;;
(struct patch-instruction (patch k) #:transparent)
(struct action-instruction (action k) #:transparent)
(struct return-instruction (result-values) #:transparent)
(struct spawn-instruction (linkage-kind action-fn k) #:transparent)
(struct script-complete-instruction (variables) #:transparent)

;; An ActorState is an (actor-state ... as below), describing the
;; state of an HLL actor.
;;
(struct actor-state (continuation-table ;; (Hashtable Symbol (Variables Any ... -> Instruction))
                     caller-id          ;; Symbol
                     self-id            ;; Symbol
                     variables          ;; Variables
                     aggregates         ;; Aggregates
                     pending-patch      ;; (Option Patch) - aggregate patch being accumulated
                     mux                ;; Mux
                     prev-assertions    ;; Trie - assertions from envt at the start of this event
                     curr-assertions    ;; Trie - prev-assertions, updated by the incoming event
                     )
  #:transparent
  #:methods gen:syndicate-pretty-printable
  [(define (syndicate-pretty-print s [p (current-output-port)])
     (pretty-print-actor-state s p))])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Linkage protocol
;;
;; Linkages are used to both propagate values from callee to caller
;; and to monitor callee presence for exception-propagation.
;;   - assertion: LinkActive
;;   - message: LinkResult
;;   - role: Caller
;;       Monitors LinkActive to detect termination of the Callee,
;;       normal or abnormal. If LinkResult is received before
;;       LinkActive vanishes, termination was normal; otherwise, it
;;       was abnormal.
;;   - role: Callee
;;       Asserts LinkActive while it runs. Should send LinkResult
;;       before termination to indicate success and communicate values
;;       to Caller.
;;
;; A LinkActive is a (link-active Symbol Symbol), describing an
;; ongoing relationship between the indicated caller and callee.
(struct link-active (caller-id callee-id) #:transparent)
;;
;; A LinkResult is a (link-result Symbol Symbol (Listof Any)),
;; describing the final values yielded by a callee to its caller.
(struct link-result (caller-id callee-id values) #:transparent) ;; message

;; Projection for observing LinkActive.
(define link-active-projection (link-active ? (?!)))

;; Assertions for patch-without-linkage to remove. TODO: this is gross.
(define linkage-assertions
  (trie-union-all #:combiner (lambda (v1 v2) (trie-success #t))
                  (list (pattern->trie #t (link-active ? ?))
                        (pattern->trie #t (observe (link-active ? ?)))
                        (pattern->trie #t (link-result ? ? ?))
                        (pattern->trie #t (observe (link-result ? ? ?))))))

;; Patch -> Patch
;; Remove linkage-related assertions.
(define (patch-without-linkage p)
  (patch-pruned-by p linkage-assertions))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Producing Instruction side-effects

(define prompt (make-continuation-prompt-tag 'syndicate-hll))

(define (syndicate-actor-prompt-tag-installed?)
  (continuation-prompt-available? prompt))

;; (Any ... -> Nothing) -> (Any ... -> Instruction)
(define (reply-to k)
  (lambda reply-values
    (call-with-continuation-prompt (lambda ()
                                     (apply k reply-values)
                                     (error 'reply-to "Script returned directly"))
                                   prompt)))

;; (-> Instruction) -> Nothing
(define (call-in-raw-context/abort proc)
  (abort-current-continuation prompt proc))

;; ((Any ... -> Instruction) -> Instruction)
(define (call-in-raw-context proc)
  (when (not (syndicate-actor-prompt-tag-installed?))
    (error 'call-in-raw-context
           "Attempt to invoke imperative Syndicate actor action outside actor context."))
  (call-with-composable-continuation
   (lambda (k) (abort-current-continuation prompt (lambda () (proc (reply-to k)))))
   prompt))

;; Returns void
(define (assert! P #:meta-level [meta-level 0])
  (call-in-raw-context
   (lambda (k) (patch-instruction (core:assert P #:meta-level meta-level) k))))

;; Returns void
(define (retract! P #:meta-level [meta-level 0])
  (call-in-raw-context
   (lambda (k) (patch-instruction (retract P #:meta-level meta-level) k))))

;; Returns void
(define (patch! p)
  (call-in-raw-context
   (lambda (k) (patch-instruction p k))))

;; Returns void
(define (send! M #:meta-level [meta-level 0])
  (perform-core-action! (message (prepend-at-meta M meta-level))))

;; Returns void
(define (perform-core-action! A)
  (call-in-raw-context
   (lambda (k) (action-instruction A k))))

;; Does not return to caller; instead, terminates the current actor
;; after sending a link-result to the calling actor.
(define (return! . result-values)
  (call-in-raw-context/abort
   (lambda () (return-instruction result-values))))

;; Does not return to caller; instead, terminates the current actor
;; without sending a link-result to the calling actor.
(define (return/no-link-result!)
  (call-in-raw-context/abort
   (lambda () (return-instruction #f))))

;; Returns new variables, plus values from spawned actor if any.
(define (spawn! linkage-kind action-fn)
  (call-in-raw-context
   (lambda (k) (spawn-instruction linkage-kind action-fn k))))

(begin-for-syntax
  (define-splicing-syntax-class init
    (pattern (~seq #:init [I ...]))
    (pattern (~seq) #:attr [I 1] '()))

  (define-splicing-syntax-class done
    (pattern (~seq #:done [I ...]))
    (pattern (~seq) #:attr [I 1] '()))

  (define-splicing-syntax-class bindings
    (pattern (~seq #:collect [(id init) ...]))
    (pattern (~seq) #:attr [id 1] '() #:attr [init 1] '())))

;; Syntax for spawning a 'call-linked actor.
(define-syntax (state stx)
  (syntax-parse stx
    [(_ init:init [bs:bindings O ...] [E Oe ...] ...)
     (expand-state 'call #'(init.I ...) #'(bs.id ...) #'(bs.init ...) #'(O ...) #'([E Oe ...] ...))]))

;; Sugar
(define-syntax (until stx)
  (syntax-parse stx
    [(_ E init:init done:done bs:bindings O ...)
     #'(state #:init [init.I ...] [#:collect [(bs.id bs.init) ...] O ...] [E done.I ... (values)])]))

;; Sugar
(define-syntax (forever stx)
  (syntax-parse stx
    [(_ init:init bs:bindings O ...)
     #'(state #:init [init.I ...] [#:collect [(bs.id bs.init) ...] O ...])]))

;; Spawn actors with 'actor linkage
(define-syntax (actor stx)
  (syntax-parse stx
    [(_ I ...)
     (expand-state 'actor #'(I ... (return/no-link-result!)) #'() #'() #'() #'())]))

;; Spawn whole dataspaces
(define-syntax (dataspace stx)
  (syntax-parse stx
    [(_ I ...)
     (expand-state 'dataspace
                   #'(I
                      ...
                      (perform-core-action! (quit-dataspace))
                      (return/no-link-result!))
                   #'()
                   #'()
                   #'()
                   #'())]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Main behavior of HLL actors

;; Special mux label used to track ad-hoc assertions
;; TODO: Revisit this, it is a bit ugly
(define *adhoc-label* -1)

;; Special mux label used to track linkage between actors.
;; TODO: Revisit this, it is a bit ugly
(define *linkage-label* -2)

;; Behavior
(define (generic-query-updater e s)
  (transition (if (patch? e)
                  (let ((t (actor-state-curr-assertions s)))
                    (struct-copy actor-state s
                                 [prev-assertions t]
                                 [curr-assertions (update-interests t e)]))
                  s)
              '()))

(define (interests-pre-and-post-patch s pat)
  (define (or* a b) (or a b))
  (define old (trie-lookup (actor-state-prev-assertions s) pat #f #:wildcard-union or*))
  (define new (trie-lookup (actor-state-curr-assertions s) pat #f #:wildcard-union or*))
  (values old new))

;; ActorState Pattern -> Boolean
(define (interest-just-appeared-matching? s pat)
  (define-values (old new) (interests-pre-and-post-patch s pat))
  (and (not old) new))

;; ActorState Pattern -> Boolean
(define (interest-just-disappeared-matching? s pat)
  (define-values (old new) (interests-pre-and-post-patch s pat))
  (and old (not new)))

;; Behavior
(define (generic-actor-behavior e s)
  (match e
    [(? patch/removed? p)
     (define continuation-table (actor-state-continuation-table s))
     (define quit?
       (for/or [(callee-id (trie-project/set/single (patch-removed p) link-active-projection))]
         (hash-has-key? continuation-table callee-id)))
     (if quit? ;; TODO: raise exception instead? Signal the cause of the quit somehow?
         (quit)
         #f)]
    [(message (link-result (== (actor-state-self-id s)) callee-id reply-values))
     ;; ^ NB. We, in principle, shouldn't need to check the
     ;; link-result's caller against our own self-id here, because
     ;; events should be routed to us only when generally falling
     ;; within our interests. First, the current implementation
     ;; overapproximates (though it could use a mux to be precise);
     ;; second, *in principle*, overapproximation should perhaps be
     ;; seen as OK, since routing may be able to be done much more
     ;; efficiently by overapproximating interest slightly. Imagine
     ;; using a bloom filter, for instance.
     (invoke-stored-continuation s callee-id reply-values)]
    [_ #f]))

;; ActorState Symbol (Variables Any ... -> Instruction) -> ActorState
(define (store-continuation s callee-id get-next-instr)
  (struct-copy actor-state s
               [continuation-table
                (hash-set (actor-state-continuation-table s)
                          callee-id
                          get-next-instr)]))

;; ActorState Symbol (Listof Any) -> Transition
(define (invoke-stored-continuation s callee-id reply-values)
  (define continuation-table (actor-state-continuation-table s))
  (define continuation (hash-ref continuation-table callee-id #f))
  (define new-table (hash-remove continuation-table callee-id))
  ;; (log-info "invoke-stored-continuation self=~a callee=~a values=~v k=~v"
  ;;           (actor-state-self-id s)
  ;;           callee-id
  ;;           reply-values
  ;;           continuation)
  (handle-actor-syscall (transition (struct-copy actor-state s [continuation-table new-table])
                                    '())
                        (apply continuation
                               (append reply-values (vector->list (actor-state-variables s))))))

;; ActorState -> Transition
(define (perform-pending-patch s)
  (transition (struct-copy actor-state s [pending-patch #f]) (actor-state-pending-patch s)))

;; Label Patch -> ActorState -> Transition
(define ((extend-pending-patch label p) s)
  (define-values (new-mux _label _p p-aggregate)
    (mux-update-stream (actor-state-mux s) label p))
  (define p0 (actor-state-pending-patch s))
  (define new-pending-patch (if p0 (patch-seq p0 p-aggregate) p-aggregate))
  (transition (struct-copy actor-state s
                           [pending-patch new-pending-patch]
                           [mux new-mux])
              '()))

;; ActorState Script -> Transition
(define (run-script s script)
  (handle-actor-syscall (transition s '())
                        ((reply-to (lambda (dummy)
                                     (define new-variables (script))
                                     (call-in-raw-context/abort
                                      (lambda ()
                                        (script-complete-instruction new-variables)))))
                         (void))))

(define (actor-body->spawn-action thunk)
  (match ((reply-to (lambda (dummy)
                      (actor (thunk))
                      (error '%%boot "Reached end of boot thunk")))
          (void))
    [(spawn-instruction 'actor action-fn _get-next-instr)
     (action-fn (gensym 'root-actor) (gensym 'boot-actor))]))

;; Transition Instruction -> Transition
(define (handle-actor-syscall t instr)
  (match instr
    [(patch-instruction p get-next-instr)
     (handle-actor-syscall (sequence-transitions t
                                                 (extend-pending-patch *adhoc-label* p))
                           (get-next-instr (void)))]
    [(action-instruction a get-next-instr)
     (handle-actor-syscall (sequence-transitions t
                                                 perform-pending-patch
                                                 (lambda (s) (transition s a)))
                           (get-next-instr (void)))]
    [(return-instruction result-values)
     (sequence-transitions t
                           perform-pending-patch
                           (lambda (s)
                             (if result-values
                                 (quit (message (link-result (actor-state-caller-id s)
                                                             (actor-state-self-id s)
                                                             result-values)))
                                 (quit))))]
    [(spawn-instruction linkage-kind action-fn get-next-instr)
     (define blocking? (eq? linkage-kind 'call))
     (define next-t
       (sequence-transitions t
                             perform-pending-patch
                             (lambda (s)
                               (define callee-id (gensym linkage-kind))
                               (define spawn-action (action-fn callee-id (actor-state-self-id s)))
                               (transition (if blocking?
                                               (store-continuation s callee-id get-next-instr)
                                               s)
                                           (if (eq? linkage-kind 'dataspace)
                                               (spawn-dataspace spawn-action)
                                               spawn-action)))))
     (if blocking?
         next-t
         (handle-actor-syscall next-t (get-next-instr (void))))]
    [(script-complete-instruction new-variables)
     (sequence-transitions t
                           ;; NB: Does not perform-pending-patch here.
                           ;; Instead, the script runner will now
                           ;; update ongoing subscriptions and
                           ;; incorporate the pending patch into that
                           ;; process.
                           (lambda (s)
                             (transition (struct-copy actor-state s [variables new-variables])
                                         '())))]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Compilation of HLL actors

;; TODO: query
;; TODO: default to hll
;; TODO: some better means of keeping track of nested dataspace levels

(begin-for-syntax
  (define-splicing-syntax-class when-pred
    (pattern (~seq #:when Pred))
    (pattern (~seq) #:attr Pred #'#t))

  (define-splicing-syntax-class meta-level
    (pattern (~seq #:meta-level level:integer))
    (pattern (~seq) #:attr level #'0))

  (define (expand-state linkage-kind init-actions binding-names binding-inits ongoings edges)
    ;; ----------------------------------------
    (define binding-count (length (syntax->list binding-names)))
    ;; ----------------------------------------
    ;; A StageProducer is a ((Syntax <Expr:Event>) -> (Syntax <Expr:(ActorState -> Transition)>)).
    ;; It computes a behavior stage suitable for composition using sequence-transitions.
    ;; It is given syntax for an expression yielding the actor's current event.

    ;; Records syntaxes for aggregate initializers.
    ;; (Boxof (Listof (Syntax <Expr:Any>)))
    (define aggregate-init-stxs (box '()))

    ;; Records aggregate updaters.
    ;; (Boxof (Listof StageProducer))
    (define query-updaters (box '()))

    ;; Records both actual event handlers and termination check handlers.
    ;; (Boxof (Listof StageProducer))
    (define event-handlers (box '()))

    ;; (Boxof (Listof StageProducer))
    (define assertion-maintainers (box '()))

    (define (box-adjoin! v val) (set-box! v (append (unbox v) (list val))))
    ;; ----------------------------------------

    (define (allocate-aggregate! init-stx)
      (box-adjoin! aggregate-init-stxs init-stx)
      (- (length (unbox aggregate-init-stxs)) 1))

    ;; StageProducer -> Void
    (define (add-query-updater! stage-producer) (box-adjoin! query-updaters stage-producer))
    (define (add-event-handler! stage-producer) (box-adjoin! event-handlers stage-producer))

    (define (mapply v fs) (map (lambda (f) (f v)) fs))

    (define (make-run-script-call outer-expr-stx state-stx I-stxs)
      (cond
        [(zero? binding-count)
         #`(run-script #,state-stx (lambda ()
                                     #,@I-stxs
                                     (vector)))]
        [(stx-null? I-stxs)
         (raise-syntax-error #f "Empty expression sequence not permitted" outer-expr-stx I-stxs)]
        [else
         #`(run-script #,state-stx (lambda ()
                                     (call-with-values (lambda () #,@I-stxs)
                                                       vector)))]))

    (define (add-assertion-maintainer! endpoint-index
                                       assert-stx
                                       pat-stx
                                       maybe-Pred-stx
                                       L-stx)
      (box-adjoin! assertion-maintainers
                   (lambda (evt-stx)
                     #`(lambda (s)
                         (match-define (vector #,@binding-names)
                           (actor-state-variables s))
                         (define old-assertions
                           (strip-interests
                            (mux-interests-of (actor-state-mux s) #,endpoint-index)))
                         (define (compute-new-assertions)
                           (patch-added (#,assert-stx #,pat-stx #:meta-level #,L-stx)))
                         (define new-assertions
                           #,(if maybe-Pred-stx
                                 #`(if #,maybe-Pred-stx
                                       (compute-new-assertions)
                                       trie-empty)
                                 #`(compute-new-assertions)))
                         (and (not (eq? old-assertions new-assertions))
                              ((extend-pending-patch
                                #,endpoint-index
                                (patch-seq (patch trie-empty old-assertions)
                                           (patch new-assertions trie-empty)))
                               s))))))

    (define (analyze-asserted-or-retracted! endpoint-index asserted? outer-expr-stx P-stx I-stxs L-stx)
      (define-values (proj-stx pat bindings _instantiated)
        (analyze-pattern outer-expr-stx P-stx))
      (add-assertion-maintainer! endpoint-index #'sub pat #f L-stx)
      (add-event-handler!
       (lambda (evt-stx)
         #`(let* ((proj (prepend-at-meta #,proj-stx #,L-stx))
                  (proj-arity (projection-arity proj)))
             (lambda (s)
               (match #,evt-stx
                 [(? #,(if asserted? #'patch/added? #'patch/removed?) p)
                  (sequence-transitions0*
                   s
                   (for/list [(entry (in-set (trie-project/set
                                              #:take proj-arity
                                              #,(if asserted?
                                                    #'(patch-added p)
                                                    #'(patch-removed p))
                                              proj)))]
                     (lambda (s)
                       (define instantiated (instantiate-projection proj entry))
                       (and (#,(if asserted?
                                   #'interest-just-appeared-matching?
                                   #'interest-just-disappeared-matching?) s instantiated)
                            (match (actor-state-variables s)
                              [(vector #,@binding-names)
                               (match-define (list #,@bindings) entry)
                               #,(make-run-script-call outer-expr-stx #'s I-stxs)])))))]
                 [_ #f]))))))

    (define (prepend-at-meta-stx context-stx stx level)
      (if (zero? level)
          stx
          #`(at-meta #,(prepend-at-meta-stx context-stx stx (- level 1)))))

    (define (analyze-message-subscription! endpoint-index outer-expr-stx P-stx I-stxs L-stx)
      (define-values (proj pat bindings _instantiated)
        (analyze-pattern outer-expr-stx P-stx))
      (add-assertion-maintainer! endpoint-index #'sub pat #f L-stx)
      (add-event-handler!
       (lambda (evt-stx)
         #`(lambda (s)
             (match (actor-state-variables s)
               [(vector #,@binding-names)
                (match #,evt-stx
                  [(message body)
                   (define capture-vals
                     (match-value/captures body
                                           #,(prepend-at-meta-stx outer-expr-stx
                                                                  proj
                                                                  (syntax-e L-stx))))
                   (and capture-vals
                        (apply (lambda #,bindings
                                 #,(make-run-script-call outer-expr-stx #'s I-stxs))
                               capture-vals))]
                  [_ #f])])))))

    (define (analyze-event! index E-stx I-stxs)
      (syntax-parse E-stx
        #:literals [asserted retracted message rising-edge]
        [(asserted P L:meta-level)
         (analyze-asserted-or-retracted! index #t E-stx #'P I-stxs #'L.level)]
        [(retracted P L:meta-level)
         (analyze-asserted-or-retracted! index #f E-stx #'P I-stxs #'L.level)]
        [(message P L:meta-level)
         (analyze-message-subscription! index E-stx #'P I-stxs #'L.level)]
        [(rising-edge Pred)
         ;; TODO: more kinds of Pred than just expr
         (define aggregate-index (allocate-aggregate! #'#f))
         (add-event-handler!
          (lambda (evt-stx)
            #`(lambda (s)
                (match-define (vector #,@binding-names) (actor-state-variables s))
                (define old-val (hash-ref (actor-state-aggregates s) #,aggregate-index))
                (define new-val Pred)
                (if (eq? old-val new-val)
                    #f
                    (let ((s (struct-copy actor-state s
                                          [aggregates (hash-set (actor-state-aggregates s)
                                                                #,aggregate-index
                                                                new-val)])))
                      (if new-val
                          #,(make-run-script-call E-stx #'s I-stxs)
                          (transition s '())))))))]))

    (define (analyze-during! index P-stx O-stxs)
      (define E-stx #`(asserted #,P-stx))
      (define-values (_proj _pat _bindings instantiated) (analyze-pattern E-stx P-stx))
      (define I-stx #`(until (retracted #,instantiated) #,@O-stxs))
      (analyze-event! index E-stx #`(#,I-stx)))

    (define (analyze-assertion! index Pred-stx outer-expr-stx P-stx L-stx)
      (define-values (proj pat bindings _instantiated)
        (analyze-pattern outer-expr-stx P-stx))
      (add-assertion-maintainer! index #'core:assert pat Pred-stx L-stx))

    (define (analyze-on-event! index clauses-stx outer-expr-stx)
      (add-event-handler!
       (lambda (evt-stx)
         #`(lambda (s)
             (match (actor-state-variables s)
               [(vector #,@binding-names)
                (match #,evt-stx
                  #,@(for/list [(clause-stx (syntax->list clauses-stx))]
                       (syntax-case clause-stx ()
                         [(pat #:when cond-expr body ...)
                          #`(pat #:when cond-expr #,(make-run-script-call outer-expr-stx #'s #'(body ...)))]
                         [(pat body ...)
                          #`(pat #,(make-run-script-call outer-expr-stx #'s #'(body ...)))]))
                  [_ #f])])))))

    (define (analyze-queries! index query-spec-stxs I-stxs)
      (error 'analyze-queries! "unimplemented"))

    ;; Query analysis happens first, because we need the queried
    ;; bindings to be in scope everywhere else.
    (for [(ongoing (in-list (syntax->list ongoings)))
          (ongoing-index (in-naturals))]
      (syntax-parse ongoing
        #:literals [query]
        [(query [query-spec ...] I ...)
         (analyze-queries! ongoing-index #'(query-spec ...) #'(I ...))]
        [_ (void)]))

    ;; Now make another pass over the ongoings, ignoring queries this
    ;; time.
    (for [(ongoing (in-list (syntax->list ongoings)))
          (ongoing-index (in-naturals))]
      (syntax-parse ongoing
        #:literals [on on-event during assert query]
        [(on E I ...)
         (analyze-event! ongoing-index #'E #'(I ...))]
        [(on-event clause ...)
         (analyze-on-event! ongoing-index #'(clause ...) ongoing)]
        [(during P O ...)
         (analyze-during! ongoing-index #'P #'(O ...))]
        [(assert w:when-pred P L:meta-level)
         (analyze-assertion! ongoing-index #'w.Pred ongoing #'P #'L.level)]
        [(query [query-spec ...] I ...)
         (void)]))

    ;; Finally, add in the termination conditions...
    (for [(edge (in-list (syntax->list edges)))
          (edge-index (in-naturals (length (syntax->list ongoings))))]
      (syntax-parse edge
        [(E I0 I ...)
         (analyze-event! edge-index #'E #'((call-with-values (lambda () I0 I ...) return!)))]))

    ;; ...the generic query-updater...
    (add-query-updater!
     (lambda (evt-stx)
       #`(lambda (s) (generic-query-updater #,evt-stx s))))

    ;; ...and generic linkage-related behaviors.
    (add-event-handler!
     (lambda (evt-stx)
       #`(lambda (s) (generic-actor-behavior #,evt-stx s))))

    (define action-fn-stx
      #`(lambda (self-id caller-id)
          (<spawn>
           (lambda ()
             (define ((maintain-assertions e) s)
               (sequence-transitions0 s #,@(mapply #'e (unbox assertion-maintainers))))

             (define (behavior e s)
               (and e
                    (sequence-transitions0 s
                                           #,@(mapply #'e (unbox query-updaters))
                                           #,@(mapply #'e (unbox event-handlers))
                                           (maintain-assertions e)
                                           perform-pending-patch)))

             (define initial-state
               (actor-state (hasheq)
                            caller-id
                            self-id
                            (vector #,@binding-inits)
                            (make-immutable-hash
                             (list
                              #,@(for/list [(init-stx (unbox aggregate-init-stxs))
                                            (init-idx (in-naturals))]
                                   #`(cons #,init-idx #,init-stx))))
                            #f
                            (mux)
                            trie-empty
                            trie-empty))

             (define (subscribe-to-linkage s)
               (define sub-to-callees
                 (patch-seq (sub (link-active self-id ?))
                            (sub (link-result self-id ? ?))))
               (define initial-subs
                 #,(if (eq? linkage-kind 'call)
                       #`(patch-seq sub-to-callees
                                    (core:assert (link-active caller-id self-id)))
                       #`sub-to-callees))
               ((extend-pending-patch *linkage-label* initial-subs) s))

             (define (run-init-actions s)
               (match (actor-state-variables s)
                 [(vector #,@binding-names)
                  ;; TODO: At the moment we are *not* letting the
                  ;; init-actions update the variables. Is this the
                  ;; right thing?
                  ;; TODO: what about intermediate (state)s? How are the variables updated?
                  (run-script s (lambda ()
                                  #,@init-actions
                                  (vector #,@binding-names)))]))

             (list behavior
                   (sequence-transitions0 initial-state
                                          subscribe-to-linkage
                                          (maintain-assertions #f)
                                          perform-pending-patch
                                          run-init-actions))))))

    ;; (local-require racket/pretty)
    ;; (pretty-print (syntax->datum action-fn-stx))

    #`(let ((do-spawn (lambda () (spawn! '#,linkage-kind #,action-fn-stx))))
        (if (syndicate-actor-prompt-tag-installed?)
            (do-spawn)
            (actor-body->spawn-action do-spawn))))
  )

    ;; ;; Given a Pred, computes (and perhaps allocates):
    ;; ;;   - an optional StageProducer for taking on board information from the outside world
    ;; ;;   - syntax for retrieving the current value of the Pred
    ;; ;;   - syntax for evaluating a new value for the Pred
    ;; ;;   - optional syntax for an updater for an aggregate
    ;; ;; (Syntax <Pred>) -> (Values (Option StageProducer)
    ;; ;;                            (Syntax <Expr:Boolean>)
    ;; ;;                            (Syntax <Expr:Boolean>)
    ;; ;;                            (Option (Syntax <Expr:(Any ActorState -> ActorState)>)))
    ;; (define (analyze-pred! Pred-stx)
    ;;   (syntax-parse Pred-stx
    ;;     #:literals [not or and exists]
    ;;     [(not Pred)
    ;;      (define-values (upd curr next store) (analyze-pred! #'Pred))
    ;;      (values upd #`(not #,curr) #`(not ,next))]
    ;;     [((~and HEAD (~or or and)) PredN ...)
    ;;      (define-values (upds currs nexts) (analyze-preds! #'(PredN ...)))
    ;;      (values (and (not (null? upds))
    ;;                   (lambda (evt-stx)
    ;;                     #`(lambda (s) (sequence-transitions0 s #,@(mapply evt-stx upds)))))
    ;;              #`(HEAD #,@currs)
    ;;              #`(HEAD #,@nexts))]
    ;;     [(exists P Pred)
    ;;      ...]

    ;;     [expr
    ;;      (define index (allocate-aggregate!))
    ;;      (values #f
    ;;              #'
    ;;      ...]))

    ;; (define (analyze-preds! Pred-stxs)
    ;;   (define-values (upds-rev currs-rev nexts-rev)
    ;;     (for/fold [(upds-rev '())
    ;;                (currs-rev '())
    ;;                (nexts-rev '())]
    ;;               [(Pred-stx (in-list (syntax->list Pred-stxs)))]
    ;;       (define-values (upd curr next) (analyze-pred! Pred-stx))
    ;;       (values (if upd (cons upd upds-rev) upds-rev)
    ;;               (cons curr currs-rev)
    ;;               (cons next nexts-rev))))
    ;;   (values (reverse upds-rev)
    ;;           (reverse currs-rev)
    ;;           (reverse nexts-rev)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; HLL pattern analysis

(begin-for-syntax
  (define (dollar-id? stx)
    (and (identifier? stx)
         (char=? (string-ref (symbol->string (syntax-e stx)) 0) #\$)))

  (define (undollar stx)
    (and (dollar-id? stx)
         (datum->syntax stx (string->symbol (substring (symbol->string (syntax-e stx)) 1)))))

  ;; Syntax -> (Values Projection AssertionSetPattern (ListOf Identifier) Syntax)
  (define (analyze-pattern outer-expr-stx pat-stx0)
    (let walk ((pat-stx pat-stx0))
      (syntax-case pat-stx ($ ? quasiquote unquote quote)
        ;; Extremely limited support for quasiquoting and quoting
        [(quasiquote (unquote p)) (walk #'p)]
        [(quasiquote (p ...)) (walk #'(list (quasiquote p) ...))]
        [(quasiquote p) (values #''p #''p '() #''p)]
        [(quote p) (values #''p #''p '() #''p)]

        [$v
         (dollar-id? #'$v)
         (with-syntax [(v (undollar #'$v))]
           (values #'(?!)
                   #'?
                   (list #'v)
                   #'v))]

        [($ v p)
         (let ()
           (define-values (pr g bs _ins) (walk #'p))
           (when (not (null? bs))
             (raise-syntax-error #f "nested bindings not supported" outer-expr-stx pat-stx))
           (values #`(?! #,pr)
                   g
                   (list #'v)
                   #'v))]

        [(? pred? p)
         ;; TODO: support pred? in asserted/retracted as well as message events
         (let ()
           (syntax-parse outer-expr-stx
             #:literals [message]
             [(message _ ...) 'ok]
             [_ (raise-syntax-error #f
                                    "Predicate '?' matching only supported in message events"
                                    outer-expr-stx
                                    pat-stx)])
           (define-values (pr g bs ins) (walk #'p))
           (values #`(predicate-match pred? #,pr)
                   g
                   bs
                   ins))]

        [(ctor p ...)
         (let ()
           (define parts (if (identifier? #'ctor) #'(p ...) #'(ctor p ...)))
           (define-values (pr g bs ins)
             (for/fold [(pr '()) (g '()) (bs '()) (ins '())] [(p (syntax->list parts))]
               (define-values (pr1 g1 bs1 ins1) (walk p))
               (values (cons pr1 pr)
                       (cons g1 g)
                       (append bs bs1)
                       (cons ins1 ins))))
           (if (identifier? #'ctor)
               (values (cons #'ctor (reverse pr))
                       (cons #'ctor (reverse g))
                       bs
                       (cons #'ctor (reverse ins)))
               (values (reverse pr)
                       (reverse g)
                       bs
                       (reverse ins))))]

        [?
         (raise-syntax-error #f
                             "Invalid use of '?' in pattern; use '_' instead"
                             outer-expr-stx
                             pat-stx)]

        [non-pair
         (if (and (identifier? #'non-pair)
                  (free-identifier=? #'non-pair #'_))
             (values #'?
                     #'?
                     '()
                     #'_)
             (values #'non-pair
                     #'non-pair
                     '()
                     #'non-pair))])))

  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(struct predicate-match (predicate sub-pattern) #:transparent)

;; Value Projection -> (Option (Listof Value))
;; Match a single value against a projection, returning a list of
;; captured values.
(define (match-value/captures v p)
  (define captures-rev
    (let walk ((v v) (p p) (captures-rev '()))
      (match* (v p)
        [(_ (capture sub))
         (match (walk v sub '())
           [#f #f]
           ['() (cons v captures-rev)]
           [_ (error 'match-value/captures "Bindings in capture sub-patterns not supported")])]
        [(_ (predicate-match pred? sub)) #:when (pred? v)
         (walk v sub captures-rev)]
        [(_ (== ?))
         captures-rev]
        [((cons v1 v2) (cons p1 p2))
         (match (walk v1 p1 captures-rev)
           [#f #f]
           [c (walk v2 p2 c)])]
        [((? vector? v) (? vector? p)) #:when (= (vector-length v) (vector-length p))
         (for/fold [(c captures-rev)] [(vv (in-vector v)) (pp (in-vector p))]
           (walk vv pp c))]
        [(_ _) #:when (or (treap? v) (treap? p))
         (error 'match-value/captures "Cannot match on treaps at present")]
        [((? non-object-struct?) (? non-object-struct?))
         #:when (eq? (struct->struct-type v) (struct->struct-type p))
         (walk (struct->vector v) (struct->vector p) captures-rev)]
        [(_ _) #:when (equal? v p)
         captures-rev]
        [(_ _)
         #f])))
  (and captures-rev (reverse captures-rev)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (pretty-print-actor-state s [p (current-output-port)])
  (match-define
    (actor-state continuation-table
                 caller-id
                 self-id
                 variables
                 aggregates
                 pending-patch
                 mux
                 prev-assertions
                 curr-assertions)
    s)
  (fprintf p "ACTOR id ~a (caller-id ~a):\n" self-id caller-id)
  (fprintf p " - ~a pending continuations\n" (hash-count continuation-table))
  (fprintf p " - variables:\n")
  (for ((v variables))
    (fprintf p "    - ")
    (display (indented-port-output 6 (lambda (p) (syndicate-pretty-print v p)) #:first-line? #f) p)
    (newline p))
  (fprintf p " - aggregates:\n")
  (for (((index a) (in-hash aggregates)))
    (define leader (format "    - ~a: " index))
    (fprintf p "~a" leader)
    (display (indented-port-output #:first-line? #f
                                   (string-length leader)
                                   (lambda (p) (syndicate-pretty-print a p)))
             p)
    (newline p))
  (fprintf p " - pending-patch:\n")
  (display (indented-port-output 3 (lambda (p) (syndicate-pretty-print pending-patch p))) p)
  (newline p)
  (fprintf p " - previous assertions from the environment:\n   ")
  (pretty-print-trie prev-assertions p #:indent 3)
  (newline p)
  (fprintf p " - current assertions from the environment:\n   ")
  (pretty-print-trie curr-assertions p #:indent 3)
  (newline p)
  (fprintf p " - ")
  (display (indented-port-output 3 (lambda (p) (syndicate-pretty-print mux p)) #:first-line? #f) p)
  (newline p))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(module+ test
  (require rackunit)

  (check-equal? (match-value/captures (list 1 2 3)
                                      (list 1 2 3))
                '())
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list 1 22 3))
                #f)
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) (?!) (?!)))
                (list 1 2 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) 2 (?!)))
                (list 1 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) ? (?!)))
                (list 1 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) (?! 2) (?!)))
                (list 1 2 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) (?! 22) (?!)))
                #f)

  (struct x (a b) #:prefab)
  (struct y (z w) #:prefab)

  (check-equal? (match-value/captures (x 1 2) (x 1 2)) '())
  (check-equal? (match-value/captures (x 1 22) (x 1 2)) #f)
  (check-equal? (match-value/captures (x 1 2) (x 1 22)) #f)
  (check-equal? (match-value/captures (x 1 2) (?! (x ? ?))) (list (x 1 2)))
  (check-equal? (match-value/captures (x 1 2) (?! (x ? 2))) (list (x 1 2)))
  (check-equal? (match-value/captures (x 1 2) (?! (x ? 22))) #f)

  (check-equal? (match-value/captures 123 (predicate-match even? ?)) #f)
  (check-equal? (match-value/captures 124 (predicate-match even? ?)) '())
  (check-equal? (match-value/captures (list 123) (list (predicate-match even? ?))) #f)
  (check-equal? (match-value/captures (list 124) (list (predicate-match even? ?))) '())
  (check-equal? (match-value/captures (list 124) (?! (list (predicate-match even? ?)))) '((124))))
