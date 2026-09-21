# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "active_job"
require "active_job/enqueue_after_transaction_commit"
require "rails_job_context"
require "global_id"
require "pg"
require "securerandom"
require "uri"

ActiveJob::Base.include ActiveJob::EnqueueAfterTransactionCommit
GlobalID.app = "job-context-spec"

# Active Job 8.1 moved the enqueue callbacks behind the transaction deferral, so
# they run when the job reaches the adapter instead of when perform_later runs.
DEFERRED_ENQUEUE_CALLBACKS = ActiveJob::Base.private_method_defined?(:_raw_enqueue)
PENDING_CALLBACK_ARGUMENTS = DEFERRED_ENQUEUE_CALLBACKS ? [] : [[42]]

RSpec.describe "JobContext with Active Record transactions" do
  class TestCurrent < ActiveSupport::CurrentAttributes
    attribute :user, :label, :metadata
    attribute :correlation_stack, default: []
  end

  # Rails 7.2 added AbstractAdapter and asks every adapter for
  # enqueue_after_transaction_commit?. Inherit it where it exists, and supply the
  # one required method where it does not.
  RecordingAdapterBase = if defined?(ActiveJob::QueueAdapters::AbstractAdapter)
    ActiveJob::QueueAdapters::AbstractAdapter
  else
    Class.new do
      def enqueue_after_transaction_commit? = false
    end
  end

  class RecordingAdapter < RecordingAdapterBase
    attr_reader :enqueued

    def initialize
      super
      @enqueued = []
    end

    def enqueue(job)
      @enqueued << job.serialize
    end

    def enqueue_at(job, _timestamp)
      enqueue(job)
    end
  end

  class ReportJob < ActiveJob::Base
    include JobContext::Job

    self.enqueue_after_transaction_commit = true
    queue_as :reports

    class_attribute :callback_arguments, default: []
    class_attribute :performed_values, default: []
    after_enqueue { |job| ReportJob.callback_arguments += [job.arguments] }

    def perform(*arguments)
      ReportJob.performed_values += [[TestCurrent.user, arguments]]
    end
  end

  class User < ActiveRecord::Base
    include GlobalID::Identification
  end

  before(:context) do
    @database_created = false
    @scratch_connected = false
    admin_url = ENV.fetch("JOB_CONTEXT_PG_URL", "postgres:///postgres")
    @database_name = "job_context_spec_#{Process.pid}_#{SecureRandom.hex(6)}"
    @admin_connection = PG.connect(admin_url)
    @admin_connection.exec("CREATE DATABASE #{@database_name}")
    @database_created = true

    admin_uri = URI.parse(admin_url)
    admin_uri.path = "/#{@database_name}"
    ActiveRecord::Base.establish_connection(admin_uri.to_s)
    @scratch_connected = true

    ActiveRecord::Schema.define do
      create_table :users, force: true do |table|
        table.string :name, null: false
      end
    end
  end

  after(:context) do
    begin
      if @scratch_connected
        ActiveRecord::Base.connection_pool.disconnect!
        ActiveRecord::Base.remove_connection
      end
    ensure
      begin
        @admin_connection.exec("DROP DATABASE #{@database_name}") if @database_created
      ensure
        @admin_connection&.close
      end
    end
  end

  before do
    JobContext.configure do |config|
      config.current_attributes = TestCurrent
      config.attributes = :all
      config.except = []
    end
    TestCurrent.reset
    ReportJob.callback_arguments = []
    ReportJob.performed_values = []
    @adapter = RecordingAdapter.new
    @previous_queue_adapter = ReportJob.queue_adapter
    ReportJob.queue_adapter = @adapter
  end

  after do
    TestCurrent.reset
    ReportJob.callback_arguments = []
    ReportJob.performed_values = []
    ReportJob.queue_adapter = @previous_queue_adapter
  end

  it "serializes the context after a real transaction commits" do
    ActiveRecord::Base.transaction do
      TestCurrent.set(user: "alice") { ReportJob.perform_later(42) }
      expect(TestCurrent.user).to be_nil
      expect(@adapter.enqueued).to be_empty
      expect(ReportJob.callback_arguments).to eq(PENDING_CALLBACK_ARGUMENTS)
    end

    expect(@adapter.enqueued.size).to eq(1)
    expect(context_user(@adapter.enqueued.first)).to eq("alice")
    expect(ReportJob.callback_arguments).to eq([[42]])
  end

  it "does not enqueue jobs when the outer transaction rolls back" do
    expect do
      ActiveRecord::Base.transaction do
        TestCurrent.set(user: "alice") { ReportJob.perform_later(42) }
        raise ActiveRecord::Rollback
      end
    end.not_to change { @adapter.enqueued.size }

    expect(ReportJob.callback_arguments).to eq(PENDING_CALLBACK_ARGUMENTS)
  end

  it "waits for the outer transaction when an inner transaction commits" do
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction(requires_new: true) do
        TestCurrent.set(user: "alice") { ReportJob.perform_later(42) }
        expect(@adapter.enqueued).to be_empty
      end

      expect(@adapter.enqueued).to be_empty
    end

    expect(@adapter.enqueued.size).to eq(1)
    expect(context_user(@adapter.enqueued.first)).to eq("alice")
  end

  it "drops a job rolled back in an inner transaction" do
    ActiveRecord::Base.transaction do
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          TestCurrent.set(user: "alice") { ReportJob.perform_later(42) }
          raise ActiveRecord::Rollback
        end
      end.not_to change { @adapter.enqueued.size }
    end

    expect(@adapter.enqueued).to be_empty
    expect(ReportJob.callback_arguments).to eq(PENDING_CALLBACK_ARGUMENTS)
  end

  it "captures the enqueue-time context when Current changes before commit" do
    ActiveRecord::Base.transaction do
      TestCurrent.set(user: "alice") { ReportJob.perform_later(42) }
      TestCurrent.user = "bob"
      expect(@adapter.enqueued).to be_empty
    end

    expect(context_user(@adapter.enqueued.first)).to eq("alice")
  end

  it "captures mutable Current values before they are changed before commit" do
    ActiveRecord::Base.transaction do
      TestCurrent.set(user: "alice", label: +"before", metadata: { "team" => "blue" }) do
        ReportJob.perform_later(42)
        TestCurrent.label.replace("after")
        TestCurrent.metadata["team"] = "red"
      end
    end

    context = ActiveJob::Arguments.deserialize(
      @adapter.enqueued.first.fetch("job_context").fetch("attributes")
    ).first
    expect(context).to include(user: "alice", label: "before", metadata: { "team" => "blue" })
  end

  it "round trips a persisted Current record through GlobalID" do
    alice = User.create!(name: "Alice")

    ActiveRecord::Base.transaction do
      TestCurrent.set(user: alice) { ReportJob.perform_later(42) }
    end

    expect(TestCurrent.user).to be_nil
    payload = @adapter.enqueued.first
    expect(context_user(payload)).to eq(alice)

    ReportJob.deserialize(payload).perform_now

    expect(ReportJob.performed_values).to eq([[alice, [42]]])
    expect(TestCurrent.user).to be_nil
  end

  private

  def context_user(payload)
    attributes = payload.fetch("job_context").fetch("attributes")
    ActiveJob::Arguments.deserialize(attributes).first.fetch(:user)
  end

end
