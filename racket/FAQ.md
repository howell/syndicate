# FAQ

* How do I run a syndicate program?
  - `#lang syndicate` collects actions (`spawn`s) from module toplevel and
  uses them as boot actions for a ground-level dataspace. The alternative
  is to use a different #lang, and to call `run-ground` yourself; see an
  example in syndicate/examples/example-plain.rkt.

* How do I debug a syndicate program?
  - You can view a colored trace of a program's execution on stderr by setting the MINIMART_TRACE environment variable, e.g.

    ```
    $ MINIMART_TRACE=xetpag racket foo.rkt
    ```

    shows  
    x - exceptions  
    e - events  
    t - process states (after they handle each event)  
    p - lifecycle events (spawns, crashes, and quits)  
    a - process actions  
    g - dataspace contents  
    Adding 'N' will show whole dataspace-states too. Remove each individual
    character to turn off the corresponding trace facility; the default
    value of the variable is just the empty-string.

  - For a more fine-grained approach, there are several ways to print specific patches/tries inside your program:

    ```racket
    pretty-print-patch     ;; (patch trie trie)
    pretty-print-trie
    patch->pretty-string
    trie->pretty-string
    trie->abstract-graph
    abstract-graph->dot
    trie->dot           ;; handy for visualizing the trie structure
    ```
* How do spawned processes communicate with one another?

  | Expression  | Effect of resulting patch  | Meaning                                           |
  | ----------  | -------------------------- | -------                                           |
  | (assert X)  | X will be asserted         | claim of X                                        |
  | (retract X) | X will be retracted        | remove claim                                      |
  | (sub X)     | (observe X) asserted       | claim interest in X                               |
  | (unsub X)   | (observe X) retracted      | unsubscribe                                       |
  | (pub X)     | (advertise X) asserted     | claim intent to claim X (or possibility of claim) |
  | (unpub X)   | (advertise X) retracted    |                                                   |

  Those all construct **patch** actions. Separately, there are **message** actions:

  | Expression  | Effect of resulting action                        | Meaning                 |
  | ----------  | --------------------------                        | -------                 |
  | (message X) | routes X via dataspace via (observe X) assertions | subscribers to X get it |

* What is the difference between `pub` and `assert`?
  - `(pub X)` is intended to mean *advertisement* of its body, rather than assertion.
  So `(assert X)` yields a patch that means "I assert X", while
  `(pub X)` yields a patch that means "I assert (advertise X)", or
  interpreted more freely, "I might in future assert X".

* How do I create a process/actor?
  ```racket
  ;; single actor
  (spawn (lambda (event state) ... (transition state' (list action ...)))
         initial-state
         initial-action ...)
  ;; stateless actor
  (spawn/stateless (lambda (event) ... (list action ...))
                   initial-action ...)
  ;; dataspace of actors
  (spawn-dataspace boot-action ...)
  ```

* How do actors at different levels communicate?
  - `at-meta` (the harpoon-marker from the paper) denotes "at the next level out" -
  so, you might send
  ```racket
  (message 'hello)
  (message (at-meta 'hello))
  ```
  and the former would go to your local peers, while the latter would go
  to peers one level out from you. Likewise,
  ```racket
  (sub 'hello)
  (sub 'hello #:meta-level 1)
  ```
  evaluate to
  ```racket
  (observe 'hello)
  (patch-union (observe (at-meta 'hello))
               (at-meta (observe 'hello)))
  ```

  The latter is a bit surprising-looking perhaps. It asserts **two** items:
  the first says
  > HERE, I am interested in assertions 'hello labelled with "OVER THERE"

  while the second says
  > OVER THERE, I am interested in assertions 'hello

  The former is necessary for the local dataspace to route events to us, and
  the latter is necessary for the remote dataspace to route events to the
  local dataspace.

  Implicit in any `sub` call with N>0 meta-level, therefore, is the
  construction of a whole *chain* of subscriptions, relaying information
  up in N+1 hops across N+1 boundaries between nested actors.

