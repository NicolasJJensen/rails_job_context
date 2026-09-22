require 'spec_helper'

class ContextCurrent < ActiveSupport::CurrentAttributes
  attribute :user, :controller, :action, :request, :data, :correlation_stack
end

class TenantCurrent < ActiveSupport::CurrentAttributes
  attribute :account
end

# Rails 7.2 added AbstractAdapter and asks every adapter for
# enqueue_after_transaction_commit?. Inherit it where it exists, and supply the
# one required method where it does not.
ContextRecordingAdapterBase = if defined?(ActiveJob::QueueAdapters::AbstractAdapter)
  ActiveJob::QueueAdapters::AbstractAdapter
else
  Class.new do
    def enqueue_after_transaction_commit? = false
  end
end

class ContextRecordingAdapter < ContextRecordingAdapterBase
  attr_reader :payloads
  def initialize
    super
    @payloads = []
  end
  def enqueue(job)
    payloads << job.serialize
  end
  def enqueue_at(job, _time)
    enqueue(job)
  end
end

class ContextTestJob < ActiveJob::Base
  include JobContext::Job
  class_attribute :observations, default: []
  def perform(*args, **kwargs)
    self.class.observations << [args, kwargs, ContextCurrent.attributes.deep_dup, TenantCurrent.attributes.deep_dup]
  end
end

class ContextChildJob < ContextTestJob; end
class ContextParentJob < ContextTestJob
  def perform
    ContextChildJob.perform_later('child')
  end
end
class ContextFailureJob < ContextTestJob
  def perform
    raise 'failed'
  end
end
class ContextRetryJob < ContextTestJob
  retry_on RuntimeError, wait: 1, attempts: 2
  def perform
    raise 'retry' if executions == 1
    super
  end
end

