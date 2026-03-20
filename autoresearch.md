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
(Nothing yet — baseline pending)
