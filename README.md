# rails_job_context

Keep request context available in Active Job. Carry selected attributes, such as
the current user or account, into background jobs and track which jobs enqueue
other jobs.

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
- Inspect parent and root jobs with the optional GoodJob dashboard integration.

## Installation

Requires Ruby 3.1 or later and Active Job / Active Support 7.2 through 8.x.

Add to your application's Gemfile:

```ruby
gem 'rails_job_context'
```

Then run `bundle install`.

## Setup

Add the attributes you want to carry to your Current class, together with an
attribute for job ancestry:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account_id, :correlation_stack
end
```

Register the class and select its attributes:

```ruby
# config/initializers/rails_job_context.rb
JobContext.configure do |config|
  config.contexts = {
    request: {
      current_attributes: -> { Current },
      attributes: %i[account_id]
    }
  }
  config.correlation_context = :request
end
```

Here, `request` names this context. `correlation_context` selects the class whose
`correlation_stack` holds the job ancestry. Use a callable so Rails can reload
your Current class in development.

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

| Setting | Default | Description |
| --- | --- | --- |
| `contexts` | Required | Named definitions for the Current classes to capture |
| `correlation_context` | Required | Name of the context that holds job ancestry |
| `correlation_attribute` | `:correlation_stack` | Ancestry attribute declared on that context's class |

Each entry in `contexts` accepts:

| Setting | Default | Description |
| --- | --- | --- |
| `current_attributes` | Required | A `CurrentAttributes` subclass or callable returning one |
| `attributes` | `[]` | Attribute names to capture, or `:all` |
| `except` | `[]` | Attribute names to exclude |

### Multiple Current classes

Give each class a name and its own attribute selection:

```ruby
class TenantCurrent < ActiveSupport::CurrentAttributes
  attribute :account_id
end

JobContext.configure do |config|
  config.contexts = {
    request: { current_attributes: -> { Current }, attributes: [] },
    tenant: { current_attributes: -> { TenantCurrent }, attributes: %i[account_id] }
  }
  config.correlation_context = :request
end
```

Only the selected correlation owner needs an ancestry attribute. Each context
must resolve to a different class. Names are matched independently of their order;
use the same names and correlation owner in enqueueing and worker processes.

### Selecting all attributes

For a Current class with a `request` attribute that should stay out of jobs:

```ruby
JobContext.configure do |config|
  config.contexts = {
    request: {
      current_attributes: -> { Current },
      attributes: :all,
      except: %i[request]
    }
  }
  config.correlation_context = :request
end
```

`:all` includes later-declared attributes and unset values. The owner's ancestry
attribute is managed separately, even when the selection is empty or excludes it.
Excluded attributes are not captured; they do not clear values already present
in the worker.

Values must be supported by Active Job's serializers. Unsupported values raise
`ActiveJob::SerializationError` naming the context and attribute. Persisted models
use GlobalID: the job reloads the record by identity rather than receiving a
snapshot of its database columns.

## Job ancestry

`Current.correlation_stack` contains job IDs from the root job to the currently
running job. For example, if `ImportJob` enqueues `ReportJob`:

```text
Inside ImportJob: [import_job_id]
Inside ReportJob: [import_job_id, report_job_id]
```

The last ID is the current job, the preceding ID is its parent, and the first ID
is the root. A retry retains the same stack. The caller's stack is restored after
execution.

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

Use the wrapper for bulk enqueueing:

```ruby
JobContext.perform_all_later(ReportJob.new, ReportJob.new)
```

It captures context before delegating to `ActiveJob.perform_all_later`. Bulk jobs
do not run per-job enqueue callbacks, and the wrapper does not add transaction
deferral.

## GoodJob integration

Add the companion gem to display saved contexts and job ancestry in GoodJob:

```ruby
gem 'rails_job_context-good_job'
```

Job details are enabled by default. The jobs table can also display parent and root
causes. See the [GoodJob integration guide](gems/rails_job_context-good_job/README.md)
for setup and configuration.

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
