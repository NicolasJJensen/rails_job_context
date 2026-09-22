require 'spec_helper'
require 'open3'
require 'rails_job_context-good_job'

RSpec.describe 'Context details in Rails' do
  SCRIPT = <<~'SCRIPT'.freeze
    require 'rails'
    require 'action_controller/railtie'
    require 'active_job/railtie'
    require 'rails_job_context-good_job'
    require 'tmpdir'
    require 'fileutils'
    require 'json'
    Dir.mktmpdir do |root|
      if ENV['HOST_OVERRIDE'] == 'true'
        FileUtils.mkdir_p(File.join(root, 'app/views/good_job'))
        File.write(File.join(root, 'app/views/good_job/_custom_job_details.html.erb'), 'Host details')
      end
      app = Class.new(Rails::Application) do
        config.root = root
        config.eager_load = false
        config.global_id.app = 'job-context-spec'
        config.secret_key_base = 'test' * 32
        config.logger = Logger.new(File::NULL)
        initializer 'context.options' do
          JobContext::Dashboard.config.details = ENV['DETAILS'] == 'true'
        end
      end
      app.initialize!
      2.times { app.reloader.prepare! }
      job = Struct.new(:serialized_params).new({ 'job_context' => { 'version' => 1,
        'contexts' => { 'TenantCurrent' => [{ 'account_id' => 42 }] } } })
      controller = GoodJob::ApplicationController.new
      html = controller.render_to_string(partial: 'good_job/custom_job_details', locals: { job: job }, layout: false)
      puts JSON.generate(html: html, paths: controller.view_paths.map(&:to_s),
        common: JobContext::Dashboard.common_view_path, details: JobContext::Dashboard.details_view_path,
        table: controller.lookup_context.find_template('good_job/jobs/table', [], true).identifier,
        original: GoodJob::Engine.root.join('app/views').to_s)
    end
  SCRIPT

  def boot(details: true, host_override: false)
    output, errors, status = Open3.capture3(
      { 'DETAILS' => details.to_s, 'HOST_OVERRIDE' => host_override.to_s }, RbConfig.ruby, '-e', SCRIPT
    )
    expect(status.success?).to be(true), "#{errors}\n#{output}"
    JSON.parse(output.lines.last)
  end

  it 'shows context details while retaining the original GoodJob table' do
    result = boot
    expect(result['html']).to include('TenantCurrent', 'account_id', '42')
    expect(result['table']).to start_with(result['original'])
    expect(result['paths'].count(result['common'])).to eq(1)
    expect(result['paths'].count(result['details'])).to eq(1)
  end

  it 'supports disabling details' do
    result = boot(details: false)
    expect(result['html']).not_to include('Context attributes')
    expect(result['paths']).not_to include(result['details'])
  end

  it 'preserves application overrides' do
    expect(boot(host_override: true)['html']).to eq('Host details')
  end
end
