# rails_job_context

Carry selected CurrentAttributes through Active Job and show job ancestry in an
optional GoodJob dashboard integration. Ruby 3.1+, Active Job 7.2 through 8.x. The
dashboard integration supports GoodJob 3.99 and 4.x, and so does its optional
table override.

## Namespace

The gem name is `rails_job_context`, and it defines the top-level constant
`JobContext`. Loading the gem raises `TypeError` when another library already
defines `JobContext` as a class.

## Application setup

```ruby
# Gemfile
gem 'rails_job_context'

# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :controller, :action, :request, :correlation_stack
end

# config/initializers/rails_job_context.rb
JobContext.configure do |config|
  # The callable resolves the current class after Rails reloads application code.
  config.current_attributes = -> { Current }
  config.attributes = %i[user controller action]
end

# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include JobContext::Job
end
```

`config.current_attributes` has no default and is required. Every code path that
serializes a job reads it, so leaving it unset raises `ArgumentError` on the first
enqueue. Point it at a `ActiveSupport::CurrentAttributes` subclass, or at a
callable returning one when Rails reloads that class in development.

Every declared attribute can be selected with `:all`. Exclusions still apply:

```ruby
config.attributes = :all
config.except = %i[request]
```

`:all` includes attributes declared later and unset attributes (captured as nil).
The default attribute list is empty; correlation tracking is independent of the
attribute list and always enabled. Declare `correlation_stack` on your Current
class, or configure `correlation_attribute` to another declared attribute.
Unsupported values raise `ActiveJob::SerializationError` naming the attribute.
Active Job serializers and GlobalID handle supported values, including persisted
models. The library does not persist live request objects or silently drop them.
A GlobalID stores record identity, not a snapshot of its database columns.

## Enqueueing, execution, and transactions

Use regular Active Job calls. Arguments and keyword arguments are untouched:

```ruby
ReportJob.perform_later(42, format: 'csv')
ReportJob.set(wait: 5.minutes).perform_later(42)
```

A namespaced `job_context` field is added to Active Job's serialized
payload alongside `arguments`. The field contains a version, serialized selected
attributes, and the ancestor IDs including this job's ID. Repeated serialization
and retries reuse the first snapshot. A new child job appends its own ID.

Context is captured after enqueue callbacks reach the adapter handoff, before
Rails can defer that handoff until commit. The selected serialized values are
copied so later mutation does not change the saved context:

```ruby
class ReportJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  def perform(report_id)
    # Current.user is Alice, although the enclosing Current.set has ended.
  end
end

ApplicationRecord.transaction do
  Current.set(user: alice) do
    ReportJob.perform_later(42)
  end
end
```

Rolling back the transaction does not enqueue the job. Transaction deferral is
owned by Rails and its configured adapter; the gem does not enable it globally.
The capture hook uses Active Job's private `raw_enqueue` handoff, added in Rails 7.2.
That handoff sets the floor of the supported Rails range, and transaction regression
tests are included.

During `perform`, selected saved attributes and the correlation stack are set
inside a `Current.set` block. Previous values are restored even if execution
raises. Excluded attributes are not carried in the payload. Direct `perform_now`
uses the same execution wrapper and captures context if no snapshot exists.

For bulk work, use the explicit snapshot wrapper:

```ruby
JobContext.perform_all_later(ReportJob.new(1), ReportJob.new(2))
```

It snapshots participating jobs before delegating to `ActiveJob.perform_all_later`.
Rails' bulk enqueue semantics still apply: per-job enqueue callbacks do not run,
and this wrapper does not add transaction deferral to bulk enqueueing.

## GoodJob dashboard

Require the integration through Bundler so its engine is registered before Rails
initializes:

```ruby
# Gemfile
gem 'rails_job_context', require: 'rails_job_context/good_job'

# Inside JobContext.configure:
config.good_job.details = true  # default
config.good_job.table = false   # optional; GoodJob 3.99.x and every 4.x release
```

