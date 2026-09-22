# rails_job_context-good_job

Inspect saved Current attributes in your GoodJob dashboard. Each job's details
page groups the captured values by their Current class.

## Installation

Requires Ruby 3.1 or later, Rails 7.2 through 8.x, and GoodJob `>= 3.99, < 5`.
Set up and mount GoodJob's dashboard in your application, then add:

```ruby
gem 'rails_job_context-good_job'
```

Run `bundle install` and restart the application. Configure your Current classes
and include `JobContext::Job` using the core [setup guide](https://github.com/NicolasJJensen/rails_job_context#setup).

The companion enables context details automatically. Saved GlobalIDs are displayed
without loading records. The original GoodJob jobs table remains unchanged.

## Configuration

To disable the context panel:

```ruby
JobContext::Dashboard.configure do |config|
  config.details = false
end
```

Set this option during application boot.

If your application supplies `app/views/good_job/_custom_job_details.html.erb`,
render the context panel inside that template:

```erb
<%= render 'job_context/details', job: job %>
```

Application templates take precedence over the companion's template.

## Extensions

Other dashboard integrations can add panels without replacing this companion's
GoodJob hook:

```ruby
JobContext::Dashboard.register_details_partial('my_extension/details')
```

The partial receives a `job` local. Repeated registration of the same path is
idempotent. Registered panels are independent of the context panel's `details`
setting and can apply their own settings.

For parent and root job links, use `rails_job_ancestry-good_job` from the separate
`rails_job_ancestry` project. It registers its ancestry panel through this interface.

## License

Available under the [MIT License](LICENSE.txt).
