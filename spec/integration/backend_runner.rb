require 'rails'
require 'active_record/railtie'
require 'active_job/railtie'
require 'rails_job_context'
require 'json'
require 'fileutils'
require 'socket'
require 'timeout'
require 'yaml'

backend, directory = ARGV
redis_pid = nil

begin
  if %w[sidekiq resque].include?(backend)
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    redis_pid = Process.spawn('redis-server', '--bind', '127.0.0.1', '--port', port.to_s,
                              '--save', '', '--appendonly', 'no', '--dir', directory,
                              out: File.join(directory, 'redis.log'), err: [:child, :out])
    Timeout.timeout(10) do
      loop do
        begin
          TCPSocket.new('127.0.0.1', port).close
          break
        rescue Errno::ECONNREFUSED
          sleep 0.05
        end
      end
    end
    ENV['REDIS_URL'] = "redis://127.0.0.1:#{port}/0"
  end

  require backend == 'delayed_job' ? 'delayed_job_active_record' : backend
  app = Class.new(Rails::Application) do
    config.root = directory
    config.eager_load = false
    config.global_id.app = 'job-context-integration'
    config.secret_key_base = 'integration-test' * 8
    config.logger = Logger.new(File::NULL)
    config.active_job.queue_adapter = backend.to_sym
  end
  FileUtils.mkdir_p(File.join(directory, 'config'))
  File.write(File.join(directory, 'config/database.yml'), {
    'test' => { 'adapter' => 'sqlite3', 'database' => File.join(directory, 'jobs.sqlite3') }
  }.to_yaml)
  app.initialize!
  ActiveJob::Base.logger = Logger.new(File::NULL)

  case backend
  when 'solid_queue'
    SolidQueue.connects_to = nil
    load Gem.loaded_specs.fetch('solid_queue').full_gem_path + '/lib/generators/solid_queue/install/templates/db/queue_schema.rb'
    worker = SolidQueue::Process.register(kind: 'Worker', name: 'integration', pid: Process.pid, hostname: 'localhost')
    drain_one = lambda do
      SolidQueue::ScheduledExecution.dispatch_next_batch(100)
      execution = SolidQueue::ReadyExecution.claim(['default'], 1, worker.id).first
      execution&.perform
      !execution.nil?
    end
  when 'sidekiq'
    require 'sidekiq/processor'
    require 'sidekiq/scheduled'
    Sidekiq.logger.level = Logger::FATAL
    capsule = Sidekiq.default_configuration.default_capsule
    capsule.queues = ['default']
    processor = Sidekiq::Processor.new(capsule)
    drain_one = lambda do
      Sidekiq::Scheduled::Enq.new(capsule).enqueue_jobs
      payload = Sidekiq.redis { |connection| connection.rpop('queue:default') }
      if payload
        processor.send(:process, Sidekiq::BasicFetch::UnitOfWork.new('queue:default', payload, capsule))
      end
      !payload.nil?
    end
  when 'resque'
    require 'resque-scheduler'
    Resque.redis = ENV.fetch('REDIS_URL')
    drain_one = lambda do
      Resque::Scheduler.handle_delayed_items
      job = Resque.reserve('default')
      job&.perform
      !job.nil?
    end
  when 'delayed_job'
    ActiveRecord::Schema.define do
      create_table :delayed_jobs do |table|
        table.integer :priority, default: 0, null: false
        table.integer :attempts, default: 0, null: false
        table.text :handler, null: false
        table.text :last_error
        table.datetime :run_at, :locked_at, :failed_at
        table.string :locked_by, :queue
        table.timestamps null: true
      end
    end
    worker = Delayed::Worker.new(quiet: true)
    drain_one = -> { worker.work_off(1).sum.positive? }
  end

  class IntegrationTenant < ActiveSupport::CurrentAttributes
    attribute :account_id, :metadata
  end
  class IntegrationUser < ActiveSupport::CurrentAttributes
    attribute :user_id
  end
  JobContext.configure do |config|
    config.contexts = [
      { current_attributes: -> { IntegrationTenant }, attributes: %i[account_id metadata] },
      { current_attributes: -> { IntegrationUser }, attributes: [:user_id] }
    ]
  end
  class IntegrationRetry < StandardError; end
  class IntegrationDiscard < StandardError; end
  class IntegrationJob < ActiveJob::Base
    include JobContext::Job
    self.enqueue_after_transaction_commit = true
    class_attribute :observations, default: []
    retry_on IntegrationRetry, wait: 0, attempts: 2
    discard_on IntegrationDiscard

    def perform(mode)
      self.class.observations += [{ mode: mode, account_id: IntegrationTenant.account_id,
        user_id: IntegrationUser.user_id, metadata: IntegrationTenant.metadata.deep_dup }]
      IntegrationJob.perform_later('child') if mode == 'parent'
      IntegrationTenant.metadata['labels'] << 'mutated in worker'
      raise IntegrationRetry if mode == 'retry' && executions == 1
      raise IntegrationDiscard if mode == 'discard'
    end
  end

  IntegrationTenant.account_id = 42
  IntegrationTenant.metadata = { 'labels' => ['original'] }
  IntegrationUser.user_id = 7
  %w[normal parent retry discard].each { |mode| IntegrationJob.perform_later(mode) }
  ActiveJob.perform_all_later(IntegrationJob.new('bulk'), IntegrationJob.new('bulk'))
  IntegrationTenant.metadata['labels'] << 'mutated after initial enqueue'
  IntegrationTenant.metadata = { 'labels' => ['original'] }
  IntegrationJob.set(wait_until: 1.second.ago).perform_later('scheduled')
  ActiveRecord::Base.transaction do
    IntegrationJob.perform_later('transaction')
    [IntegrationTenant, IntegrationUser].each(&:reset)
  end
  IntegrationTenant.account_id = 42
  IntegrationTenant.metadata = { 'labels' => ['original'] }
  IntegrationUser.user_id = 7
  ActiveRecord::Base.transaction do
    IntegrationJob.perform_later('rollback')
    raise ActiveRecord::Rollback
  end
  abort 'Adapter executed jobs before the worker started' unless IntegrationJob.observations.empty?
  IntegrationTenant.metadata['labels'] << 'mutated after enqueue'
  [IntegrationTenant, IntegrationUser].each(&:reset)

  restored = true
  Timeout.timeout(15) do
    while drain_one.call
      restored &&= IntegrationTenant.account_id.nil? && IntegrationTenant.metadata.nil? && IntegrationUser.user_id.nil?
    end
  end
  puts JSON.generate(observations: IntegrationJob.observations, restored: restored)
ensure
  ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  if redis_pid
    Process.kill('TERM', redis_pid)
    Process.wait(redis_pid)
  end
end
