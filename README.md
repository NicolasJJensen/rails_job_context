# rails_job_context

Keep request context available in Active Job. Carry selected attributes, such as
the current user or account, into background jobs.

Once configured, jobs can read the context captured when they were enqueued:

```ruby
class ReportJob < ApplicationJob
  def perform
    Rails.logger.info("Account: #{Current.account_id}") # Account: 42
  end
end

Current.set(account_id: 42) { ReportJob.perform_later }
```

- Select which attributes to carry from one or more `CurrentAttributes` classes.
- Preserve the captured values across retries and transaction-deferred enqueueing.
- Inspect saved attributes with the optional GoodJob dashboard integration.

## Installation

Requires Ruby 3.1 or later and Active Job / Active Support 7.2 through 8.x.

Add to your application's Gemfile:

```ruby
gem 'rails_job_context'
```

Then run `bundle install`.

## Setup

Define the attributes you want to carry in your Current class:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account_id
end
```

Register the class and select its attributes:

```ruby
# config/initializers/rails_job_context.rb
JobContext.configure do |config|
  config.contexts << {
    current_attributes: -> { Current },
    attributes: %i[account_id]
  }
end
```

Use a callable so Rails can reload your Current class in development. The gem
identifies each context by its class name, so configuration order does not affect
which class receives saved attributes.

Include the concern in your application job:

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include JobContext::Job
end
```

## Usage

Enqueue jobs with the usual Active Job methods:

```ruby
class ReportJob < ApplicationJob
  def perform
    Rails.logger.info("Account: #{Current.account_id}")
  end
end

Current.set(account_id: 42) do
  ReportJob.perform_later
end
```

The job logs `Account: 42`, even though the caller's `Current.set` block has ended.
Selected values are available during execution, and the worker's previous values
are restored afterward, including when the job raises an exception.

Positional and keyword arguments work as usual. `perform_now` also restores context
and captures the caller's values if the job does not already have a snapshot.

## Configuration

`config.contexts` is an array of registrations. Append with `<<`, or assign the
complete array with `config.contexts = [...]`.

Each registration accepts:

| Setting | Default | Description |
| --- | --- | --- |
| `current_attributes` | Required | A named `CurrentAttributes` subclass or callable returning one |
| `attributes` | `[]` | Attribute names to capture, or `:all` |
| `except` | `[]` | Attribute names to exclude |

### Multiple Current classes

Register each class with its own attribute selection:

```ruby
class TenantCurrent < ActiveSupport::CurrentAttributes
  attribute :account_id
end

JobContext.configure do |config|
  config.contexts = [
    { current_attributes: -> { Current }, attributes: %i[account_id] },
    { current_attributes: -> { TenantCurrent }, attributes: %i[account_id] }
  ]
end
```

Each registration must resolve to a different named class. Use the same classes
in enqueueing and worker processes. The worker matches saved class names against
its registrations; it does not load classes named by the payload.

### Selecting all attributes

For a Current class with a `request` attribute that should stay out of jobs:

```ruby
JobContext.configure do |config|
  config.contexts = [
    {
      current_attributes: -> { Current },
      attributes: :all,
      except: %i[request]
    }
  ]
end
```

`:all` includes later-declared attributes and unset values. Excluded attributes are not captured; they do not clear values already present
in the worker.

Values must be supported by Active Job's serializers. Unsupported values raise
`ActiveJob::SerializationError` naming the context and attribute. Persisted models
use GlobalID: the job reloads the record by identity rather than receiving a
snapshot of its database columns.

## Transactions, retries, and bulk enqueueing

When Rails defers a job until transaction commit, the gem captures context before
that delay:

```ruby
class ReportJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  def perform
    Rails.logger.info("Account: #{Current.account_id}")
  end
end

ApplicationRecord.transaction do
  Current.set(account_id: 42) { ReportJob.perform_later }
end
```

The job receives account ID `42`. A rollback prevents enqueueing when transaction
deferral is enabled. Rails and the adapter control deferral; this gem does not
enable it globally. On Rails 8.1, deferred enqueue callbacks run after capture,
so their changes do not replace the saved context.

Retries and repeated serialization reuse the first snapshot. Later changes to
captured strings, arrays, or hashes do not alter it.

Use Rails for bulk enqueueing:

```ruby
ActiveJob.perform_all_later(ReportJob.new, ReportJob.new)
```

Bulk enqueueing captures context when the adapter serializes each job. See
[Limitations](#limitations) for capture timing and transaction behavior.

## Supported backends

The core depends on Active Job, not a particular queue backend. Use your backend
through Active Job and include `JobContext::Job` in your application job:

```ruby
config.active_job.queue_adapter = :solid_queue # or :sidekiq, :resque, :delayed_job
```

The backend integration suite covers these versions on Ruby 3.3 with Rails 7.2,
8.0, and 8.1:

| Backend | Verified version |
| --- | --- |
| Solid Queue | 1.4.0 |
| Sidekiq | 8.0.10 |
| Resque | 2.7.0, with resque-scheduler 4.11.0 for scheduled jobs and retries |
| Delayed Job | delayed_job_active_record 4.1.11 with delayed_job 4.2.0 |

Tests use real Redis or SQLite storage and invoke each backend's worker execution
path. They verify multiple Current classes, mutable snapshots, normal and bulk
jobs, scheduled jobs, child jobs, Active Job retries and discards, transaction
commit and rollback, and context cleanup. They do not start production worker
daemons or test backend-native retry policies.

GoodJob also has dedicated compatibility coverage. The optional
`rails_job_context-good_job` package provides its dashboard integration.

Other Active Job adapters may work, but are not covered by this backend suite.
Native jobs that bypass Active Job, such as Sidekiq workers using `perform_async`,
do not receive context from this gem. See [Limitations](#limitations) for bulk
transaction behavior.

## GoodJob integration

Add the companion gem to display saved context attributes in GoodJob:

```ruby
gem 'rails_job_context-good_job'
```

Job details are enabled by default. See the
[GoodJob integration guide](gems/rails_job_context-good_job/README.md) for setup.

## Job ancestry

For parent/root relationships and an ancestry chain, use the separate
`rails_job_ancestry` gem. It uses this gem to propagate its own state and does not
require ancestry attributes on your application's Current classes.

## Limitations

Rails bulk enqueueing bypasses per-job enqueue callbacks and transaction deferral,
including `enqueue_after_transaction_commit`. The adapter determines whether bulk
jobs participate in a database transaction or survive a rollback.

For jobs without a saved snapshot, bulk enqueueing captures Current values when
the adapter serializes each job. If an adapter postpones serialization until after
Current changes or resets, the job can capture different values. This is an
adapter-dependent limitation, not a known failure with a specific supported adapter.

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/NicolasJJensen/rails_job_context/issues).
From a repository checkout, install dependencies and run the tests:

```sh
bundle install
bundle exec rake
```

The transaction tests require PostgreSQL. See [CONTRIBUTING.md](CONTRIBUTING.md)
for database setup, compatibility testing, and release instructions.

## License

Available under the [MIT License](LICENSE.txt).