* Do I need to keep track of everything a process is asserting in order to retract only what is appropriate?
  - No. You can often avoid needing to remember state like this explicitly by
  using wildcard retractions:

    ```racket
    (list (retract `(key ,?))
          (assert `(key ,new-key-value)))
    ```

    One potential issue with this is it generates two observable events.
    That is, there is a window of time when the old term has been retracted
    but the new has not yet been asserted. Implicit in this is the idea that
    the actions an event-handler produces are performed **in order**, and you
    can rely on that in NC. So in the example above, the retraction will
    logically happen before the assertion. You can avoid this by using
    `patch-seq` instead, to combine patches into a single equivalent patch:

    ```racket
    (patch-seq (retract `(key ,?))
               (assert `(key ,new-key-value)))
     ```


* How do I get the assertions out of a patch?
  - A patch consists of two tries, added and removed
  - To get assertions out of a trie, you have to decide what sort of assertions
  you are interested in, compile a pattern for those assertions, and pass that
  along with the trie to `trie-project/set`.
  - `trie-project/set` takes a trie and a pattern and returns a set of lists
  - Say you are in interested in assertions of the shape `(posn x y)` for all `x` and `y`
    within some assertion-set `asserions`.
    * call `(trie-project/set #:take 2 assertions (posn (?!) (?!)))`
    * the `(?!)` is for **capturing** the matched value. Use `?` if you want to
      match but don't care about the actual value.
    * the lists returned by `trie-project/set` contain the captured values in
      order.
    * the argument to `#:take` must match the number of captures in
      the pattern. Use `projection-arity` if you don't statically know
      this number.
  - Say we are receiving a patch p where the assertion `(posn 2 3)` was added.
  - The result of

    ```racket
    (trie-project/set #:take 2 (patch-added p) (posn (?!) (?!)))
    ```
    would be `(set (list 2 3))`.
  - If we only cared about the y position, we could instead do

    ```racket
    (trie-project/set #:take 1 (patch-added p) (posn ? (?!)))
    ```
    and get the result `(set (list 3))`.
  - an entire structure can be captured by passing a pattern as an argument to
    `(?!)`.

    ```racket
    (trie-project/set #:take 1 (patch-added p) (?! (posn ? ?)))
    ```
    with the same example yields `(set (posn 2 3))`.
  - `trie-project/set/single` is like mapping `car` over the result of
  `trie-project/set`. See also `project-assertions`.
  - `patch-project/set` uses `values` to return the result of matching a projection
  against both the added and removed bits of a patch.

* What is the distinction between `(assert X)` and `(message X)`?
  - Time. An assertion is visible to anyone interested in it from when it is
  asserted until when it is retracted. A message, on the other hand, is transient.
  When a message is sent, it is delivered to everyone that is interested in it
  **at that time**.

* How to inject an external event (e.g. keyboard press) into the dataspace?
  - Use `send-ground-message`.
  - (Note that the argument to `send-ground-message` is wrapped in a `message`,
  so to send `'foo` at the ground level use `(send-ground-message 'foo)` rather than
  `(send-ground-message (message 'foo))`)

* My GUI program isn't working!
  - Eventspaces. Wrap your GUI code with
  ```racket
  (parameterize ((current-eventspace (make-eventspace)))
    ...)
  ```

* I used `spawn` but the actor isn't being created. What happened?
  - The only two ways to spawn a process are to (a) supply the spawn instruction in
  that dataspace's boot-actions, or (b) have some already-existing actor supply the
  spawn instruction in response to some event it receives. Note that calling `spawn`
  constructs a structure which is perhaps eventually interpreted by the containing
  dataspace of an actor; it doesn't really "do" anything directly.

* Why does `patch-seq` exist? Aren't all the actions in a transition effectively `patch-seq`d together?
  - Effectively, yes, that is what happens. The difference is in the
    granularity of the action: when issuing *separate patch actions*, it's
    possible for an observer to observe a moment *in between* the adjacent
    patches, with the dataspace in an intermediate state.

    Patch-seq combines multiple patches into a single patch having the same
    effect as the sequence of individual patches.

    By combining a bunch of patch actions into a single action, there is no
    opportunity for a peer to observe some intermediate state. The peer only
    gets to observe things-as-they-were-before-the-patch, and
    things-as-they-are-after-the-patch.

* How do I create a tiered dataspace, such as
  ```
        ground
      /         \
 net1           net2
                   \
                   net3
  ```
  - use `spawn-dataspace`:
  ```racket
  #lang syndicate
  (spawn-dataspace <net1-spawns> ...)
  (spawn-dataspace <net2-spawns> ...
                   (spawn-dataspace <net3-spawns> ...))
  ```
  `spawn-dataspace` expands into a regular `spawn` with an event-handler and
  state corresponding to a whole VM. The arguments to spawn-dataspace are
  actions to take at boot time in the new VM.

* What is the outcome if I do `(assert X)` and then later `(patch-seq (retract ?) assert X)`?
  - if you started with the set Y of assertions, you'd go to Y + {X}, then just {X}.

* Can a message be included in the initial actions of a process?

  - At the moment they are not allowed in the implementation;
    this is more restrictive than the calculus, where any action is
    permitted in a boot action.

	If I remember right, the reason they are not allowed is to do with
	atomic assignment of responsibilities at spawn time.

	Imagine a socket listener detects some shared state that indicates a new
	socket is waiting to be accepted. It decides to spawn a process to
	handle the new connection.

	The protocol for sockets involves maintaining shared state signalling
	the willingness of each end to continue. Once such a signal is asserted,
	it must be maintained continuously, because its retraction signals
	disconnection.

	So the newly-spawned process must signal this state. If it is spawned
	without the state included in its assertions, then it must assert the
	state later on. But what if it fails to do so? Then it's violating it's
	implicit contract with the peer - a kind of denial of service. What if
	it fails to do so because it *crashes* before it has a chance to? Then
	the peer will hang forever waiting for something to happen.

	For this reason, it is possible to spawn processes with nonempty
	assertion sets. The assertions take effect atomically with the creation
	of the process itself. So the spawning process can atomically "assign
	responsibility" to the spawned process, giving it no opportunity to
	crash before the necessary shared state has been asserted.

	The current implementation is problematic though. The computation of the
	initial patch is being done in the context of the spawned process, which
	means that if it crashes computing the initial patch, only the spawned
	process is killed - the spawning process is not signalled. More thought
	required.

* Can I split a syndicate program across multiple files?
  - Only one module with `#lang syndicate` can be used at a time.

* Why does `#f` keep getting sent as an event?
  - When a behavior returns something besides `#f` in response to an event, it is
  repeatedly sent `#f` until it does return `#f`.
  - Think of it as a way of the dataspace asking "anything else?"
