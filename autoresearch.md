# Autoresearch: Ori Scope Performance

## Objective
Minimize framework overhead in Ori's Scope (the fiber scheduler / event loop) to maximize operations/sec. The benchmark exercises all major primitives: fork/join, channels, promises, semaphores, broadcast, select, nested scopes, and mixed workloads.

## Metrics
- **Primary**: `ops_per_sec` (higher is better) — total benchmark operations per second
- **Secondary**: `total_ms`, `fork_join_ms`, `channel_ms`, `promise_ms`, `semaphore_ms`, `broadcast_ms`, `select_ms`, `nested_scopes_ms`, `mixed_ms`

## How to Run
`./autoresearch.sh` — runs benchmark 5 times, reports median ops/sec. Outputs `METRIC name=value` lines.

## Files in Scope
- `lib/ori/scope.rb` — The main Scope class (fiber scheduler, event loop). Primary optimization target.
- `lib/ori/task.rb` — Task wrapper around fibers
- `lib/ori/channel.rb` — Channel + UnboundedQueue
- `lib/ori/promise.rb` — Promise primitive
- `lib/ori/semaphore.rb` — Semaphore primitive
- `lib/ori/mutex.rb` — Mutex (extends Semaphore)
- `lib/ori/reentrant_semaphore.rb` — Reentrant semaphore
- `lib/ori/broadcast.rb` — Broadcast pub/sub
- `lib/ori/select.rb` — Select (race) across selectables
- `lib/ori/selectable.rb` — Selectable interface
- `lib/ori/lazy.rb` — Lazy data structures (LazyHash, LazyArray, LazyHashSet)
- `lib/ori/timeout.rb` — Timeout wrapper
- `lib/ori.rb` — Entry point (Ori.sync, Ori.select)
- `bench/ori_benchmark.rb` — Benchmark script

## Off Limits
- `test/**` — Tests must not be modified
- `sorbet/**` — Type definitions
- Public API must remain compatible

## Constraints
- All tests must pass (`./autoresearch.checks.sh`)
- No new gem dependencies
- Maintain API compatibility
- No behavioral changes (semantics must be preserved)

## What's Been Tried

### Key wins (kept)
1. **Cache @state instead of thread-local lookup** (+13.5%) — `state` was called dozens of times per loop via `Thread.current.thread_variable_get`. Cached in `@state` ivar.
2. **Replace Lazy data structures with plain Hash/Array/Set** (+14%) — LazyHash/LazyArray had `instance_variable_defined?` overhead on every access.
3. **Optimize pending_work?, cleanup_dead_fibers** (+4.4%) — Removed mutex synchronization, avoid allocations on fast path.
4. **Skip fiber_ids lookup when not tracing** (+8.9%) — Only compute tracer IDs when tracer is active.
5. **Lazily create IO.pipe** (+11.7%) — IO.pipe syscall deferred to first actual IO operation. Huge win for nested scopes.
6. **Inline create_task + register_task into fork** (+3.9%) — Eliminate method dispatch in hot path.
7. **Use single Selectable is_a? check in Task#resume** (+2.1%) — Replaced 5-class case/when with single module check.
8. **Use empty? check for Channel value?** (+3.2%) — Avoid peek+comparison, just check array empty.
9. **Inline UnboundedQueue** — Use plain array for channel buffer, eliminating wrapper.
10. **Merge fiber_ids and task_queue into single hash** (+4.7%) — Halved hash operations per fiber.
11. **Remove cancellation_error from Task#resume hot path** — Moved to cancel() method.
12. Various micro-optimizations: split await loop, defer current_time, optimize close_scope, attr_reader for Task#id, etc.

### Dead ends (discarded)
- Swap-and-drain pending array — Ruby's Array#shift is already fast for small arrays.
- Remove waiting.key? check in process_pending — Needed for correctness (timeout tests fail).
- Inline cleanup on fiber completion — Changes scheduling order, breaks select tests.
- Lazy Mutex creation — Adds complexity for no measurable gain.
- Avoid Fiber.current.blocking? — Marginal, changes semantics slightly.
- Use equal? for sentinel — Symbol != is already identity comparison.
- Inline process_pending/blocked into process_available_work — Ruby inlines methods.
