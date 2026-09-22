require 'spec_helper'
require 'open3'
require 'rails_job_context-good_job'

RSpec.describe 'GoodJob dashboard in a booted Rails application' do
  BOOT_SCRIPT = <<~'RUBY'.freeze
    require 'rails'
    require 'action_controller/railtie'
    require 'active_job/railtie'
    require 'rails_job_context-good_job'
    require 'tmpdir'
    require 'fileutils'
    require 'json'

    if ENV['GOOD_JOB_VERSION']
      GoodJob.send(:remove_const, :VERSION)
      GoodJob.const_set(:VERSION, ENV['GOOD_JOB_VERSION'])
    end

    Dir.mktmpdir('job-context-rails-') do |root|
      if ENV['HOST_OVERRIDE'] == 'true'
        FileUtils.mkdir_p(File.join(root, 'app/views/good_job/jobs'))
        File.write(File.join(root, 'app/views/good_job/_custom_job_details.html.erb'), 'Host details')
        File.write(File.join(root, 'app/views/good_job/jobs/_table.erb'), 'Host table')
      end
      app = Class.new(Rails::Application) do
        config.eager_load = false
        config.global_id.app = 'job-context-spec'
        config.secret_key_base = 'test' * 32
        config.logger = Logger.new(File::NULL)
        config.hosts.clear
        config.root = root
        initializer 'test.context_options' do
          JobContext::Dashboard.config.details = ENV['DETAILS'] == 'true'
          JobContext::Dashboard.config.table = ENV['TABLE'] == 'true'
        end
      end
      app.initialize!
      app.routes.draw { mount GoodJob::Engine => '/good_job' }
      # Exercising to_prepare twice catches duplicated paths across reloads.
      app.reloader.prepare!
      app.reloader.prepare!
      controller = GoodJob::ApplicationController.new
      lookup = controller.lookup_context
      details = lookup.find_template('good_job/custom_job_details', [], true)
      table = lookup.find_template('good_job/jobs/table', [], true)
      html = controller.render_to_string(partial: 'good_job/custom_job_details', locals: { job: Struct.new(:serialized_params).new({}) }, layout: false)
      puts JSON.generate(details: details.identifier, table: table.identifier,
        html: html, paths: controller.view_paths.map(&:to_s), root: root,
        common: JobContext::Dashboard.common_view_path,
        details_path: JobContext::Dashboard.details_view_path,
        table_path: JobContext::Dashboard.table_view_path,
        good_job_views: GoodJob::Engine.root.join('app/views').to_s,
        good_job_version: GoodJob::VERSION)
    end
  RUBY

  def run_boot(details:, table:, host_override: false, good_job_version: nil)
    environment = { 'DETAILS' => details.to_s, 'TABLE' => table.to_s, 'HOST_OVERRIDE' => host_override.to_s }
    environment['GOOD_JOB_VERSION'] = good_job_version if good_job_version
    Open3.capture3(
      environment,
      RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), '-e', BOOT_SCRIPT
    )
  end

  def boot(details:, table:, host_override: false, good_job_version: nil)
    output, errors, status = run_boot(details: details, table: table, host_override: host_override,
                                      good_job_version: good_job_version)
    expect(status.success?).to be(true), "#{errors}\n#{output}"
    JSON.parse(output.lines.last)
  end

  table_options = JobContext::Dashboard.table_supported? ? [false, true] : [false]

  [false, true].product(table_options).each do |details, table|
    it "uses details=#{details} and table=#{table} after real Rails boot and preparation" do
      result = boot(details: details, table: table)
      expect(result['good_job_version']).to eq(GoodJob::VERSION)
      if details
        expect(result['details']).to start_with(result['details_path'])
        expect(result['html']).to include('Unknown origin')
      else
        expect(result['details']).to start_with(result['good_job_views'])
        expect(result['html']).not_to include('Unknown origin')
      end
      if table
        expect(result['table']).to start_with(result['table_path'])
      else
        expect(result['table']).to start_with(result['good_job_views'])
      end
      expect(result['paths'].count(result['common'])).to eq(1)
      expect(result['paths'].count(result['details_path'])).to eq(details ? 1 : 0)
      expect(result['paths'].count(result['table_path'])).to eq(table ? 1 : 0)
    end
  end

  it 'preserves application template overrides ahead of the gem' do
    result = boot(details: true, table: JobContext::Dashboard.table_supported?, host_override: true)
    expect(result['details']).to start_with(result['root'])
    expect(result['html']).to eq('Host details')
  end

  it 'selects the table template of the loaded GoodJob series', if: JobContext::Dashboard.table_supported? do
    result = boot(details: true, table: true)

    expect(File.basename(result['table_path'])).to eq(expected_table_series)
    expect(result['table']).to eq(File.join(result['table_path'], 'good_job/jobs/_table.erb'))
  end

  # Each series template calls helpers the neighbouring series does not define,
  # so a real boot has to land on the directory that matches the loaded release.
  %w[3.99.1 4.0.0 4.12.1 4.13.0 4.13.1 4.16.0 4.17.0 4.18.0 4.19.2].each do |version|
    it "selects #{expected_table_series(version)} after a real boot on GoodJob #{version}" do
      result = boot(details: true, table: true, good_job_version: version)

      expect(File.basename(result['table_path'])).to eq(expected_table_series(version))
      expect(result['table']).to eq(File.join(result['table_path'], 'good_job/jobs/_table.erb'))
    end
  end

  # The series ranges are contiguous from 3.99 to 5, so only a release outside
  # that union reaches the error.
  ['3.98.0', '5.0.0'].each do |version|
    it "names the supported GoodJob range when the table override cannot match #{version}" do
      _output, errors, status = run_boot(details: true, table: true, good_job_version: version)

      expect(status.success?).to be(false)
      expect(errors).to include('JobContext::Error')
      expect(errors).to include('Dashboard.config.table')
      expect(errors).to include(version)
      expect(errors).to include('>= 3.99, < 4 (v3)', '>= 4.0, < 4.13.1 (v4_0)', '>= 4.13.1, < 4.17 (v4_13)',
                                '>= 4.17, < 4.18 (v4_17)', '>= 4.18, < 5 (v4_18)')
    end
  end
end
