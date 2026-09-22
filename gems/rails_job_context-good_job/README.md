# rails_job_context-good_job

Show named job contexts and direct/root job ancestry in GoodJob. This companion
gem includes the core `rails_job_context` dependency, Rails engine, dashboard
queries, and GoodJob templates.

## Setup

```ruby
# Gemfile
gem 'rails_job_context-good_job'

# config/initializers/rails_job_context_good_job.rb
JobContext::Dashboard.configure do |config|
  config.details = true
  config.table = false
end
```

Bundler loads the integration automatically. Configure the core contexts and
include `JobContext::Job` in your application job as described in the
[repository README](https://github.com/NicolasJJensen/rails_job_context).
Mount and secure GoodJob's dashboard using GoodJob's application setup.

Details default to enabled. The details partial uses GoodJob's documented
`good_job/custom_job_details` extension point. It groups saved attributes by
context and shows the immediate parent and root job. Initial jobs use the
correlation owner's controller/action attributes as their origin.

If your application already supplies the details hook, render the companion's
partial inside your existing template:

```erb
<%= render 'job_context/details', job: job %>
```

Application templates retain precedence. Set dashboard options during application
boot and restart to change them. The integration reinstalls view paths on Rails
reload without adding duplicates.

## Jobs table

Set `config.table = true` to show ancestry in the jobs table. This replaces the
complete internal GoodJob table, so the gem ships templates for specific series:

| GoodJob range | Template directory |
| --- | --- |
| `>= 3.99, < 4` | `integrations/good_job/views/v3` |
| `>= 4.0, < 4.13.1` | `integrations/good_job/views/v4_0` |
| `>= 4.13.1, < 4.17` | `integrations/good_job/views/v4_13` |
| `>= 4.17, < 4.18` | `integrations/good_job/views/v4_17` |
| `>= 4.18, < 5` | `integrations/good_job/views/v4_18` |

GoodJob 4.13.1 changed row actions to forms. Version 4.17 changed row selection
controllers, and 4.18 introduced the `job_action_states` helper. The gem selects a
template by the installed GoodJob version. Upgrades require compatibility tests
and review of upstream template changes.

The companion's dependency range is `good_job >= 3.99, < 5`, including when only
details are enabled. Bundler rejects incompatible combinations. Disabling table
replacement does not expand the companion's supported GoodJob range.

Missing context displays `Unknown origin`; deleted ancestors display
`Unavailable job (ID)`. The table fetches ancestors in one query per render.
Dashboard rendering reads serialized context without resolving GlobalIDs or
instantiating custom serialized objects.

## License

This gem uses the [MIT License](LICENSE.txt). Its table templates derive from
[GoodJob](https://github.com/bensheldon/good_job), copyright Ben Sheldon. The
original notice is included in [LICENSE.good_job.txt](LICENSE.good_job.txt).
