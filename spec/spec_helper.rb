require 'rspec/core'
require 'rspec/expectations'
require 'rspec/mocks'
require 'json'
require 'logger'
require 'rails_job_context'
ActiveJob::Base.logger = Logger.new(File::NULL)

RSpec.configure do |config|
  config.order = :random
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.before do
    JobContext.instance_variable_set(:@config, JobContext::Configuration.new)
    if defined?(JobContext::Dashboard)
      JobContext::Dashboard.instance_variable_set(:@config, nil)
      JobContext::Dashboard.details_partials.clear if JobContext::Dashboard.respond_to?(:details_partials)
    end
    ActiveSupport::CurrentAttributes.clear_all
  end
  config.after { ActiveSupport::CurrentAttributes.clear_all }
end
