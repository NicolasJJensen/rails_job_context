require 'spec_helper'

class JobContextCurrent < ActiveSupport::CurrentAttributes
  attribute :account_id, :mutable, :controller, :action
end

class JobContextTenantCurrent < ActiveSupport::CurrentAttributes
  attribute :tenant_id
end

class JobContextRecordingAdapter < ActiveJob::QueueAdapters::AsyncAdapter
  attr_reader :payloads

  def initialize
    super
    @payloads = []
  end

  def enqueue(job)
    payloads << job.serialize
  end

  def enqueue_at(job, _timestamp)
    enqueue(job)
  end
end

class JobContextTestJob < ActiveJob::Base
  include JobContext::Job
  class_attribute :observed, default: []

  def perform
    self.class.observed << [JobContextCurrent.attributes.deep_dup, JobContextTenantCurrent.attributes.deep_dup]
  end
end

class JobContextFailureJob < JobContextTestJob
  def perform
    raise 'failed'
  end
end

class JobContextMutatingRetryJob < JobContextTestJob
  retry_on RuntimeError, wait: 0, attempts: 2

  def perform
    JobContextCurrent.mutable['key'] = 'changed'
    raise 'retry' if executions == 1
  end
end

class JobContextCallbackJob < JobContextTestJob
  before_enqueue { JobContextCurrent.action = 'callback' }
  around_enqueue do |_job, block|
    JobContextCurrent.set(controller: 'temporary') { block.call }
  end
end

