# rails_job_context-good_job

See the context and ancestry behind each background job. Display saved attributes
and links to parent and root jobs in your existing GoodJob dashboard.

## Installation

The companion requires Ruby 3.1 or newer, Rails 7.2 through 8.x, and GoodJob
`>= 3.99, < 5`. Your application must already use and mount GoodJob's dashboard.

Add the gem to your Gemfile:

```ruby
gem 'rails_job_context-good_job'
```

Configure the core gem and include `JobContext::Job` as described in the root
project's [setup guide](https://github.com/NicolasJJensen/rails_job_context#setup).
Run `bundle install` and restart the application. The companion loads during Rails boot and adds its dashboard views automatically.

Details are enabled by default. The default table remains GoodJob's table, so you
can install the companion without adding dashboard configuration.

## Dashboard details

The direct cause is the parent job. The root cause is the first job in the chain. It links to
those GoodJob records when they still exist. For an initial job, it shows the
correlation owner's controller and action, such as `orders#create`.

The panel also groups the saved attributes by context name. Each group shows the
serialized values saved by the core gem. Dashboard rendering
reads those values without resolving GlobalIDs or instantiating serialized objects.

If your application already defines GoodJob's custom details partial, keep that
partial and render the companion partial inside it:

```erb
<%= render 'job_context/details', job: job %>
```

Place the host partial at `app/views/good_job/_custom_job_details.html.erb`.
Application views take precedence over the companion views.

## Jobs table

Enable the additional table columns:

```ruby
# config/initializers/rails_job_context_good_job.rb
JobContext::Dashboard.configure do |config|
  config.table = true
end
```

The table adds direct-cause and root-cause columns. It uses the same links and
origin labels as the details panel. Missing context displays `Unknown origin`.
Deleted ancestors display `Unavailable job (ID)`.

The table replacement supports GoodJob `>= 3.99, < 5`. The integration selects a
matching GoodJob template for each supported release series. See the
[compatibility notes](https://github.com/NicolasJJensen/rails_job_context/blob/main/docs/compatibility.md)
for upgrade considerations. Set dashboard options during application boot.

## License

This gem uses the [MIT License](LICENSE.txt). Its table templates derive from
[GoodJob](https://github.com/bensheldon/good_job), copyright Ben Sheldon. The
original notice is included in [LICENSE.good_job.txt](LICENSE.good_job.txt).