RSpec.describe JobContext::Job do
  let(:adapter) { ContextRecordingAdapter.new }
  before do
    JobContext.configure do |config|
      config.contexts = {
        request: { current_attributes: -> { ContextCurrent }, attributes: :all, except: [:request] },
        tenant: { current_attributes: -> { TenantCurrent }, attributes: :all, except: [] }
      }
      config.correlation_context = :request
    end
    ContextTestJob.queue_adapter = adapter
    ContextTestJob.observations = []
  end

  def round_trip(job)
    ActiveJob::Base.deserialize(JSON.parse(JSON.generate(job.serialize)))
  end

  it 'keeps positional and keyword arguments intact through serialization and execution' do
    ContextCurrent.user = 'alice'
    job = ContextTestJob.perform_later(42, { 'plain' => true }, flag: true)
    expect(job.arguments).to eq([42, { 'plain' => true }, { flag: true }])
    ContextCurrent.user = 'bob'
    round_trip(job).perform_now
    args, kwargs, current = ContextTestJob.observations.last
    expect(args).to eq([42, { 'plain' => true }])
    expect(kwargs).to eq(flag: true)
    expect(current[:user]).to eq('alice')
    expect(current[:correlation_stack]).to eq([job.job_id])
    expect(ContextCurrent.user).to eq('bob')
  end

  it 'captures and restores each named Current context' do
    ContextCurrent.user = 'alice'
    TenantCurrent.account = 'acme'
    job = ContextTestJob.perform_later
    payload = job.serialize.fetch('job_context')

    expect(ActiveJob::Arguments.deserialize(payload.fetch('contexts').fetch('tenant')).first).to eq(account: 'acme')
    TenantCurrent.account = 'other'
    round_trip(job).perform_now
    expect(ContextTestJob.observations.last[3][:account]).to eq('acme')
    expect(TenantCurrent.account).to eq('other')
  end

  it 'rejects a payload with a missing configured context' do
    ContextCurrent.user = 'alice'
    payload = ContextTestJob.new.serialize
    payload['job_context']['contexts'].delete('tenant')

    expect { ActiveJob::Base.deserialize(payload).perform_now }
      .to raise_error(ArgumentError, /Missing configured context payload: tenant/)
  end

  it 'resolves each context callable once per capture' do
    calls = 0
    JobContext.config.contexts['request'].current_attributes = -> { calls += 1; ContextCurrent }
    JobContext.config.contexts['tenant'].current_attributes = -> { calls += 1; TenantCurrent }

    ContextTestJob.new.serialize
    expect(calls).to eq(2)
  end

  it 'keeps a same-named attribute in a non-owner context' do
    stub_const('TenantCurrent', Class.new(ActiveSupport::CurrentAttributes) do
      attribute :correlation_stack, :account
    end)
    JobContext.config.contexts['tenant'].current_attributes = TenantCurrent
    TenantCurrent.correlation_stack = ['tenant-stack']

    payload = ContextTestJob.new.serialize.fetch('job_context')
    values = ActiveJob::Arguments.deserialize(payload.fetch('contexts').fetch('tenant')).first
    expect(values).to include(correlation_stack: ['tenant-stack'])
  end

  it 'preserves custom serialization supplied by a job subclass' do
    stub_const('CustomSerializedContextJob', Class.new(ContextTestJob) do
      attr_accessor :extra
      def serialize
        super.merge('custom_extra' => extra)
      end
      def deserialize(data)
        super
        self.extra = data['custom_extra']
      end
    end)
    job = CustomSerializedContextJob.new(42)
    job.extra = 'kept'
    ContextCurrent.user = 'alice'
    restored = round_trip(job)
    expect(restored.extra).to eq('kept')
    expect(restored.serialize['job_context']).to eq(job.serialize['job_context'])
  end

  it 'keeps an explicit empty options hash as an argument for new jobs' do
    job = ContextTestJob.new(42, {})
    round_trip(job).perform_now
    expect(ContextTestJob.observations.last[0]).to eq([42, {}])
  end

  it 'wraps perform_now without enqueueing or leaking a correlation stack' do
    ContextCurrent.user = 'alice'
    ContextTestJob.perform_now(42)
    expect(adapter.payloads).to be_empty
    expect(ContextTestJob.observations.last[2][:user]).to eq('alice')
    expect(ContextTestJob.observations.last[2][:correlation_stack].size).to eq(1)
    expect(ContextCurrent.correlation_stack).to be_nil
  end

  it 'rejects an unsupported stored envelope version' do
    data = ContextTestJob.new.serialize
    data['job_context']['version'] = 99
    expect { ActiveJob::Base.deserialize(data) }.to raise_error(ArgumentError, /Unsupported/)
  end

  it 'supports an explicit list and excludes unselected values' do
    JobContext.config.contexts['request'].attributes = [:user]
    ContextCurrent.user = 'alice'
    ContextCurrent.request = Object.new
    data = ContextTestJob.new.serialize.fetch('job_context')
    expect(ActiveJob::Arguments.deserialize(data['contexts']['request']).first).to eq(user: 'alice')
  end

  it 'includes declared but unset attributes and newly declared attributes with :all' do
    stub_const('AdditionalCurrent', Class.new(ActiveSupport::CurrentAttributes) do
      attribute :correlation_stack, :one
    end)
    JobContext.config.contexts = {
      request: { current_attributes: AdditionalCurrent, attributes: :all, except: [] },
      tenant: { current_attributes: TenantCurrent, attributes: :all, except: [] }
    }
    AdditionalCurrent.attribute :later
    AdditionalCurrent.later = 'new'
    values = ActiveJob::Arguments.deserialize(ContextTestJob.new.serialize['job_context']['contexts']['request']).first
    expect(values).to eq(one: nil, later: 'new')
  end

  it 'names unsupported attributes in serialization errors' do
    JobContext.config.contexts['request'].except = []
    ContextCurrent.request = Object.new
    expect { ContextTestJob.perform_later }.to raise_error(ActiveJob::SerializationError, /Context request.request/)
    expect(adapter.payloads).to be_empty
  end

  it 'rejects unknown explicitly configured attributes' do
    JobContext.config.contexts['request'].attributes = [:misspelled]
    expect { ContextTestJob.new.serialize }.to raise_error(ArgumentError, /misspelled/)
  end

  it 'resolves a reloaded Current class when restoring a saved job' do
    ContextCurrent.user = 'alice'
    job = ContextTestJob.new
    payload = job.serialize
    stub_const('ContextCurrent', Class.new(ActiveSupport::CurrentAttributes) do
      attribute :user, :request, :controller, :action, :data, :correlation_stack
    end)
    ContextCurrent.user = 'bob'
    expect(ContextCurrent).to receive(:set).and_call_original

    ActiveJob::Base.deserialize(payload).perform_now

    expect(ContextTestJob.observations.last[2][:user]).to eq('alice')
    expect(ContextCurrent.user).to eq('bob')
  end

  it 'captures changes made by subclass enqueue callbacks' do
    stub_const('CallbackContextJob', Class.new(ContextTestJob) do
      before_enqueue { ContextCurrent.action = 'callback' }
      around_enqueue do |_job, block|
        ContextCurrent.set(controller: 'temporary') { block.call }
      end
    end)
    job = CallbackContextJob.perform_later
    values = ActiveJob::Arguments.deserialize(job.serialize['job_context']['contexts']['request']).first
    expect(values).to include(controller: 'temporary', action: 'callback')
    expect(ContextCurrent.controller).to be_nil
  end

  it 'preserves a detached snapshot across repeated serialization' do
    ContextCurrent.data = { 'nested' => ['original'] }
    TenantCurrent.account = { 'name' => 'original' }
    job = ContextTestJob.perform_later
    ContextCurrent.data['nested'].first.replace('changed')
    TenantCurrent.account['name'].replace('changed')
    payload = job.serialize
    payload['job_context']['correlation_stack'].clear
    values = ActiveJob::Arguments.deserialize(job.serialize['job_context']['contexts']['request']).first
    expect(values[:data]).to eq('nested' => ['original'])
    tenant = ActiveJob::Arguments.deserialize(payload['job_context']['contexts']['tenant']).first
    expect(tenant[:account]).to eq('name' => 'original')
    expect(job.serialize['job_context']['correlation_stack']).to eq([job.job_id])
  end

  it 'extends ancestry when a restored parent enqueues a child' do
    ContextCurrent.user = 'alice'
    TenantCurrent.account = 'acme'
    parent = ContextParentJob.perform_later
    ContextCurrent.reset
    round_trip(parent).perform_now
    child = adapter.payloads.last
    expect(child['job_context']['correlation_stack']).to eq([parent.job_id, child['job_id']])
    expect(ActiveJob::Arguments.deserialize(child['job_context']['contexts']['request']).first[:user]).to eq('alice')
    expect(ActiveJob::Arguments.deserialize(child['job_context']['contexts']['tenant']).first[:account]).to eq('acme')
    expect(ContextCurrent.correlation_stack).to be_nil
  end

  it 'restores the caller context when execution raises' do
    ContextCurrent.user = 'alice'
    TenantCurrent.account = 'acme'
    job = ContextFailureJob.perform_later
    ContextCurrent.user = 'bob'
    ContextCurrent.correlation_stack = ['outer']
    TenantCurrent.account = 'other'
    expect { round_trip(job).perform_now }.to raise_error('failed')
    expect(ContextCurrent.user).to eq('bob')
    expect(ContextCurrent.correlation_stack).to eq(['outer'])
    expect(TenantCurrent.account).to eq('other')
  end

  it 'retains the original snapshot and a single job ID on retry' do
    ContextCurrent.user = 'alice'
    TenantCurrent.account = 'acme'
    job = ContextRetryJob.perform_later
    ContextCurrent.user = 'bob'
    round_trip(job).perform_now
    retry_payload = adapter.payloads.last
    expect(retry_payload['job_context']).to eq(adapter.payloads.first['job_context'])
    expect(retry_payload['job_context']['correlation_stack']).to eq([job.job_id])
    expect(ActiveJob::Arguments.deserialize(retry_payload['job_context']['contexts']['tenant']).first[:account]).to eq('acme')
    ActiveJob::Base.deserialize(retry_payload).perform_now
    expect(ContextCurrent.user).to eq('bob')
  end

  it 'supports bulk enqueue through the explicit snapshot wrapper' do
    ContextCurrent.user = 'alice'
    jobs = [ContextTestJob.new(1), ContextTestJob.new(2)]
    JobContext.perform_all_later(jobs)
    expect(adapter.payloads.size).to eq(2)
    expect(adapter.payloads.map { |p| p['job_context']['correlation_stack'] }).to eq(jobs.map { |j| [j.job_id] })
  end

end
