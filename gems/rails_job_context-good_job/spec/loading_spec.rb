require 'spec_helper'
require 'open3'

RSpec.describe 'Companion loading' do
  it 'loads its engine through Bundler without a require override' do
    script = <<~'SCRIPT'
      require 'bundler'
      Bundler.require
      abort 'Missing companion engine' unless defined?(JobContext::Engine)
      abort 'Missing core' unless defined?(JobContext::Job)
      abort 'Details disabled' unless JobContext::Dashboard.config.details
    SCRIPT
    output, errors, status = Open3.capture3(RbConfig.ruby, '-e', script)
    expect(status.success?).to be(true), "#{errors}\n#{output}"
  end
end
