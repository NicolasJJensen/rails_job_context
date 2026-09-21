require 'rspec/core'
require 'rspec/expectations'
require 'rspec/mocks'
require 'json'
require 'logger'
require 'rails_job_context'
ActiveJob::Base.logger = Logger.new(File::NULL)

# Re-derives GoodJob's jobs-table boundaries independently of the gem, so a
# change to either side fails the specs instead of agreeing with itself.
module TableSeriesExpectations
  BOUNDARIES = [['3.99', 'v3'], ['4.0', 'v4_0'], ['4.13.1', 'v4_13'],
                ['4.17', 'v4_17'], ['4.18', 'v4_18'], ['5', nil]].freeze

  def expected_table_series(version = GoodJob::VERSION)
    version = Gem::Version.new(version)
    BOUNDARIES.reverse.each do |lower, series|
      return series if version >= Gem::Version.new(lower)
    end
    nil
  end
end

RSpec.configure do |config|
  config.order = :random
  config.include TableSeriesExpectations
  config.extend TableSeriesExpectations
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.before do
    JobContext.instance_variable_set(:@config, JobContext::Configuration.new)
    ActiveSupport::CurrentAttributes.clear_all
  end
  config.after { ActiveSupport::CurrentAttributes.clear_all }
end
