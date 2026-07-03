Have a look at ~/apps/com/dallasread/dev/_simple-cqrs

## The migration you need to run (Postgres)

The reference ships `Storage::Sqlite` but not the migration that creates the log. For a multi-tenant
Postgres app it looks like this. Two things the reference (single-tenant SQLite) doesn't cover, and that
will bite you otherwise: a **`namespace`** column for per-tenant isolation (`Storage` scopes every
read/write to it), and **`config.active_record.schema_format = :sql`** — Ruby `schema.rb` can't
represent the triggers, so without this the test DB loads a table with no append-only enforcement.

```ruby
class CreateEvents < ActiveRecord::Migration[7.1]
  def up
    create_table :events, id: false do |t|
      t.primary_key :seq                 # bigserial — cross-process append order
      t.uuid    :event_id,   null: false # the event's own identity (survives upcasting)
      t.uuid    :namespace,  null: false # the tenant (e.g. Account id); drop if single-tenant
      t.string  :collection, null: false
      t.uuid    :record_id,  null: false
      t.string  :action,     null: false
      t.jsonb   :data
      t.string  :actor
      t.bigint  :time,       null: false # SimpleCqrs millisecond clock
      t.integer :version,    null: false, default: 1
      t.string  :upcasted_from
    end
    add_index :events, :event_id, unique: true
    add_index :events, %i[namespace collection]
    add_index :events, %i[namespace record_id]

    # Append-only: a row, once written, can never be changed or removed. (TRUNCATE fires a different
    # trigger class, so a transactional/truncating test harness can still reset the table.)
    execute <<~SQL.squish
      CREATE OR REPLACE FUNCTION events_reject_mutation() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'events is append-only; % is not allowed', TG_OP; END;
      $$ LANGUAGE plpgsql;
    SQL
    execute "CREATE TRIGGER events_no_update BEFORE UPDATE ON events FOR EACH ROW EXECUTE FUNCTION events_reject_mutation();"
    execute "CREATE TRIGGER events_no_delete BEFORE DELETE ON events FOR EACH ROW EXECUTE FUNCTION events_reject_mutation();"
  end

  def down
    execute "DROP TRIGGER IF EXISTS events_no_update ON events;"
    execute "DROP TRIGGER IF EXISTS events_no_delete ON events;"
    execute "DROP FUNCTION IF EXISTS events_reject_mutation();"
    drop_table :events
  end
end
```

After adding `config.active_record.schema_format = :sql` to `config/application.rb`, run the migration
(it regenerates `db/structure.sql` with the function + triggers) and delete the now-stale `db/schema.rb`.

The `Storage::Postgres` adapter mirrors the reference's `Storage::Sqlite`, plus: `initialize(namespace:)`,
every query scoped `where(namespace:)`, `append` sets `namespace`, and `data` is `deep_symbolize_keys`-ed
on read (the `jsonb` column hands back string keys; events fold on symbols).

## Async reactions

For durable off-request reactions, dispatch each one to ActiveJob by the reaction's index in
`Workflow.reactions_for(event)` (a reaction is a Proc and can't be serialized; the worker re-derives the
same ordered list). With Rails 7.1, **Solid Queue** runs inside Puma (`plugin :solid_queue` in
`config/puma.rb`) — no separate worker dyno.