`require 'rails_job_context/good_job'` needs both `rails` and `good_job`. Neither
is a dependency of this gem, because the core library runs without them. Your
application supplies both. The integration accepts good_job `>= 3.99, < 5`, and
raises `JobContext::Error` naming that range when Bundler resolves another
version.

The details integration uses GoodJob's `good_job/custom_job_details` partial hook,
which exists in GoodJob 3.99 and 4.x. One partial serves both series.

The table integration instead replaces GoodJob's complete jobs-table template.
GoodJob rewrote that template three times inside the 4.x series, so the gem
carries one copy per structural revision and picks the copy by `Gem::Version`
comparison. The ranges are contiguous and cover every release from 3.99 to 5:

| GoodJob | Template series shipped by this gem |
| --- | --- |
| `>= 3.99, < 4` | `integrations/good_job/views/v3/good_job/jobs/_table.erb` |
| `>= 4.0, < 4.13.1` | `integrations/good_job/views/v4_0/good_job/jobs/_table.erb` |
| `>= 4.13.1, < 4.17` | `integrations/good_job/views/v4_13/good_job/jobs/_table.erb` |
| `>= 4.17, < 4.18` | `integrations/good_job/views/v4_17/good_job/jobs/_table.erb` |
| `>= 4.18, < 5` | `integrations/good_job/views/v4_18/good_job/jobs/_table.erb` |

Each split matches an upstream release that changed what the template calls.
Release 4.13.1 replaced the rails-ujs row action links with `job_action_form` and
`job_destroy_form` button forms. Release 4.17 moved row selection onto a Stimulus
`checkbox-toggle` controller. Release 4.18 moved the row actions onto the
`job_action_states` helper, which earlier releases do not define. The remaining
upstream edits inside a range are cosmetic, so one copy serves the whole range.

Setting `config.good_job.table = true` on a release outside `>= 3.99, < 5` raises
`JobContext::Error` during boot rather than rendering a broken dashboard. Leave it
false there and use the details hook, which shows the same causes on the job page.

Configure these options during application boot; restart to change them.
Application view overrides retain precedence.

If your application already supplies the details hook, render the gem's details
partial from your existing template rather than replacing your content:

```erb
<%= render 'job_context/details', job: job %>
```

Both views show the immediate parent and root job, or the originating controller
and action for initial jobs. Missing context displays `Unknown origin`. Deleted
ancestors display `Unavailable job (ID)`. The table loads all required ancestor
records in one query per render, with no per-row lookups. Dashboard readers do
not resolve GlobalIDs from job context just to display origin labels.

## Migrating from hand-rolled Current propagation

A common home-grown approach appends a trailing options hash holding a
`__metadata__` key, with the caller's Current values under
`current_attributes`. Replace those concerns in `ApplicationJob` with
`include JobContext::Job`, and delete any local copies of the GoodJob
correlation templates so the gem's views resolve. Your Current class, your jobs,
your GoodJob configuration, and your worker deployment stay where they are.

The gem reads and restores jobs already enqueued in that old shape. It removes
the metadata before `perform` and keeps the caller's own options. Dashboard rows
render from either format. One edge remains: the old shape cannot tell an
originally explicit empty options hash from a hash added only to carry metadata,
so an empty trailing metadata-only hash is dropped.

## Development

Clone the repository, then:

```sh
bundle install
bundle exec rake
gem build rails_job_context.gemspec
```

The transaction specs create and drop a uniquely named PostgreSQL database,
using `postgres:///postgres` as the administrative connection by default. Set
`JOB_CONTEXT_PG_URL` to another PostgreSQL administrative URL if needed;
the connected user needs permission to create a database. Tables are created only
in the generated scratch database, never in the supplied administrative database.
No browser is required for the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/NicolasJJensen/rails_job_context.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

The table templates under `integrations/good_job/views/` derive from
[GoodJob](https://github.com/bensheldon/good_job), copyright Ben Sheldon, used
under the MIT License. GoodJob's notice is reproduced verbatim in
[LICENSE.good_job.txt](LICENSE.good_job.txt) and ships inside the gem package.
