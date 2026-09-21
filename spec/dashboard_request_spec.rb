require 'spec_helper'
require 'open3'
require 'rails_job_context/good_job'

RSpec.describe 'GoodJob jobs index rendered by a booted Rails application' do
  REQUEST_SCRIPT = <<~'RUBY'.freeze
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'active_job/railtie'
    require 'rails_job_context/good_job'
    require 'erb'
    require 'fileutils'
    require 'json'
    require 'pg'
    require 'rack'
    require 'securerandom'
    require 'tmpdir'
    require 'uri'
    require 'yaml'

    class Current < ActiveSupport::CurrentAttributes
      attribute :controller, :action, :correlation_stack
    end

    def fetch(app, path)
      status, _headers, body = app.call(Rack::MockRequest.env_for("http://example.com#{path}"))
      collected = +''
      body.each { |chunk| collected << chunk }
      [status, collected]
    end

    admin_url = ENV.fetch('JOB_CONTEXT_PG_URL', 'postgres:///postgres')
    database_name = "job_context_dashboard_#{Process.pid}_#{SecureRandom.hex(6)}"
    admin_connection = PG.connect(admin_url)
    admin_connection.exec("CREATE DATABASE #{database_name}")
    database_url = URI.parse(admin_url).tap { |uri| uri.path = "/#{database_name}" }.to_s
    connected = false

    begin
      Dir.mktmpdir('job-context-dashboard-') do |root|
        FileUtils.mkdir_p(File.join(root, 'config'))
        File.write(File.join(root, 'config/database.yml'),
                   { 'development' => { 'url' => database_url }, 'test' => { 'url' => database_url } }.to_yaml)

        app = Class.new(Rails::Application) do
          config.eager_load = false
          config.global_id.app = 'job-context-spec'
          config.secret_key_base = 'test' * 32
          config.logger = Logger.new(File::NULL)
          config.hosts.clear
          config.root = root
          config.active_job.queue_adapter = :good_job
          config.good_job.execution_mode = :external
          config.good_job.preserve_job_records = true
          initializer 'test.context_options' do
            JobContext.configure do |context|
              context.current_attributes = -> { Current }
              context.attributes = %i[controller action]
            end
            JobContext.config.good_job.details = true
            JobContext.config.good_job.table = true
          end
        end
        app.initialize!
        connected = true
        app.routes.draw { mount GoodJob::Engine => '/good_job' }

        migrations = GoodJob::Engine.root.join('lib/generators/good_job/templates/install/migrations/*.erb')
        Dir[migrations].sort.each do |file|
          source = ERB.new(File.read(file))
                      .result_with_hash(migration_version: "[#{ActiveRecord::Migration.current_version}]")
          Object.class_eval(source, file)
        end
        ActiveRecord::Migration.suppress_messages { CreateGoodJobs.new.migrate(:up) }

        Object.const_set(:ChildJob, Class.new(ActiveJob::Base) do
          include JobContext::Job
          def perform; end
        end)
        Object.const_set(:ParentJob, Class.new(ActiveJob::Base) do
          include JobContext::Job
          def perform = ChildJob.perform_later
        end)

        Current.set(controller: 'orders', action: 'create') { ParentJob.perform_later }
        # The first pass runs ParentJob, which enqueues ChildJob for the second.
        GoodJob.perform_inline
        GoodJob.perform_inline

        parent = GoodJob::Job.where(job_class: 'ParentJob').first
        child = GoodJob::Job.where(job_class: 'ChildJob').first
        index_status, index_body = fetch(app, '/good_job/jobs')
        child_status, child_body = fetch(app, '/good_job/jobs?job_class=ChildJob')

        puts JSON.generate(
          good_job_version: GoodJob::VERSION,
          table_path: JobContext::Dashboard.table_view_path,
          table_series: File.basename(JobContext::Dashboard.table_view_path),
          parent_id: parent&.id,
          child_id: child&.id,
          index_status: index_status,
          child_status: child_status,
          index_direct_cause_header: index_body.include?('>Direct Cause<'),
          index_root_cause_header: index_body.include?('>Root Cause<'),
          index_rows: index_body.scan('>Direct Cause<').size,
          child_rows: child_body.scan('>Direct Cause<').size,
          child_shows_child_id: child_body.include?(child.id),
          child_links_parent: child_body.include?("/good_job/jobs/#{parent&.id}"),
          child_names_parent: child_body.include?('ParentJob'),
          index_shows_origin: index_body.include?('orders#create')
        )
      end
    ensure
      if connected
        ActiveRecord::Base.connection_pool.disconnect!
        ActiveRecord::Base.remove_connection
      end
      admin_connection.exec("DROP DATABASE IF EXISTS #{database_name}")
      admin_connection.close
    end
  RUBY

  def request_jobs_index
    output, errors, status = Open3.capture3(
      RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), '-e', REQUEST_SCRIPT
    )
    expect(status.success?).to be(true), "#{errors}\n#{output}"
    JSON.parse(output.lines.last)
  end

  it "adds both cause columns and names the parent as the direct cause of the child on #{GoodJob::VERSION}",
     if: JobContext::Dashboard.table_supported? do
    result = request_jobs_index

    expect(result['good_job_version']).to eq(GoodJob::VERSION)
    expect(result['table_path']).to eq(JobContext::Dashboard.table_view_path)
    expect(result['table_series']).to eq(expected_table_series)
    expect(result['index_status']).to eq(200)
    expect(result['child_status']).to eq(200)
    expect(result['index_direct_cause_header']).to be(true)
    expect(result['index_root_cause_header']).to be(true)
    # One header plus one small-screen label for each of the two jobs.
    expect(result['index_rows']).to eq(3)
    expect(result['child_rows']).to eq(2)
    expect(result['child_shows_child_id']).to be(true)
    expect(result['child_links_parent']).to be(true)
    expect(result['child_names_parent']).to be(true)
    expect(result['index_shows_origin']).to be(true)
  end
end
