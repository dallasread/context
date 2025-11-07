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
    checkpoint.id = checkpoint.id || uuid()
    checkpoint.order = checkpoint.order ?? this.queries.findAllCheckpointsForJourney(journey).length

    this.track(journey, 'checkpoints', checkpoint.id, 'create', checkpoint)
  }

  // Remove checkpoint (soft delete)
  removeCheckpointFromJourney(journey, checkpoint) {
    this.track(journey, 'checkpoints', checkpoint.id, 'delete')
  }

  // Complete a checkpoint
  completeCheckpointForJourney(journey, checkpoint) {
    const completion = {
      id: uuid(),
      checkpointId: checkpoint.id,
      completedAt: Date.now()
    }

    this.track(journey, 'checkpointCompletions', completion.id, 'create', completion)
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
    todo.id = uuid()
    this.state.track('todos', todo.id, 'create', todo)
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

*Last updated: 2025-11-07*
