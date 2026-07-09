---
name: util-cqrs-ruby
description: CQRS + Event Sourcing in plain Ruby/Rails, as shown in the Simple CQRS reference app - commands, immutable events, a per-tenant event log, projections folded on read, cached queries, workflows/sagas, and materialized views. Use when implementing or reviewing CQRS/Event Sourcing in a Ruby or Rails app.
---

# util-cqrs-ruby

CQRS + Event Sourcing in plain Ruby. Every change is an immutable **event** appended to a per-tenant **log**, which is the only source of truth. There is no stored read model by default: a **projection** folds itself from events on read, a **query** caches those folds, and a **command** just emits events. Reads and writes never share a path; the only thing between them is the log.

## The one-way flow

```
  HTTP request
       |
       v
  Controller --build--> ctx  (tenant log . actor . cache . namespace)
       |
       |-- write --> Command --track--> EventStore --append--> event log --> Workflow reactions
       |                                                       (async mailer . 3rd-party . retries)
       |
       |-- read ---> Query --fold--> Projection.fold(events) <--read-- event log
                          (caching is opt-in: snapshot the fold, replay only the tail)
```

A controller action builds one `ctx` per request and only calls Commands and Queries. It never touches the log, an Event, a Projection, or a Workflow directly.

## Core building blocks

- **Event** - a frozen fact: `collection`, `record_id`, `action`, `data`, `actor`, `time`, `version`, plus its own `id`. Its key `time/collection/record_id/action/vN/id` is time-sortable and unique. An event, once written, is immutable: you never edit a past event's shape. To evolve it, add a new higher-version fold rule and leave the old versions as upcasts, so old events migrate forward on read.

- **EventStore / log** - `track` appends the event, then emits it so Workflow reactions cascade. A per-tenant seam (`MultiTenant.for(namespace)`) hands each namespace its own store over a tiny `storage` interface (in-memory, or a persisted adapter). A `transaction` buffers emits and flushes them on commit, so an AtomicCommand's events land as a unit or not at all.

- **Context (`ctx`)** - the per-request seam carrying `log`, `actor`, `cache`, and `namespace`. Commands and queries take a `ctx`. `ctx.track(event, ...)` emits, stamped with the ctx's actor.

- **Command** - captures one user intent. Barely a class: a `ctx` and a `call`. It emits with `@ctx.track` and reads only to guard a precondition, by calling a query directly. Most commands emit a single event; follow-on facts are reactions and derived values are computed on read. A failed precondition raises `Rejected`. When one decision must record several facts together, subclass **AtomicCommand** (its tracks run inside a transaction).

  ```ruby
  class CompleteJourney < SimpleCqrs::Command
    def call(id:)
      journey = Queries::FindJourney.call(@ctx, id) or raise Rejected, "no such journey: #{id}"
      return if journey.complete?           # already complete -> idempotent no-op
      @ctx.track(Journey::EVENT_COMPLETED, record_id: id)
    end
  end
  ```

- **Projection** - declares a `collection`, its event names, its `field`s, and `on(EVENT, version)` fold rules. `fold`/`fold_all` rebuild a record (or a whole collection) from its event stream on read. Predicate methods derive from the folded state.

  ```ruby
  class Journey < SimpleCqrs::Projection
    collection "journey"
    EVENT_STARTED   = "#{collection_name}.started".freeze
    EVENT_COMPLETED = "#{collection_name}.completed".freeze
    field :id, :name, :completed_at, :completed_by

    on(EVENT_STARTED, 1)   { |e| with(name: e.data[:name]) }
    on(EVENT_COMPLETED, 1) { |e| with(completed_at: e.time, completed_by: e.actor) }

    def complete? = !completed_at.nil?
  end
  ```

- **Query / CachedQuery** - the read boundary. `find`/`all_of` fold a projection straight from the log with no cache. Subclass **CachedQuery** to fold the same streams through the ctx's fold cache (Null by default, Snapshot when wired: checkpoint a fold, replay only the tail). Caching is opt-in per read. Order is derived on read (the log's insertion order), not stored.

  ```ruby
  class FindJourney < SimpleCqrs::CachedQuery; def call(id) = find(Journey, id); end
  class AllJourneys < SimpleCqrs::Query;       def call     = all_of(Journey).sort_by(&:name); end
  ```

- **Workflow (saga / process manager)** - the write side. `on(EVENT)` registers a reaction that fires when that event commits, including cross-aggregate reactions (a `journey.started` seeds the first checkpoint; an onboarding flow asks a Sale to charge, then reacts to `charged` or `gave_up`). Third-party work lives here: bounded retries, idempotency keyed by `event.key`, and any error turned into a domain fact (a `charge_failed` event) rather than a raw crash.

- **MaterializedView** - the one stored read model, maintained by a workflow. It records a row per source event into a store as events commit, then reads from that store: O(1) per write, O(rows) per read. `record` is idempotent on `event.key`, and `rebuild` backfills from the log through the same path, so it stays rebuildable from the log.

- **Dispatcher** - every reaction runs through a dispatcher. `Inline` (the default) runs it now, synchronous and deterministic. Swap in `Queue`, `Threaded`, or an Active Job adapter and the same reactions run off the request. Inline-versus-async is a deployment choice, not a per-rule flag.

## Conventions worth copying

- Events are immutable and past-tense facts; evolve their shape only by adding higher-version fold rules and upcasting old events on read.
- Event names live in exactly one place: the projection that owns the collection defines `EVENT_*` constants; commands and workflows refer to them qualified (`Journey::EVENT_STARTED`).
- Derive on read (ordering, counts, aggregates) instead of storing it, unless you deliberately materialize a view.
- Commands read only to guard a precondition, and stay idempotent (a terminal state re-issued is a no-op).
- Multitenancy is a namespace: a different deployment or domain is a different store, always supplied explicitly. Test the isolation you cannot see in the code.
- Drive use-case specs through the controller (the app's entry point), asserting both on rendered assigns and on the events an action recorded.

## Sync vs offline

Unlike its JavaScript counterpart, this Ruby version is not offline-first. It runs server-side over a per-tenant log, and its sync-versus-async axis is the **dispatcher** (inline reactions on the request thread, or the same reactions run off-request via a queue, thread, or Active Job), not offline client sync.

## Related

`util-cqrs-js` is the JavaScript/Vue counterpart: the same command/event/projection model applied offline-first in the browser, with a local event store synced to remote storage.

## Resources

- [Simple CQRS in Ruby](https://dev.dallasread.com/simple-cqrs) - the runnable reference app, generated from its own test suite, with a guided end-to-end tour (create, onboard, bill, read back) and the full source for every class summarized above. Go here for the deep detail: the `EventStore`/`Event` internals, upcasting chains, the cache and dispatcher variants, materialized-view rebuild, and the use-case specs.
