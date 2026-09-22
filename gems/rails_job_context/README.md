# rails_job_context

Keep request context available in Active Job. Carry selected attributes, such as
the current user or account, into background jobs and track which jobs enqueue
other jobs.

Requires Ruby 3.1 or later and Active Job / Active Support 7.2 through 8.x.

## Installation

Add to your application's Gemfile, then run `bundle install`:

```ruby
gem 'rails_job_context'
```

## Quickstart

Define the attributes to capture and an attribute for job ancestry:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account_id, :correlation_stack
end
```

Configure the context:

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
multiple Current classes, attribute exclusions, supported values, ancestry,
transactions, and bulk enqueueing.

For dashboard views, add the optional
[GoodJob companion](https://github.com/NicolasJJensen/rails_job_context/tree/main/gems/rails_job_context-good_job).

## Contributing

See the [contribution guide](https://github.com/NicolasJJensen/rails_job_context/blob/main/CONTRIBUTING.md)
for development and testing instructions.

## License

Available under the [MIT License](LICENSE.txt).