RSpec.describe JobContext::Job do
  let(:adapter) { JobContextRecordingAdapter.new }

  before do
    JobContext.configure do |config|
      config.contexts = [
        { current_attributes: -> { JobContextCurrent }, attributes: [:account_id, :mutable] },
        { current_attributes: -> { JobContextTenantCurrent }, attributes: [:tenant_id] }
      ]
    end
    JobContextTestJob.queue_adapter = adapter
    JobContextTestJob.observed = []
  end

  def round_trip(job)
    ActiveJob::Base.deserialize(JSON.parse(JSON.generate(job.serialize)))
  end

  it 'serializes named contexts without correlation fields' do
    JobContextCurrent.account_id = 42
    payload = JobContextTestJob.new.serialize.fetch('job_context')
    expect(payload.keys).to eq(['version', 'contexts'])
    expect(payload['contexts'].keys).to eq(['JobContextCurrent', 'JobContextTenantCurrent'])
  end

  it 'restores configured contexts and restores the caller after execution' do
    JobContextCurrent.account_id = 42
    JobContextTenantCurrent.tenant_id = 'acme'
    job = JobContextTestJob.perform_later
    JobContextCurrent.account_id = 7
    JobContextTenantCurrent.tenant_id = 'other'
    round_trip(job).perform_now
    expect(JobContextTestJob.observed.last).to eq([{ account_id: 42, mutable: nil }, { tenant_id: 'acme' }])
    expect(JobContextCurrent.account_id).to eq(7)
    expect(JobContextTenantCurrent.tenant_id).to eq('other')
  end

  it 'restores a saved payload through a reloaded named Current class' do
    JobContextCurrent.account_id = 42
    payload = JobContextTestJob.new.serialize
    stub_const('JobContextCurrent', Class.new(ActiveSupport::CurrentAttributes) do
      attribute :account_id, :mutable, :controller, :action
    end)
    JobContextCurrent.account_id = 7
    reloaded = ActiveJob::Base.deserialize(payload)
    reloaded.perform_now
    expect(JobContextTestJob.observed.last.first[:account_id]).to eq(42)
    expect(JobContextCurrent.account_id).to eq(7)
  end

  it 'captures values changed by enqueue callbacks' do
    JobContext.config.contexts.first[:attributes] = [:account_id, :mutable, :controller, :action]
    job = JobContextCallbackJob.perform_later
    values = ActiveJob::Arguments.deserialize(job.serialize['job_context']['contexts']['JobContextCurrent']).first
    expect(values).to include(controller: 'temporary', action: 'callback')
    expect(JobContextCurrent.controller).to be_nil
  end

  it 'returns saved attributes for a class and captures when needed' do
    JobContextCurrent.account_id = 42
    job = JobContextTestJob.new
    expect(job.job_context_for(JobContextCurrent)).to include(account_id: 42)
    expect(job.job_context_for(JobContextTenantCurrent)).to include(tenant_id: nil)
  end

  it 'detaches values returned by job_context_for' do
    JobContextCurrent.mutable = { 'key' => ['before'] }
    job = JobContextTestJob.new
    returned = job.job_context_for(JobContextCurrent)
    returned[:mutable]['key'][0] = 'changed'
    expect(job.job_context_for(JobContextCurrent)).to eq(mutable: { 'key' => ['before'] }, account_id: nil)
  end

  it 'ignores payload contexts that are not configured' do
    payload = JobContextTestJob.new.serialize
    payload['job_context']['contexts']['OtherCurrent'] = ActiveJob::Arguments.serialize([{ value: 1 }])
    expect { ActiveJob::Base.deserialize(payload).perform_now }.not_to raise_error
  end

  it 'rejects a payload that omits a configured context' do
    payload = JobContextTestJob.new.serialize
    payload['job_context']['contexts'].delete('JobContextTenantCurrent')
    expect { ActiveJob::Base.deserialize(payload).perform_now }
      .to raise_error(ArgumentError, /Missing configured context payload: JobContextTenantCurrent/)
  end

  it 'identifies an unsupported context value by attribute' do
    JobContextCurrent.mutable = Object.new
    expect { JobContextTestJob.new.serialize }
      .to raise_error(ActiveJob::SerializationError, /Context JobContextCurrent.mutable/)
  end

  it 'restores contexts by named key after configuration reordering' do
    JobContextCurrent.account_id = 42
    JobContextTenantCurrent.tenant_id = 'acme'
    job = JobContextTestJob.new
    job.serialize
    JobContext.config.contexts = [
      { current_attributes: -> { JobContextTenantCurrent }, attributes: [:tenant_id] },
      { current_attributes: -> { JobContextCurrent }, attributes: [:account_id, :mutable, :controller, :action] }
    ]
    JobContextCurrent.account_id = 7
    JobContextTenantCurrent.tenant_id = 'other'
    job.perform_now
    expect(JobContextTestJob.observed.last).to include({ account_id: 42, mutable: nil }, { tenant_id: 'acme' })
  end

  it 'resolves reload-safe callables once per operation' do
    calls = 0
    JobContext.config.contexts = [{ current_attributes: -> { calls += 1; JobContextCurrent }, attributes: [] }]
    JobContextTestJob.new.serialize
    expect(calls).to eq(1)
  end

  it 'keeps a detached mutable snapshot across repeated serialization' do
    JobContextCurrent.mutable = { 'key' => ['before'] }
    job = JobContextTestJob.new
    job.serialize
    JobContextCurrent.mutable['key'][0] = 'after'
    values = ActiveJob::Arguments.deserialize(job.serialize['job_context']['contexts']['JobContextCurrent']).first
    expect(values[:mutable]).to eq('key' => ['before'])
  end

  it 'keeps the snapshot when perform mutates Current before retry' do
    JobContextCurrent.mutable = { 'key' => 'before' }
    job = JobContextMutatingRetryJob.perform_later
    round_trip(job).perform_now
    expect(adapter.payloads.last['job_context']).to eq(adapter.payloads.first['job_context'])
    values = ActiveJob::Arguments.deserialize(adapter.payloads.last['job_context']['contexts']['JobContextCurrent']).first
    expect(values[:mutable]).to eq('key' => 'before')
  end

  it 'restores caller values when perform raises' do
    JobContextCurrent.account_id = 42
    job = JobContextFailureJob.perform_later
    JobContextCurrent.account_id = 7
    expect { round_trip(job).perform_now }.to raise_error('failed')
    expect(JobContextCurrent.account_id).to eq(7)
  end

  it 'captures one caller snapshot for bulk enqueue' do
    JobContextCurrent.account_id = 42
    jobs = [JobContextTestJob.new, JobContextTestJob.new]
    JobContext.perform_all_later(jobs)
    expect(adapter.payloads.size).to eq(2)
    snapshots = adapter.payloads.map { |payload| payload['job_context']['contexts']['JobContextCurrent'] }
    expect(snapshots).to eq([snapshots.first, snapshots.first])
  end

  it 'supports all and except attribute selection' do
    stub_const('SelectionCurrent', Class.new(ActiveSupport::CurrentAttributes) do
      attribute :one, :two
    end)
    JobContext.configure { |config| config.contexts = [{ current_attributes: SelectionCurrent, attributes: :all, except: [:two] }] }
    SelectionCurrent.one = 1
    SelectionCurrent.two = 2
    values = ActiveJob::Arguments.deserialize(JobContextTestJob.new.serialize['job_context']['contexts']['SelectionCurrent']).first
    expect(values).to eq(one: 1)
  end

  it 'reports unknown selected attributes' do
    JobContext.config.contexts = [{ current_attributes: JobContextCurrent, attributes: [:missing] }]
    expect { JobContextTestJob.new.serialize }.to raise_error(ArgumentError, /Unknown attributes.*missing/)
  end

  it 'rejects unsupported payload versions' do
    payload = JobContextTestJob.new.serialize
    payload['job_context']['version'] = 2
    expect { ActiveJob::Base.deserialize(payload) }.to raise_error(ArgumentError, /Unsupported/)
  end
end
