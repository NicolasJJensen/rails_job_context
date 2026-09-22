require 'spec_helper'
require 'open3'

RSpec.describe 'Core loading' do
  it 'loads without activating Rails or GoodJob integration' do
    script = <<~'SCRIPT'
      require 'rails_job_context'
      abort 'Core loaded Rails' if defined?(Rails)
      abort 'Core loaded GoodJob' if defined?(GoodJob)
      abort 'Core exposes GoodJob settings' if JobContext.config.respond_to?(:good_job)
      abort 'Core loaded dashboard code' if $LOADED_FEATURES.any? { |path| path.end_with?('/job_context/dashboard.rb') }
    SCRIPT
    output, errors, status = Open3.capture3(RbConfig.ruby, '-e', script)
    expect(status.success?).to be(true), "#{errors}\n#{output}"
  end
end
