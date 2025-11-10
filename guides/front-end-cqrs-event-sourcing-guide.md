# CQRS + Event Sourcing with Vue.js: Implementation Guide

This guide documents the architecture pattern used in the Together Progress application, combining **Command-Query Responsibility Segregation (CQRS)** with **Event Sourcing** in a Vue.js application.

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Architecture Overview](#architecture-overview)
3. [Event Sourcing Deep Dive](#event-sourcing-deep-dive)
4. [CQRS Implementation](#cqrs-implementation)
5. [Project Structure](#project-structure)
6. [Code Examples](#code-examples)
7. [Vue Component Integration](#vue-component-integration)
8. [Testing Strategy](#testing-strategy)
9. [Benefits & Trade-offs](#benefits--trade-offs)

---

## Core Concepts

### What is CQRS?

**Command-Query Responsibility Segregation** is a pattern that separates read operations (queries) from write operations (commands):

- **Commands**: Operations that change state but don't return data
- **Queries**: Operations that return data but don't change state

### What is Event Sourcing?

**Event Sourcing** is a pattern where state changes are stored as a sequence of immutable events, rather than storing only the current state:

- Every change is recorded as an **Event**
- Current state is reconstructed by replaying all events
- Events are immutable and append-only
- Complete audit trail of all changes

### Why Combine Them?

CQRS and Event Sourcing complement each other perfectly:

- Commands produce Events
- Events are stored in an Event Store
- Queries read from reconstructed state
- Full history and time-travel debugging
- Offline-first with eventual consistency

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         Vue Component                        │
│  ┌────────────────┐                    ┌─────────────────┐  │
│  │   Commands     │                    │     Queries     │  │
│  │   (Write)      │                    │     (Read)      │  │
│  └───────┬────────┘                    └────────▲────────┘  │
│          │                                      │           │
│          ▼                                      │           │
│  ┌──────────────────────────────────────────────┴────────┐  │
│  │              Event Store (State)                      │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐ │  │
│  │  │ Event 1 │→ │ Event 2 │→ │ Event 3 │→ │ Event N │ │  │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘ │  │
│  │              ↓ Runners (Reducers)                    │  │
│  │         Current State (Computed)                     │  │
│  └───────────────────────┬───────────────────────────────┘  │
│                          │                                  │
│                          ▼                                  │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         LocalForage (IndexedDB/localStorage)          │ │
│  └───────────────────────┬────────────────────────────────┘ │
│                          │                                  │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │  Adapters (S3, etc.)   │
              │   Remote Storage       │
              └─────────────────────────┘
```

---

## Event Sourcing Deep Dive

### Event Structure

Events are immutable records of state changes:

```javascript
// Event Key Format: timestamp/collection/objectId/action/version
// Example: "1234567890/journeys/abc-123/create/v4"

class EventStoreEvent {
  constructor(collection, objectId, action, data, time, version) {
    this.collection = collection    // e.g., "journeys", "checkpoints"
    this.objectId = objectId        // Unique ID of the object
    this.action = action            // e.g., "create", "update", "delete"
    this.data = data                // The actual data/payload
    this.time = time || Date.now()  // Event timestamp
    this.version = version || 'v4'  // Schema version
  }

  get key() {
    return `${this.time}/${this.collection}/${this.objectId}/${this.action}/${this.version}`
  }
}
```

### Event Store

The Event Store manages all events and reconstructs state:

```javascript
class EventStore {
  constructor(db, runners) {
    this._db = db              // LocalForage instance
    this._runners = runners    // Event handlers
    this._state = {
      journeys: [],
      checkpoints: [],
      tasks: [],
      checkIns: [],
      checkpointCompletions: []
    }
  }

  // Add a new event
  track(collection, objectId, action, data, time, version) {
    // Generate UUID if objectId not provided
    if (!objectId) {
      objectId = uuid()
    }

    const event = new EventStoreEvent(collection, objectId, action, data, time, version)

    // Run the event to update state
    this._runEvent(event)

    // Persist to storage
    this._db.setItem(event.key, event.toLocal())

    return event
  }

  // Replay all events to reconstruct state
  async restore() {
    const events = []

    // Load all events from storage
    await this._db.iterate((value) => {
      events.push(EventStoreEvent.fromLocal(value))
    })

    // Sort by timestamp
    events.sort((a, b) => a.time - b.time)

    // Replay each event
    events.forEach(event => this._runEvent(event))

    return this._state
  }

  // Execute an event using runners
  _runEvent(event) {
    const runnerKey = `${event.collection}.${event.action}`
    const runner = this._runners[runnerKey]

    if (runner) {
      runner.call(this._state, event)
    }
  }
}
```

### UUID Generation

**Important:** UUID generation is centralized in the Event Store, not in Commands.

The Event Store automatically generates UUIDs when `objectId` is `null` or `undefined`:

```javascript
// In EventStore.track()
track(collection, objectId, action, data, time, version) {
  // Generate UUID if objectId not provided
  if (!objectId) {
    objectId = uuid()
  }
  // ... rest of method
  return event
}
```

**Commands retrieve the generated ID from the returned event:**

```javascript
// ✅ Correct: Event Store generates ID
addFeed(feed) {
  const event = this.track(feed.accountId, 'feeds', null, 'create', feed)
  feed.id = event.objectId  // Get ID from event
  return feed
}

// ❌ Incorrect: Don't generate UUIDs in commands
addFeed(feed) {
  feed.id = uuid()  // Don't do this!
  this.track(feed.accountId, 'feeds', feed.id, 'create', feed)
  return feed
}
```

**Benefits of centralizing UUID generation:**

- **Single source of truth**: All IDs generated in one place
- **Consistency**: Same pattern across all commands
- **Simpler commands**: Commands don't need uuid imports
- **Easier testing**: Mock the event store to control IDs
- **Event-driven**: IDs are part of the event creation process

### Querying After Creation (CQRS Best Practice)

**Important:** Commands should track events, then query for the newly created entity. There are two patterns depending on whether the entity needs pre-allocated resources (like a database).

#### Pattern 1: Pre-allocate Resources (e.g., Accounts with Databases)

When creating an entity that needs resources created before tracking (like an account that needs its own database), create the resource first to get the ID, then track with that ID.

**✅ Good: Create DB first, then track with ID**

```javascript
addAccount(account) {
  // Create a database for this account and get the ID
  account.id = this.state.createDB(null)

  // Track account creation with the generated ID
  this.track(null, 'accounts', account.id, 'create', account)

  // Query for the newly created account
  return this.queries.findAccount(account.id)
}
```

**Why this works:**
- `createDB()` generates and returns a UUID
- We assign that UUID to `account.id`
- We track with that specific UUID as the `objectId`
- We can immediately query by that ID

#### Pattern 2: Let Event Store Generate ID (e.g., Feeds, Tags, Items)

For most entities, let the event store generate the ID, then query for the newly created entity using the returned event's objectId.

**✅ Good: Track with null objectId, then query by generated ID**

```javascript
addFeed(feed) {
  // Track feed creation (event store generates ID)
  const event = this.track(feed.accountId, 'feeds', null, 'create', feed)

  // Query for the newly created feed by the generated ID
  return this.queries.findFeed(event.objectId)
}

addTag(tag) {
  // Track tag creation (event store generates ID)
  const event = this.track(tag.accountId, 'tags', null, 'create', tag)

  // Query for the newly created tag
  return this.queries.findTag(event.objectId)
}

addItem(item) {
  // Get accountId from the feed
  const feed = this.queries.findFeed(item.feedId)
  const accountId = feed?.accountId

  // Track item creation (event store generates ID)
  const event = this.track(accountId, 'items', null, 'create', item)

  // Query for the newly created item
  return this.queries.findItem(event.objectId)
}
```

**Why this works:**
- Tracking with `null` objectId tells event store to generate a UUID
- The returned event contains the generated `objectId`
- We immediately query by that ID to get the full object with all computed fields

**❌ Bad: Manually constructing return object**

```javascript
// Don't do this - manually building the return object
addFeed(feed) {
  const event = this.track(feed.accountId, 'feeds', null, 'create', feed)
  return {
    ...feed,
    id: event.objectId  // Missing any computed/derived fields!
  }
}
```

**Why this is bad:**
- Manually constructing objects bypasses query logic
- Missing computed fields that queries may add
- Not following CQRS separation (command shouldn't construct query results)

**Required query methods:**

```javascript
// In Queries class - simple findById queries
findAccount(id) {
  return this.state.findAll(undefined, 'accounts')
    .find(account => account.id === id)
}

findFeed(id) {
  return this.state.findAll(undefined, 'feeds')
    .find(feed => feed.id === id)
}

findTag(id) {
  return this.state.findAll(undefined, 'tags')
    .find(tag => tag.id === id)
}

findItem(id) {
  return this.state.findAll(undefined, 'items')
    .find(item => item.id === id)
}
```

**Key points:**
- State layer automatically filters deleted items (use `findAllWithDeleted()` if you need them)
- Queries work across all databases when passed `undefined` as dbId
- IDs are unique globally, not just within a database
- Simple and predictable: query by ID immediately after creation

**Deleted items handling:**

The EventStore manages deleted item filtering at the state layer:

```javascript
// In EventStore
findAll(collection) {
  const items = this._state[collection] || []
  return items.filter(item => !item._deleted)  // Auto-filter deleted
}

findAllWithDeleted(collection) {
  return this._state[collection] || []  // Include deleted items
}
```

This means queries don't need to check `!item._deleted` - the state layer handles it automatically. Only use `findAllWithDeleted()` when you explicitly need deleted items (e.g., for audit trails or undo functionality).

**Why this matters:**

- **Strict CQRS separation**: Commands change state, queries read state
- **Consistent pattern**: All create operations follow the same flow
- **Testability**: Can test commands and queries independently
- **Flexibility**: Query logic can change without affecting commands
- **Single responsibility**: Commands execute, queries retrieve

### Architectural Layering: State Management Responsibilities

**Key principle: The state layer manages data concerns, queries perform business logic.**

**State Layer (EventStore) Responsibilities:**
- Filter deleted items by default
- Manage multiple databases (MultipleEventStore)
- Handle event persistence and replay
- Provide raw data access

**Query Layer Responsibilities:**
- Business logic filters (e.g., items for specific feed)
- Sorting and ordering
- Derived computations
- Aggregations

**Anti-pattern:**

```javascript
// ❌ Bad: Queries filtering deleted items
allAccounts() {
  return this.state.findAll(undefined, 'accounts')
    .filter(account => !account._deleted)  // State layer should handle this
    .sort((a, b) => a.name.localeCompare(b.name))
}
```

**Correct pattern:**

```javascript
// ✅ Good: State handles deletion, queries handle business logic
allAccounts() {
  return this.state.findAll(undefined, 'accounts')  // Already filtered by state
    .sort((a, b) => a.name.localeCompare(b.name))   // Query adds sorting
}
```

**Benefits:**
- DRY: Deletion filtering in one place (state layer)
- Consistency: Can't forget to filter deleted items
- Clear separation: State manages data lifecycle, queries perform business operations
- Easy to override: Use `findAllWithDeleted()` when you explicitly need deleted items

### Event Runners (Reducers)

Runners define how events modify state:

```javascript
export default {
  // Use built-in CREATE runner
  'journeys.create': EventStore.RUNNERS.CREATE,
  'checkpoints.create': EventStore.RUNNERS.CREATE,

  // Soft delete (mark as deleted)
  'journeys.delete': EventStore.RUNNERS.DELETE,
  'checkpoints.delete': EventStore.RUNNERS.DELETE,

  // Custom runner for updating name
  'checkpoints.updateName'(event) {
    const checkpoint = this.checkpoints.find(item => item.id === event.objectId)
    if (checkpoint) {
      checkpoint.name = event.data
      checkpoint.updatedAt = event.time
    }
  },

  // Custom runner for completing a task
  'tasks.complete'(event) {
    const task = this.tasks.find(item => item.id === event.objectId)
    if (task) {
      task.complete = true
      task.completedAt = event.time
    }
  },

  // Custom runner for updating order
  'checkpoints.updateOrder'(event) {
    const checkpoint = this.checkpoints.find(item => item.id === event.objectId)
    if (checkpoint) {
      checkpoint.order = event.data
    }
  }
}
```

### Timestamp-Based State Pattern

**Prefer timestamp fields over booleans for state that tracks when something happened.**

Instead of boolean flags like `paused`, `saved`, or `archived`, use timestamp fields that record when the state change occurred. This provides more information and follows event sourcing principles better.

**❌ Bad: Boolean flags**

```javascript
// Runners
'feeds.pause'(event) {
  const feed = this.feeds.find(item => item.id === event.objectId)
  if (feed) {
    feed.paused = true
    feed.updatedAt = event.time
  }
}

'feeds.unpause'(event) {
  const feed = this.feeds.find(item => item.id === event.objectId)
  if (feed) {
    feed.paused = false
    feed.updatedAt = event.time
  }
}

// Usage in components
if (feed.paused) {
  // Show paused state
}
```

**✅ Good: Timestamp fields with dedicated events**

```javascript
// Runners
'feeds.pause'(event) {
  const feed = this.feeds.find(item => item.id === event.objectId)
  if (feed) {
    feed.pausedAt = event.time  // Timestamp, not boolean
    feed.updatedAt = event.time
  }
}

'feeds.unpause'(event) {
  const feed = this.feeds.find(item => item.id === event.objectId)
  if (feed) {
    feed.pausedAt = null  // null means not paused
    feed.updatedAt = event.time
  }
}

// Dedicated commands (not generic update)
pauseFeed(feed) {
  this.track(feed.accountId, 'feeds', feed.id, 'pause')
}

unpauseFeed(feed) {
  this.track(feed.accountId, 'feeds', feed.id, 'unpause')
}

// Usage in components
if (feed.pausedAt) {
  // Show paused state
  // Can also show when it was paused: formatDate(feed.pausedAt)
}
```

**Benefits of timestamp-based state:**

1. **Richer data**: Know exactly when the state changed
2. **Better audit trail**: Can query "feeds paused in the last week"
3. **Enables sorting**: Sort by "recently paused" or "longest paused"
4. **Future extensibility**: Can add features like "paused for 7 days" notifications
5. **True event sourcing**: Events capture when things happened
6. **Dedicated events**: Each state transition is explicit

**Common patterns to convert:**

| Boolean Pattern | Timestamp Pattern | Events |
|----------------|-------------------|---------|
| `saved: true/false` | `savedAt: timestamp/null` | `items.save`, `items.unsave` |
| `paused: true/false` | `pausedAt: timestamp/null` | `feeds.pause`, `feeds.unpause` |
| `archived: true/false` | `archivedAt: timestamp/null` | `items.archive`, `items.unarchive` |
| `read: true/false` | `readAt: timestamp/null` | `items.markRead`, `items.markUnread` |
| `completed: true/false` | `completedAt: timestamp/null` | `tasks.complete`, `tasks.uncomplete` |

**When to use booleans vs timestamps:**

- ✅ Use booleans: Static properties that never change (`isSystem`, `hasChildren`)
- ✅ Use timestamps: State that changes over time and you care when it changed
- ✅ Use enums: Multiple discrete states (`status: 'draft' | 'published' | 'archived'`)

### Built-in Runners

The Event Store provides standard runners:

```javascript
EventStore.RUNNERS = {
  // Create new object
  CREATE(event) {
    this[event.collection].push({
      ...event.data,
      id: event.objectId,
      createdAt: event.time,
      _collection: event.collection
    })
  },

  // Update existing or create if missing
  UPDATE(event) {
    const existing = this[event.collection].find(item => item.id === event.objectId)

    if (!existing) {
      return EventStore.RUNNERS.CREATE.call(this, event)
    }

    existing.updatedAt = event.time
    Object.assign(existing, event.data)
  },

  // Soft delete (preserves history)
  DELETE(event) {
    const existing = this[event.collection].find(item => item.id === event.objectId)
    if (existing) {
      existing._deleted = true
      existing.deletedAt = event.time
    }
  }
}
```

### Multi-Store Pattern

For multi-tenant applications, use separate event stores:

```javascript
class MultiEventStore {
  constructor() {
    this._stores = new Map()
  }

  // Create or get a store for a specific journey
  getStore(journeyId) {
    if (!this._stores.has(journeyId)) {
      const db = localforage.createInstance({ name: journeyId })
      this._stores.set(journeyId, new EventStore(db, runners))
    }
    return this._stores.get(journeyId)
  }

  // Track event in specific journey's store
  track(journeyId, collection, objectId, action, data) {
    const store = this.getStore(journeyId)
    return store.track(collection, objectId, action, data)
  }

  // Restore all stores
  async restoreAll() {
    const promises = Array.from(this._stores.values()).map(store => store.restore())
    return Promise.all(promises)
  }
}
```

### MultipleEventStore Pattern (Extended)

For applications with account-based isolation where each account needs its own database:

```javascript
import { v4 as uuidv4 } from 'uuid'
import EventStore from './event-store.js'

class MultipleEventStore extends EventStore {
  constructor(name, version, runners = {}) {
    super(name, version, runners)
    this._config = this._db      // Root DB stores account configs
    this._dbs = {}                // Map of accountId -> EventStore

    // Get unique collection names from runners
    const collectionNames = new Set()
    for (const key in runners) {
      collectionNames.add(key.split('.')[0])
    }

    // Define read-only properties for each collection
    for (const collectionName of collectionNames) {
      Object.defineProperty(this, collectionName, {
        get: () => this.findAll(undefined, collectionName),
        set: () => {
          throw new Error(`Cannot set read-only attribute: ${collectionName}`)
        }
      })
    }
  }

  // Create a new database for an account
  createDB(dbId) {
    dbId = dbId || uuidv4()
    this.setConfig(dbId, {})
    this._initDB(dbId)
    return dbId
  }

  // Delete account database
  deleteDB(dbId) {
    const db = this._dbs[dbId]
    delete this._dbs[dbId]
    return Promise.all([
      db.teardown(),
      this._config.removeItem(dbId)
    ])
  }

  // Track event in specific database
  track(dbId, collection, objectId, action, data) {
    const dbs = this._findDBs(dbId ? [dbId] : undefined)
    const promises = dbs.map((db) => db.track(collection, objectId, action, data))
    return Promise.all(promises)
  }

  // Find all items in collection, optionally filtered by database
  findAll(dbId, collection) {
    const dbs = this._findDBs(dbId ? [dbId] : undefined)
    return dbs.reduce((items, db) => {
      return items.concat(db.findAll(collection))
    }, []).sort(EventStore.SORT_BY_DATE)
  }

  // Restore all account databases
  restore() {
    return this._config
      .iterate((value, dbId) => {
        this._initDB(dbId)
      })
      .then(() => {
        const promises = []
        for (const key in this._dbs) {
          promises.push(this._dbs[key].restore())
        }
        return Promise.all(promises)
      })
  }

  // Initialize a specific account database
  _initDB(dbId) {
    const db = new EventStore(`${this._name}-${dbId}`, this._version, this._runners)
    this._dbs[dbId] = db
    return db
  }

  // Find databases by IDs, or all if no IDs provided
  _findDBs(dbIds) {
    if (!dbIds || !dbIds.length) {
      return Object.values(this._dbs)
    }

    return Object.values(this._dbs).filter(db =>
      dbIds.includes(db._name.split('-').pop())
    )
  }
}
```

**Key differences from MultiEventStore:**

1. **Extends EventStore**: Inherits base functionality
2. **Root database**: Config database stores account metadata
3. **Lazy initialization**: Account databases created on-demand
4. **Unified API**: Single interface for querying across accounts or specific accounts
5. **Automatic cleanup**: Deleting account removes its database

**Usage with Commands:**

```javascript
class Commands {
  constructor({ state, queries }) {
    this.state = state  // MultipleEventStore instance
    this.queries = queries
  }

  // Account commands use root DB (dbId = null)
  addAccount(account) {
    // Track account creation (event store generates ID)
    const event = this.track(null, 'accounts', account.id, 'create', account)
    account.id = event.objectId

    // Create isolated database for this account
    this.state.createDB(account.id)

    return account
  }

  removeAccount(account) {
    this.track(null, 'accounts', account.id, 'delete')

    // Delete account's database
    this.state.deleteDB(account.id)
  }

  // Feed commands use account-specific DB
  addFeed(feed) {
    // Store in account-specific database (event store generates ID)
    const event = this.track(feed.accountId, 'feeds', feed.id, 'create', feed)
    feed.id = event.objectId
    return feed
  }

  // Item commands lookup accountId from feed
  addItem(item) {
    // Get accountId from feed
    const feed = this.queries.findFeed(item.feedId)
    const accountId = feed?.accountId

    // Store in account-specific database (event store generates ID)
    const event = this.track(accountId, 'items', item.id, 'create', item)
    item.id = event.objectId
    return item
  }

  // Core tracking with dbId
  track(dbId, collection, objectId, action, data) {
    this.state.track(dbId, collection, objectId, action, data)
  }
}
```

**Usage with Queries:**

```javascript
class Queries {
  constructor({ state }) {
    this.state = state  // MultipleEventStore instance
  }

  // Query accounts from root DB (dbId = undefined)
  allAccounts() {
    return this.state.findAll(undefined, 'accounts')
      .filter(account => !account._deleted)
      .sort((a, b) => a.name?.localeCompare(b.name))
  }

  // Query feeds from specific account DB
  feedsForAccount(account) {
    return this.state.findAll(account.id, 'feeds')
      .filter(feed => !feed._deleted && feed.accountId === account.id)
      .sort((a, b) => a.title?.localeCompare(b.title))
  }

  // Query items from specific account DB
  itemsForAccount(account) {
    return this.state.findAll(account.id, 'items')
      .filter(item => !item._deleted)
      .sort((a, b) => (b.pubDate || 0) - (a.pubDate || 0))
  }

  // Query across all accounts (if needed)
  allFeeds() {
    return this.state.findAll(undefined, 'feeds')
      .filter(feed => !feed._deleted)
      .sort((a, b) => a.title?.localeCompare(b.title))
  }
}
```

**Benefits of MultipleEventStore:**

- **Data isolation**: Each account's data is in a separate IndexedDB database
- **Performance**: Queries only scan relevant account data
- **Privacy**: Account data can be independently encrypted/deleted
- **Scalability**: Large accounts don't slow down queries for small accounts
- **Flexibility**: Can query specific account or across all accounts
- **Browser limits**: Avoids hitting single-database size limits

**When to use:**

- Multi-tenant applications with account-based data isolation
- Apps where users have multiple workspaces/projects
- When accounts can have vastly different data sizes
- When you need to selectively sync/export account data

### Storing Preferences in Root DB Config

For app-wide preferences that should persist independently of event sourcing (like UI settings, filters, etc.), store them in the root database config object keyed by account ID.

**Why separate from events:**

- Preferences are UI state, not domain events
- Don't need audit trail for UI preferences
- Faster read/write without event overhead
- No need to replay events for preference changes

**Implementation:**

Add methods to `MultipleEventStore` to manage config:

```javascript
// In MultipleEventStore
async getConfig(dbId) {
  return await this._config.getItem(dbId) || {}
}

async updateConfig(dbId, updates) {
  const config = await this.getConfig(dbId)
  const newConfig = { ...config, ...updates }
  await this.setConfig(dbId, newConfig)
  return newConfig
}
```

**Root DB Structure:**

```javascript
// Root DB (_config) stores account configs
{
  "account-123-uuid": {
    preferences: {
      contentFilter: "video",
      sidebarCollapsed: false,
      theme: "dark"
    }
  },
  "account-456-uuid": {
    preferences: {
      contentFilter: null,
      theme: "light"
    }
  }
}
```

**Commands for preferences:**

```javascript
// src/commands/index.js
class Commands {
  async updatePreference(account, key, value) {
    const config = await this.state.getConfig(account.id)
    const preferences = { ...(config.preferences || {}) }
    preferences[key] = value

    await this.state.updateConfig(account.id, { preferences })
  }

  async getPreferences(account) {
    const config = await this.state.getConfig(account.id)
    return config.preferences || {}
  }
}
```

**Queries for preferences:**

```javascript
// src/queries/index.js
class Queries {
  async getPreferences(account) {
    const config = await this.state.getConfig(account.id)
    return config.preferences || {}
  }

  async getPreferenceValue(account, key, defaultValue = null) {
    const preferences = await this.getPreferences(account)
    return preferences[key] ?? defaultValue
  }
}
```

**Usage in components:**

```javascript
// Load preferences on mount
export default {
  data() {
    return {
      preferences: {}  // Cached from root DB
    }
  },

  computed: {
    contentFilter() {
      return this.preferences.contentFilter || null
    }
  },

  async mounted() {
    // Load preferences from root DB config
    this.preferences = await this.app.queries.getPreferences(this.account)
  },

  methods: {
    async changeContentFilter(value) {
      // Update preference in root DB config
      await this.app.commands.updatePreference(this.account, 'contentFilter', value)

      // Refresh local cache
      this.preferences = await this.app.queries.getPreferences(this.account)
    }
  }
}
```

**Key differences from event-sourced data:**

| Event Store | Root DB Config |
|-------------|----------------|
| Domain events | UI preferences |
| Immutable events | Mutable config |
| Full audit trail | Current state only |
| Event replay | Direct read/write |
| Runs through runners | No processing |
| Accounts, feeds, items | Preferences, settings |

**Best practices:**

1. **Use for UI state only**: Don't store domain data in config
2. **Cache in components**: Load once on mount, refresh after updates
3. **Account-scoped**: Each account has its own preferences
4. **Don't abuse**: Only for true preferences, not domain state
5. **Async aware**: Always await config operations
6. **Encapsulate access**: Use Commands/Queries, never access `_config` directly

**When to use config vs events:**

- ✅ Config: UI theme, filter selections, collapsed panels, sort order
- ❌ Events: User data, feeds, items, tags, account info

---

## CQRS Implementation

### Commands (Write Operations)

Commands handle all state mutations and produce events:

```javascript
class Commands {
  constructor({ state, queries, storageSettings }) {
    this.state = state                      // MultiEventStore instance
    this.queries = queries                  // Queries instance
    this.storageSettings = storageSettings  // Adapter management
  }

  // Create a new journey
  addJourney(journey) {
    journey.id = this.state.createDB(null, config)

    // Track the creation event
    this.track(journey, 'journeys', journey.id, 'create', journey)

    // Automatically create first checkpoint
    this.addCheckpointToJourney(journey, {
      name: 'Start a journey',
      order: 0
    })

    return journey
  }

  // Update journey name
  updateJourneyName(journey, name) {
    this.track(journey, 'journeys', journey.id, 'updateName', name)
  }

  // Add checkpoint to journey
  addCheckpointToJourney(journey, checkpoint) {
    checkpoint.order = checkpoint.order ?? this.queries.findAllCheckpointsForJourney(journey).length

    // Event store will generate ID
    const event = this.track(journey, 'checkpoints', checkpoint.id, 'create', checkpoint)
    checkpoint.id = event.objectId
  }

  // Remove checkpoint (soft delete)
  removeCheckpointFromJourney(journey, checkpoint) {
    this.track(journey, 'checkpoints', checkpoint.id, 'delete')
  }

  // Complete a checkpoint
  completeCheckpointForJourney(journey, checkpoint) {
    const completion = {
      checkpointId: checkpoint.id,
      completedAt: Date.now()
    }

    // Event store will generate ID
    const event = this.track(journey, 'checkpointCompletions', null, 'create', completion)
    completion.id = event.objectId
  }

  // Core tracking method
  track(journey, collectionName, objectId, action, data) {
    // Store event
    this.state.track(journey.id, collectionName, objectId, action, data)

    // Debounced sync with remote storage
    this.debouncedUpdateJourneySync(journey)
  }

  // Sync with remote storage (debounced to avoid excessive writes)
  debouncedUpdateJourneySync(journey) {
    clearTimeout(this._syncTimeouts?.[journey.id])

    this._syncTimeouts = this._syncTimeouts || {}
    this._syncTimeouts[journey.id] = setTimeout(() => {
      this.syncJourneyWithRemote(journey)
    }, 1000)
  }

  // Sync journey to remote storage via adapter
  async syncJourneyWithRemote(journey) {
    const fileContents = this.queries.journeyToFile(journey)

    return this.storageSettings.put(
      journey.id,
      fileContents,
      (data) => data,
      'journey'
    )
  }

  // Restore state from local storage on app start
  async restoreFromLocal() {
    return this.state.restoreAll()
  }
}
```

### Key Command Principles

1. Commands never return data (use queries for that)
2. All mutations go through `track()`
3. Commands produce events
4. Automatic remote sync (debounced)
5. Commands can compose (e.g., `addJourney` calls `addCheckpointToJourney`)

### Queries (Read Operations)

Queries provide read-only access to state:

```javascript
class Queries {
  constructor({ state }) {
    this.state = state  // MultiEventStore instance
  }

  // Find all journeys
  allJourneys() {
    return this.state.findAll(null, 'journeys')
      .filter(journey => !journey._deleted)
      .sort(SORT_BY_NAME)
  }

  // Find specific journey by ID
  findJourney(id) {
    return this.state.findAll(null, 'journeys')
      .find(journey => journey.id === id && !journey._deleted)
  }

  // Find all checkpoints for a journey
  findAllCheckpointsForJourney(journey) {
    return this.state.findAll(journey.id, 'checkpoints')
      .filter(checkpoint => !checkpoint._deleted)
      .sort(SORT_BY_ORDER)
  }

  // Find specific checkpoint
  findCheckpointForJourney(journey, checkpointId) {
    return this.findAllCheckpointsForJourney(journey)
      .find(checkpoint => checkpoint.id === checkpointId)
  }

  // Complex query: incomplete checkpoints
  findAllIncompleteCheckpointsForJourney(journey) {
    return this.findAllCheckpointsForJourney(journey)
      .filter(checkpoint => !this.isCheckpointCompleteForJourney(journey, checkpoint))
  }

  // Check if checkpoint is complete
  isCheckpointCompleteForJourney(journey, checkpoint) {
    const completions = this.findAllCheckpointCompletionsForJourney(journey)
    return completions.some(c => c.checkpointId === checkpoint.id)
  }

  // Timeline aggregation
  findAllTimelineEventsForJourney(journey) {
    const checkIns = this.findAllCheckInsForJourney(journey)
    const completions = this.findAllCheckpointCompletionsForJourney(journey)

    return [...checkIns, ...completions]
      .sort(SORT_BY_TIME)
  }

  // Export journey to file format
  journeyToFile(journey) {
    return this.state.findAllEvents(journey.id)
      .map(event => `${event.key} ${event.toLocal()}`)
      .join('\n')
  }

  // Import journey from file
  fileToJourney(fileContents) {
    return fileContents
      .split('\n')
      .filter(Boolean)
      .map(line => {
        const [key, ...dataParts] = line.split(' ')
        const data = dataParts.join(' ')
        return EventStoreEvent.fromLocal(data)
      })
  }
}
```

### Custom Sorters

Queries use composable sorters:

```javascript
// sort-by-name.js
export default (a, b) => {
  return a.name.localeCompare(b.name)
}

// sort-by-time.js
export default (a, b) => {
  return (a.createdAt || 0) - (b.createdAt || 0)
}

// sort-by-order.js
export default (a, b) => {
  return (a.order || 0) - (b.order || 0)
}

// sort-by-hillchart.js
export default (a, b) => {
  const aValue = a.hillchart ?? -1
  const bValue = b.hillchart ?? -1
  return aValue - bValue
}
```

---

## Project Structure

```
src/
├── app/                          # Vue application
│   ├── components/               # Reusable UI components
│   │   ├── add-checkpoint/
│   │   ├── checkpoint-list/
│   │   └── hillchart/
│   ├── views/                    # Page-level components
│   │   ├── plan/                 # Planning view
│   │   ├── execute/              # Execution view
│   │   └── reflect/              # Reflection view
│   ├── router/                   # Vue Router config
│   └── component.vue             # Root component
│
├── state/                        # Event Sourcing
│   ├── event-store.js            # Core event store
│   ├── multi-event-store.js      # Multi-tenant stores
│   ├── event-store-event.js      # Event class
│   └── runners.js                # Event handlers/reducers
│
├── commands/                     # CQRS Commands
│   └── index.js                  # All write operations
│
├── queries/                      # CQRS Queries
│   ├── index.js                  # All read operations
│   └── sorters/                  # Query sorting utilities
│       ├── sort-by-name.js
│       ├── sort-by-time.js
│       ├── sort-by-order.js
│       ├── sort-by-hillchart.js
│       └── sort-by-focuschart.js
│
└── storage-settings/             # Adapters
    ├── storage-settings.js       # Adapter management
    └── adapters/                 # Storage backends
        ├── s3.js                 # AWS S3 storage
        ├── none.js               # Local-only
        └── paste.js              # Paste-based sharing
```

---

## Code Examples

### Full Application Setup

```javascript
// src/app/component.vue
<script>
import { MultiEventStore } from '@/state/multi-event-store'
import { Commands } from '@/commands'
import { Queries } from '@/queries'
import { StorageSettings } from '@/storage-settings'

export default {
  data() {
    // Initialize Event Store
    const state = new MultiEventStore()

    // Initialize Queries
    const queries = new Queries({ state })

    // Initialize Storage Settings (Adapters)
    const storageSettings = new StorageSettings()

    // Initialize Commands
    const commands = new Commands({
      state,
      queries,
      storageSettings,
      saveAs: this.saveAs,
      copyToClipboard: this.copyToClipboard,
      blob: this.blob
    })

    return {
      app: this,
      queries,
      commands,
      isLoading: true
    }
  },

  computed: {
    // Query: All journeys (reactive)
    journeys() {
      return this.app.queries.allJourneys()
    }
  },

  async mounted() {
    // Restore state from local storage
    await this.commands.restoreFromLocal()
    this.isLoading = false
  }
}
</script>
```

### Component Example: Adding a Checkpoint

```vue
<!-- src/app/components/add-checkpoint/component.vue -->
<template>
  <form @submit.prevent="addCheckpoint" class="add-checkpoint">
    <input
      v-model="newCheckpointName"
      type="text"
      placeholder="Add a checkpoint..."
      aria-label="New checkpoint name"
    >
    <button type="submit">Add</button>
  </form>
</template>

<script>
export default {
  props: {
    app: { type: Object, required: true },
    journey: { type: Object, required: true }
  },

  data() {
    return {
      newCheckpointName: ''
    }
  },

  methods: {
    addCheckpoint() {
      if (!this.newCheckpointName.trim()) return

      // Execute command (write operation)
      this.app.commands.addCheckpointToJourney(this.journey, {
        name: this.newCheckpointName
      })

      // Reset form
      this.newCheckpointName = ''
    }
  }
}
</script>
```

### Component Example: Displaying Checkpoints

```vue
<!-- src/app/components/checkpoint-list/component.vue -->
<template>
  <div class="checkpoint-list">
    <div
      v-for="checkpoint in checkpoints"
      :key="checkpoint.id"
      class="checkpoint"
      :class="{ complete: isComplete(checkpoint) }"
    >
      <h3>{{ checkpoint.name }}</h3>
      <button @click="complete(checkpoint)">
        Complete
      </button>
      <button @click="remove(checkpoint)">
        Remove
      </button>
    </div>
  </div>
</template>

<script>
export default {
  props: {
    app: { type: Object, required: true },
    journey: { type: Object, required: true }
  },

  computed: {
    // Query: All checkpoints (reactive)
    checkpoints() {
      return this.app.queries.findAllCheckpointsForJourney(this.journey)
    }
  },

  methods: {
    // Query: Check if complete
    isComplete(checkpoint) {
      return this.app.queries.isCheckpointCompleteForJourney(
        this.journey,
        checkpoint
      )
    },

    // Command: Complete checkpoint
    complete(checkpoint) {
      this.app.commands.completeCheckpointForJourney(this.journey, checkpoint)
    },

    // Command: Remove checkpoint
    remove(checkpoint) {
      this.app.commands.removeCheckpointFromJourney(this.journey, checkpoint)
    }
  }
}
</script>
```

### Adapter Example: S3 Storage

```javascript
// src/storage-settings/adapters/s3.js
import AWS from 'aws-sdk'

export default class S3 {
  constructor(data) {
    this.data = data  // { bucket, filename, region, endpoint, credentials }
  }

  async put(data, encrypt) {
    const s3 = this._getS3Client()

    // Optional encryption hook
    const body = encrypt ? await encrypt(data) : data

    return s3.putObject({
      Bucket: this.data.bucket,
      Key: this.data.filename,
      Body: body,
      ContentType: 'text/plain'
    }).promise()
  }

  async fetch(decrypt) {
    const s3 = this._getS3Client()

    const response = await s3.getObject({
      Bucket: this.data.bucket,
      Key: this.data.filename
    }).promise()

    const body = response.Body.toString()

    // Optional decryption hook
    return decrypt ? await decrypt(body) : body
  }

  _getS3Client() {
    return new AWS.S3({
      endpoint: this.data.endpoint,
      region: this.data.region,
      credentials: new AWS.Credentials({
        accessKeyId: this.data.credentials.accessKeyId,
        secretAccessKey: this.data.credentials.secretAccessKey
      })
    })
  }
}
```

---

## Vue Component Integration

### Data Flow Patterns

**Read Pattern (Queries in Computed Properties):**

```javascript
export default {
  props: ['app', 'journey'],

  computed: {
    // Queries are reactive - re-compute when state changes
    checkpoints() {
      return this.app.queries.findAllCheckpointsForJourney(this.journey)
    },

    incompleteCheckpoints() {
      return this.app.queries.findAllIncompleteCheckpointsForJourney(this.journey)
    },

    completionRate() {
      const total = this.checkpoints.length
      const complete = total - this.incompleteCheckpoints.length
      return total > 0 ? (complete / total) * 100 : 0
    }
  }
}
```

**Write Pattern (Commands in Methods):**

```javascript
export default {
  props: ['app', 'journey'],

  methods: {
    addCheckpoint(name) {
      this.app.commands.addCheckpointToJourney(this.journey, { name })
    },

    updateCheckpointName(checkpoint, name) {
      this.app.commands.updateCheckpointName(this.journey, checkpoint, name)
    },

    removeCheckpoint(checkpoint) {
      this.app.commands.removeCheckpointFromJourney(this.journey, checkpoint)
    },

    completeCheckpoint(checkpoint) {
      this.app.commands.completeCheckpointForJourney(this.journey, checkpoint)
    }
  }
}
```

### Props Pattern

Pass the app instance down to all components:

```vue
<template>
  <checkpoint-list :app="app" :journey="currentJourney" />
</template>

<script>
import CheckpointList from '@/app/components/checkpoint-list'

export default {
  components: { CheckpointList },

  props: {
    app: { type: Object, required: true }
  },

  computed: {
    currentJourney() {
      return this.app.queries.findJourney(this.$route.params.id)
    }
  }
}
</script>
```

### Reactivity with Event Sourcing

Vue's reactivity system automatically tracks queries:

```javascript
// When a command runs...
this.app.commands.addCheckpointToJourney(journey, { name: 'New Checkpoint' })

// 1. Command tracks an event
// 2. Event is added to Event Store
// 3. Runner updates state
// 4. Vue detects state change
// 5. Computed properties re-evaluate
// 6. Components re-render

// The checkpoint list automatically updates!
```

---

## Testing Strategy

### Integration Testing with Events

```javascript
// use-cases/journeys/begin-a-journey.spec.js
import { mountApp, story, event } from '../helper.js'

describe('Journeys: Begin a journey', () => {
  let app

  beforeEach(async () => {
    // Mount full app (not a unit test)
    app = await mountApp()

    // Simulate user actions
    await app.click('[aria-label="Start a journey"]')
    await app.find('[aria-label="Journey name"]').setValue('My Journey')
    await app.click('[aria-label="Journey color #A2E8F1"]')
    await app.submit('[aria-label="Start journey"]')
  })

  // Test user story
  story('begins the journey', () => {
    expect(app.text()).toContain('My Journey')
    expect(app.text()).toContain('Start a journey') // First checkpoint
  })

  // Test that correct events were emitted
  event('journeys.create', {
    collection: 'journeys',
    action: 'create',
    data: {
      name: 'My Journey',
      color: '#A2E8F1'
    }
  }, () => ({ app }))

  event('checkpoints.create', {
    collection: 'checkpoints',
    action: 'create',
    data: {
      name: 'Start a journey',
      order: 0
    }
  }, () => ({ app }))
})
```

### Testing Helpers

```javascript
// use-cases/helper.js
import { mount } from '@vue/test-utils'
import App from '@/app/component.vue'

export async function mountApp() {
  const wrapper = mount(App)
  await wrapper.vm.commands.restoreFromLocal()
  return wrapper
}

export function story(description, testFn) {
  it(description, testFn)
}

export function event(eventKey, expectedEvent, getContext) {
  it(`emits ${eventKey} event`, () => {
    const { app } = getContext()
    const events = app.vm.state.findAllEvents()

    const matchingEvent = events.find(e => {
      return e.collection === expectedEvent.collection &&
             e.action === expectedEvent.action
    })

    expect(matchingEvent).toBeDefined()
    expect(matchingEvent.data).toMatchObject(expectedEvent.data)
  })
}
```

### Event Replay Testing

Test event replay to ensure deterministic state:

```javascript
describe('Event Replay', () => {
  it('reconstructs state from events', async () => {
    // Create initial state
    const journey = await commands.addJourney({ name: 'Test' })
    await commands.addCheckpointToJourney(journey, { name: 'Checkpoint 1' })
    await commands.addCheckpointToJourney(journey, { name: 'Checkpoint 2' })

    // Capture events
    const events = queries.findAllEventsForJourney(journey)

    // Clear state
    await state.clear()

    // Replay events
    events.forEach(event => state._runEvent(event))

    // State should be identical
    const restoredJourney = queries.findJourney(journey.id)
    expect(restoredJourney.name).toBe('Test')

    const checkpoints = queries.findAllCheckpointsForJourney(restoredJourney)
    expect(checkpoints).toHaveLength(2)
    expect(checkpoints[0].name).toBe('Checkpoint 1')
    expect(checkpoints[1].name).toBe('Checkpoint 2')
  })
})
```

---

## Benefits & Trade-offs

### Benefits

**Event Sourcing Benefits:**

1. **Complete Audit Trail**: Every change is recorded with timestamp and details
2. **Time Travel Debugging**: Replay events to any point in time
3. **Event Replay**: Reconstruct state from scratch
4. **Offline-First**: All events stored locally, synced when online
5. **Conflict Resolution**: Events are append-only, easier to merge
6. **Analytical Queries**: Query historical data (when, how often, by whom)
7. **Event-Driven Architecture**: Easy to add event listeners/webhooks

**CQRS Benefits:**

1. **Separation of Concerns**: Read and write logic completely separated
2. **Independent Scaling**: Scale reads and writes independently (if needed)
3. **Optimized Queries**: Tailor read models for specific use cases
4. **Simplified Commands**: Write operations don't need to return data
5. **Clear Intent**: Commands are explicit about what changes they make

**Combined Benefits:**

1. **Undo/Redo**: Can implement by replaying events
2. **Synchronization**: Multiple devices can sync via event merging
3. **Testing**: Easy to test by verifying events, not state
4. **Debugging**: See exactly what happened and when
5. **Flexibility**: Easy to add new projections/views

### Trade-offs

**Complexity:**

- More moving parts than traditional state management
- Steeper learning curve for new developers
- Need to understand event sourcing concepts

**Storage:**

- Events accumulate over time (can snapshot and archive)
- More storage than just current state
- Need strategy for pruning old events

**Performance:**

- Initial load replays all events (can be slow)
- Solution: Snapshots + recent events
- Event Store restore: O(n) where n = number of events

**Eventual Consistency:**

- Remote sync is async (debounced)
- Possible conflicts if multiple devices
- Need conflict resolution strategy

**Query Limitations:**

- Can't easily query across event stores (multi-tenant)
- Need to design collections/aggregates carefully
- Some queries require replaying many events

### When to Use This Pattern

**Good Fit:**

- Applications with audit requirements
- Collaborative/multi-device apps
- Offline-first applications
- Complex domain logic
- Need for time-travel/history
- Event-driven systems

**Not Recommended:**

- Simple CRUD apps
- Read-heavy with no writes
- Tight latency requirements
- Simple state management sufficient
- Team unfamiliar with patterns

---

## Best Practices

### Event Design

1. **Events are immutable**: Never modify an event after creation
2. **Events are facts**: Describe what happened, not what should happen
3. **Past tense names**: `CheckpointCreated`, not `CreateCheckpoint`
4. **Fine-grained**: One event per logical change
5. **Include context**: Timestamp, user ID, version

### Naming Conventions

1. **Boolean properties**: Always use `is`, `has`, or `should` prefix
   - ✅ `isRead`, `isDeleted`, `isActive`, `isComplete`
   - ✅ `hasChildren`, `hasPermission`
   - ✅ `shouldSync`, `shouldNotify`
   - ❌ `read`, `deleted`, `active`, `complete`

2. **Command methods**: Use imperative present tense
   - ✅ `addEmail()`, `markEmailAsRead()`, `updateAccount()`
   - ✅ `removeCheckpoint()`, `completeTask()`
   - ❌ `emailAdded()`, `readEmail()`, `accountUpdate()`

3. **Query methods**: Use descriptive names
   - ✅ `allEmails()`, `unreadEmails()`, `findEmail(id)`
   - ✅ `emailsInFolder(folder)`, `incompleteTasks()`
   - ❌ `getEmails()`, `emails()`, `email(id)`

4. **Event actions**: Use past tense or descriptive verbs
   - ✅ `'emails.markRead'`, `'emails.create'`, `'emails.delete'`
   - ✅ `'checkpoints.updateName'`, `'tasks.complete'`
   - ❌ `'emails.read'`, `'emails.add'`, `'emails.remove'`

5. **Collections**: Use plural nouns
   - ✅ `emails`, `folders`, `accounts`
   - ❌ `email`, `folder`, `account`

### Command Design

1. **Present tense names**: `addCheckpoint`, `updateJourneyName`
2. **Validate before tracking**: Don't create invalid events
3. **Compose commands**: Build complex operations from simple ones
4. **Idempotent**: Safe to retry
5. **Return promises**: For async operations

### Query Design

1. **Pure functions**: No side effects
2. **Composable**: Chain filters, sorts, maps
3. **Cached**: Use computed properties in Vue
4. **Specific**: Create queries for each use case
5. **Filter deleted**: Exclude soft-deleted items
6. **Never filter in components**: All filtering, sorting, and data manipulation must be done in Queries

**❌ Bad: Filtering in components**

```javascript
// In Vue component
computed: {
  selectedFeeds() {
    // Don't filter in components!
    return this.feeds.filter(feed => feed.tags && feed.tags.includes(this.tag.id))
  },

  filteredItems() {
    // Don't filter in components!
    return this.items.filter(item => item.author === this.selectedAuthor)
  }
}
```

**✅ Good: Create query methods**

```javascript
// In Queries class
feedsForTag(tag) {
  const accountId = tag.accountId
  return this.state.findAll(accountId, 'feeds')
    .filter(feed => !feed._deleted && feed.tags && feed.tags.includes(tag.id))
    .sort((a, b) => a.title.localeCompare(b.title))
}

feedIdsForTag(tag) {
  return this.feedsForTag(tag).map(feed => feed.id)
}

itemsForFeedByAuthor(feed, author) {
  return this.itemsForFeed(feed)
    .filter(item => item.author === author)
}

findTagByName(account, name) {
  const tags = this.tagsForAccount(account)
  const matching = tags.filter(t => t.name === name)
  return matching[matching.length - 1] // Most recently created
}

// In Vue component
computed: {
  selectedFeeds() {
    // Use query method
    return this.app.queries.feedsForTag(this.tag)
  },

  selectedFeedIds() {
    // Use specialized query method
    return this.app.queries.feedIdsForTag(this.tag)
  },

  filteredItems() {
    // Use query method with parameters
    if (this.selectedAuthor) {
      return this.app.queries.itemsForFeedByAuthor(this.feed, this.selectedAuthor)
    }
    return this.app.queries.itemsForFeed(this.feed)
  }
}
```

**Why this matters:**

- **Single responsibility**: Components handle UI, Queries handle data access
- **Reusability**: Query methods can be used across multiple components
- **Testability**: Query logic can be tested independently
- **Performance**: Complex queries can be optimized in one place
- **Maintainability**: Data access patterns are centralized
- **Type safety**: Easier to document and type-check query methods
- **Consistency**: All filtering follows the same patterns

### State Management

1. **Aggregate roots**: Group related entities (journey + checkpoints)
2. **Snapshot strategy**: Periodically snapshot state for faster restore
3. **Event versioning**: Include version field for schema evolution
4. **Soft deletes**: Mark as deleted, don't remove from event store
5. **Bounded contexts**: Separate event stores per aggregate

### Testing

1. **Test events**: Verify correct events are emitted
2. **Integration tests**: Test user journeys, not units
3. **Event replay**: Test state reconstruction
4. **Deterministic**: Same events = same state
5. **Mock adapters**: Test without external dependencies

---

## Migration Guide

If you're migrating from traditional state management to Event Sourcing + CQRS:

### Step 1: Add Event Store

```javascript
// Install dependencies
npm install localforage uuid

// Create event store
import EventStore from '@/state/event-store'
import runners from '@/state/runners'

const db = localforage.createInstance({ name: 'myapp' })
const state = new EventStore(db, runners)
```

### Step 2: Define Runners

```javascript
// src/state/runners.js
export default {
  'todos.create': EventStore.RUNNERS.CREATE,
  'todos.delete': EventStore.RUNNERS.DELETE,

  'todos.complete'(event) {
    const todo = this.todos.find(t => t.id === event.objectId)
    if (todo) todo.complete = true
  }
}
```

### Step 3: Create Commands

```javascript
// src/commands/index.js
export class Commands {
  constructor({ state }) {
    this.state = state
  }

  addTodo(todo) {
    // Event store generates ID
    const event = this.state.track('todos', null, 'create', todo)
    todo.id = event.objectId
  }

  completeTodo(todo) {
    this.state.track('todos', todo.id, 'complete')
  }

  removeTodo(todo) {
    this.state.track('todos', todo.id, 'delete')
  }
}
```

### Step 4: Create Queries

```javascript
// src/queries/index.js
export class Queries {
  constructor({ state }) {
    this.state = state
  }

  allTodos() {
    return this.state.findAll('todos')
      .filter(todo => !todo._deleted)
  }

  incompleteTodos() {
    return this.allTodos()
      .filter(todo => !todo.complete)
  }
}
```

### Step 5: Update Vue Components

```vue
<script>
export default {
  data() {
    const state = new EventStore(db, runners)
    const queries = new Queries({ state })
    const commands = new Commands({ state })

    return { queries, commands }
  },

  computed: {
    todos() {
      return this.queries.allTodos()
    }
  },

  methods: {
    addTodo(text) {
      this.commands.addTodo({ text })
    }
  }
}
</script>
```

---

## Conclusion

This Event-Sourced CQRS pattern with Vue.js provides:

- **Separation of concerns** between reads and writes
- **Complete audit trail** of all changes
- **Offline-first** architecture with sync
- **Time-travel debugging** capabilities
- **Flexible storage** via adapters
- **Testable** through event verification
- **Scalable** multi-tenant support

The pattern works exceptionally well with Vue's reactivity system, providing automatic UI updates when state changes through events.

---

## Resources

- [Original Article](https://dev.dallasread.com/building-a-web-app-from-scratch-using-vue-js-and-cqrs)
- [Together Progress App](https://app.togetherprogress.com)
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html)
- [CQRS Pattern](https://martinfowler.com/bliki/CQRS.html)
- [Vue.js Documentation](https://vuejs.org)

---

*Last updated: 2025-11-08*
