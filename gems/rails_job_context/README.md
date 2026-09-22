# rails_job_context

Carry selected `ActiveSupport::CurrentAttributes` through Active Job, with one
ancestry stack shared across named contexts. Ruby 3.1+, Active Job 7.2 through 8.x.

This repository publishes two gems:

| Gem | Purpose | Runtime dependencies |
| --- | --- | --- |
| `rails_job_context` | Context snapshots, restoration, and job ancestry | Active Job, Active Support |
| `rails_job_context-good_job` | Context and ancestry in the GoodJob dashboard | Core gem, Railties, GoodJob 3.99 through 4.x |

The core package contains no GoodJob integration or templates.

## Application setup

```ruby
# Gemfile
gem 'rails_job_context'

# app/models/request_current.rb
class RequestCurrent < ActiveSupport::CurrentAttributes
  attribute :user, :controller, :action, :request, :correlation_stack
end

# app/models/tenant_current.rb
class TenantCurrent < ActiveSupport::CurrentAttributes
  attribute :account
end

# config/initializers/rails_job_context.rb
JobContext.configure do |config|
  config.contexts = {
    request: {
      current_attributes: -> { RequestCurrent },
      attributes: %i[user controller action]
    },
    tenant: {
      current_attributes: -> { TenantCurrent },
      attributes: %i[account]
    }
  }
  config.correlation_context = :request
end

# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include JobContext::Job
end
```

One context is enough; add more when your application uses separate Current
classes. Context names identify the entries in the payload and do not depend on
configuration order. Each entry accepts a CurrentAttributes subclass or a callable
returning one. Use callables for classes Rails reloads in development.

`contexts` and `correlation_context` are required. Only the correlation owner must
declare `correlation_stack`. Set `config.correlation_attribute` to use another
attribute on that owner. The stack is independent of selected attributes and is
never duplicated across contexts.

Each context has its own selection and exclusions:

```ruby
config.contexts = {
  request: {
    current_attributes: -> { RequestCurrent },
    attributes: :all,
    except: %i[request]
  }
}
config.correlation_context = :request
```

The default selection is empty. `:all` includes later-declared and unset
attributes. Exclusions still apply, and the owner's correlation attribute is
handled separately. Unsupported values raise `ActiveJob::SerializationError`
with the context and attribute name. Active Job serializers and GlobalID handle
supported values, including persisted models. GlobalID stores record identity,
not a snapshot of database columns.

The gem defines the top-level `JobContext` module. A conflicting class with that
name causes a clear error when the gem loads.

## Enqueueing and execution

Use normal Active Job calls; arguments and keyword arguments remain unchanged:

```ruby
ReportJob.perform_later(42, format: 'csv')
ReportJob.set(wait: 5.minutes).perform_later(42)
```

The namespaced `job_context` payload contains a format version, a map of serialized
named contexts, the correlation owner's name, and one ancestry stack. The stack
includes this job's ID. A child job appends its own ID. Repeated serialization and
retries reuse the first snapshot, including detached nested strings and collections.

During execution, nested `Current.set` blocks restore every configured context.
Previous values return even when execution raises. Only selected attributes are
set; exclusions do not clear values already present in the execution environment.
Direct `perform_now` captures the caller's context when no snapshot exists.

This is an unreleased format with no legacy metadata reader. Configure the same
context names and correlation owner in enqueueing and worker processes.

## Transactions and Rails compatibility

Snapshots are captured before Rails defers enqueueing until transaction commit:

```ruby
class ReportJob < ApplicationJob
  self.enqueue_after_transaction_commit = true
end

ApplicationRecord.transaction do
  RequestCurrent.set(user: alice) do
    ReportJob.perform_later(42)
  end
end
```

The job retains Alice even though the surrounding `RequestCurrent.set` ends
before commit. Rolling back prevents enqueueing. Rails and the queue adapter own
transaction deferral; the gem does not enable it globally.

The capture hooks depend on private Active Job methods:

- Rails 7.2 and 8.0: `raw_enqueue`, after enqueue callbacks enter and before deferral.
- Rails 8.1: `_raw_enqueue` for immediate jobs, after callbacks enter.
- Rails 8.1 with deferral: `raw_enqueue`, before Rails defers callbacks and enqueueing.
  Changes made by those deferred callbacks do not replace the saved snapshot.

Compatibility tests cover callback timing and real PostgreSQL transactions.
Framework upgrades require these checks because the hooks are private.

For bulk enqueueing, use:

```ruby
JobContext.perform_all_later(ReportJob.new(1), ReportJob.new(2))
```

This captures participating jobs before delegating to `ActiveJob.perform_all_later`.
Per-job enqueue callbacks do not run, and the wrapper does not add transaction
deferral to bulk enqueueing.

## Optional GoodJob dashboard

Add the companion gem. No `require:` option is needed:

```ruby
# Gemfile
gem 'rails_job_context-good_job'

# config/initializers/rails_job_context_good_job.rb
JobContext::Dashboard.configure do |config|
  config.details = true
  config.table = false
end
```

The companion depends on the core and loads its Rails engine during boot. Details
are enabled by default; replacing the jobs table is opt-in. See the
[companion README](https://github.com/NicolasJJensen/rails_job_context/tree/main/gems/rails_job_context-good_job) for template
compatibility and application overrides.

## Development

```sh
bundle install
bundle exec rake
bundle exec rake build
```

Both packages use the same version initially. `rake build` builds each gemspec into
`pkg/`. Publish both artifacts for a coordinated release, with the core first.
The companion declares the matching core version as its dependency.

Run the core without GoodJob in the bundle:

```sh
BUNDLE_GEMFILE=gemfiles/core_rails_8_0.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/core_rails_8_0.gemfile bundle exec rspec gems/rails_job_context/spec
```

The compatibility matrix tests Rails 7.2, 8.0, and 8.1, plus GoodJob template
boundaries. PostgreSQL specs create and drop a uniquely named scratch database.
They use `postgres:///postgres` as the administrative connection by default.
Set `JOB_CONTEXT_PG_URL` to another administrative URL if needed. The database
user must be able to create databases. No browser is required.

## License

Both gems use the [MIT License](LICENSE.txt). The companion also includes
GoodJob's copyright notice for its derived table templates.
