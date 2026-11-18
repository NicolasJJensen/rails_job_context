# rails_job_context

Keep request context available in Active Job. Carry selected attributes, such as
the current user or account, into background jobs.

Requires Ruby 3.1 or later and Active Job / Active Support 7.2 through 8.x.

## Installation

Add to your application's Gemfile, then run `bundle install`:

```ruby
gem 'rails_job_context'
```

## Quickstart

Define the attributes to capture:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account_id
end
```

Configure the context:

```ruby
# config/initializers/rails_job_context.rb
JobContext.configure do |config|
  config.contexts << {
    current_attributes: -> { Current },
    attributes: %i[account_id]
  }
end
```

Enable propagation and enqueue a job:

```ruby
class ApplicationJob < ActiveJob::Base
  include JobContext::Job
end

class ReportJob < ApplicationJob
  def perform
    Rails.logger.info("Account: #{Current.account_id}")
  end
end

Current.set(account_id: 42) { ReportJob.perform_later }
```

The job logs `Account: 42`. Its context is captured before transaction-deferred
enqueueing and retained across retries. Previous worker values are restored after
execution, including when the job raises.

The [full guide](https://github.com/NicolasJJensen/rails_job_context#readme) covers
multiple Current classes, attribute exclusions, and supported values, plus
transactions and bulk enqueueing.

For dashboard views, add the optional
[GoodJob companion](https://github.com/NicolasJJensen/rails_job_context/tree/main/gems/rails_job_context-good_job).

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

## Limitations

Rails bulk enqueueing bypasses per-job enqueue callbacks and transaction deferral,
including `enqueue_after_transaction_commit`. The adapter determines whether bulk
jobs participate in a database transaction or survive a rollback.

For jobs without a saved snapshot, bulk enqueueing captures Current values when
the adapter serializes each job. If an adapter postpones serialization until after
Current changes or resets, the job can capture different values. This is an
adapter-dependent limitation, not a known failure with a specific supported adapter.

## Contributing

See the [contribution guide](https://github.com/NicolasJJensen/rails_job_context/blob/main/CONTRIBUTING.md)
for development and testing instructions.

## License

Available under the [MIT License](LICENSE.txt).
