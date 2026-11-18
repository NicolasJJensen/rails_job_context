require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'Active Job backend integration' do
  %w[solid_queue sidekiq resque delayed_job].each do |backend|
    it "propagates context through #{backend} storage and worker execution" do
      Dir.mktmpdir("job-context-#{backend}-") do |directory|
        output, errors, status = Open3.capture3(
          { 'RAILS_ENV' => 'test', 'DATABASE_URL' => nil },
          RbConfig.ruby, File.expand_path('backend_runner.rb', __dir__), backend, directory
        )
        expect(status.success?).to be(true), "#{backend}: #{errors}\n#{output}"
        result = JSON.parse(output.lines.last)
        expect(result.fetch('observations').map { |row| row.fetch('mode') }.sort)
          .to eq(%w[bulk bulk child discard normal parent retry retry scheduled transaction].sort)
        result.fetch('observations').each do |row|
          expect(row.fetch('account_id')).to eq(42)
          expect(row.fetch('user_id')).to eq(7)
          expect(row.fetch('metadata')).to eq('labels' => ['original'])
        end
        expect(result.fetch('restored')).to be(true)
      end
    end
  end
end
