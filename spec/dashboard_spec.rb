require 'spec_helper'
require 'action_view'
require 'action_view/helpers'
require 'rails_job_context/good_job'

RSpec.describe 'GoodJob dashboard integration' do
  JobRecord = Struct.new(
    :id, :active_job_id, :job_class, :display_name, :serialized_params,
    :display_serialized_params, :error, :queue_name, :priority, :labels,
    :executions_count, :last_status_at, :status, :error_event,
    keyword_init: true
  )
  Filter = Struct.new(:filtered_count) do
    # GoodJob 4.18 reads filter.params[:state] to pick the mass actions it offers.
    def params = {}

    def to_params(override = {}) = override
  end

  before do
    stub_const('GoodJob::Job', Class.new do
      def self.where(*) = []
      def self.find_by(*) = nil
    end)
    allow(GoodJob::Job).to receive(:where).and_return([])
    allow(GoodJob::Job).to receive(:find_by).and_raise('dashboard must not use find_by')
  end

  def render_partial(name, locals = nil, paths: [JobContext::Dashboard.common_view_path, JobContext::Dashboard.details_view_path, JobContext::Dashboard.table_view_path], **keyword_locals)
    locals ||= keyword_locals
    lookup = ActionView::LookupContext.new(paths)
    view_class = ActionView::Base.with_empty_template_cache
    view = view_class.new(lookup, {}, nil)
    view.extend(ActionView::Helpers::UrlHelper)
    # GoodJob 4 opens routeless forms with form_with(model: false), so url_for
    # receives nil and cannot fall back to the application routes.
    view.define_singleton_method(:url_for) { |options = nil| options.is_a?(String) ? options : '/good_job/jobs' }
    view.define_singleton_method(:job_path) { |job| "/good_job/jobs/#{job.respond_to?(:id) ? job.id : job}" }
    view.define_singleton_method(:mass_update_jobs_path) { |_params| '/good_job/jobs/mass_update' }
    view.define_singleton_method(:reschedule_job_path) { |_id| '/good_job/jobs/reschedule' }
    view.define_singleton_method(:discard_job_path) { |_id| '/good_job/jobs/discard' }
    view.define_singleton_method(:force_discard_job_path) { |_id| '/good_job/jobs/force_discard' }
    view.define_singleton_method(:retry_job_path) { |_id| '/good_job/jobs/retry' }
    view.define_singleton_method(:render_icon) { |_name| '' }
    view.define_singleton_method(:relative_time) { |_time| 'now' }
    view.define_singleton_method(:status_badge) { |_status| 'succeeded' }
    view.define_singleton_method(:dom_id) { |record, suffix = nil| "job-#{record.id}#{suffix ? "-#{suffix}" : ''}" }
    view.define_singleton_method(:t) { |key, **_options| key.to_s }
    view.define_singleton_method(:job_action_states) do
      {
        reschedule: %w[scheduled retried queued], retry: %w[discarded],
        discard: %w[scheduled retried queued], force_discard: %w[running],
        destroy: %w[discarded succeeded]
      }
    end
    view.render partial: name, locals: locals
  end

  def job(id:, stack:, payload: nil, legacy: nil)
    serialized = if payload
      { 'job_context' => payload.merge('correlation_stack' => stack) }
    else
      { 'arguments' => [legacy || { '__metadata__' => { 'current_attributes' => { 'correlation_stack' => stack } } }] }
    end
    JobRecord.new(
      id: id, active_job_id: id, job_class: "Job#{id}", display_name: "Job#{id}",
      serialized_params: serialized, display_serialized_params: serialized,
      error: nil, queue_name: 'default', priority: 0, labels: [], executions_count: 1,
      last_status_at: Time.current, status: :succeeded, error_event: nil
    )
  end

  it 'renders new envelopes, legacy metadata, and unknown origins without deserializing' do
    expect(ActiveJob::Arguments).not_to receive(:deserialize)
    expect(GlobalID::Locator).not_to receive(:locate)
    current = job(id: 'current', stack: ['current'], payload: {
      'version' => 1,
      'attributes' => [{ 'controller' => 'orders', 'action' => 'create', 'user' => { '_aj_globalid' => 'gid://test/User/123' } }]
    })
    legacy = job(id: 'legacy', stack: ['legacy'], legacy: {
      '__metadata__' => { 'current_attributes' => { 'controller' => 'users', 'action' => 'show' } }
    })

    expect(render_partial('good_job/custom_job_details', job: current)).to include('orders#create')
    expect(render_partial('good_job/custom_job_details', job: legacy)).to include('users#show')
    expect(render_partial('good_job/custom_job_details', job: job(id: 'plain', stack: []))).to include('Unknown origin')
    positional = JobRecord.new(id: 'positional', active_job_id: 'positional', serialized_params: { 'arguments' => [42] })
    expect(render_partial('good_job/custom_job_details', job: positional)).to include('Unknown origin')
  end

  it 'covers good_job 3.99 up to 5 with contiguous series ranges' do
    bounds = JobContext::Dashboard::TABLE_SERIES.map do |series|
      series[:requirement].requirements.to_h { |operator, version| [operator, version] }
    end

    expect(bounds.first['>=']).to eq(Gem::Version.new('3.99'))
    expect(bounds.last['<']).to eq(Gem::Version.new('5'))
    bounds.each_cons(2) { |lower, upper| expect(lower['<']).to eq(upper['>=']) }
  end

  it 'ships a table template for every series it advertises' do
    JobContext::Dashboard::TABLE_SERIES.each do |series|
      path = File.expand_path("../integrations/good_job/views/#{series[:directory]}/good_job/jobs/_table.erb", __dir__)
      expect(File.file?(path)).to be(true), path
    end
  end

  it 'selects one table template for every GoodJob release in the supported range' do
    %w[
      3.99.0 3.99.9 4.0.0 4.0.3 4.5.0 4.7.0 4.9.1 4.12.1 4.13.0
      4.13.1 4.15.0 4.16.0 4.17.0 4.17.9 4.18.0 4.19.2 4.99.9
    ].each do |version|
      stub_const('GoodJob::VERSION', version)
      expect(JobContext::Dashboard.table_supported?).to be(true), version
      expect(File.basename(JobContext::Dashboard.table_view_path)).to eq(expected_table_series(version)), version
    end
  end

  it 'refuses the table override outside the supported range' do
    ['3.98.0', '5.0.0'].each do |version|
      stub_const('GoodJob::VERSION', version)
      expect(JobContext::Dashboard.table_supported?).to be(false), version
      expect { JobContext::Dashboard.table_view_path }.to raise_error(JobContext::Error, /#{Regexp.escape(version)}/)
    end
  end

  it 'selects the table template of the loaded GoodJob release' do
    expect(File.basename(JobContext::Dashboard.table_view_path)).to eq(expected_table_series)
    expect(File.file?(File.join(JobContext::Dashboard.table_view_path, 'good_job/jobs/_table.erb'))).to be(true)
  end

  it 'adds both cause columns to the table header', if: JobContext::Dashboard.table_supported? do
    record = job(id: 'child', stack: %w[root parent child], payload: { 'version' => 1, 'attributes' => [{}] })
    parent = job(id: 'parent-record', stack: [], payload: { 'version' => 1, 'attributes' => [{}] }).tap { |job| job.active_job_id = 'parent' }
    allow(GoodJob::Job).to receive(:where).with(active_job_id: %w[parent root]).and_return([parent])

    html = render_partial('good_job/jobs/table', { jobs: [record], filter: Filter.new(1) },
                          paths: [JobContext::Dashboard.common_view_path, JobContext::Dashboard.table_view_path])
    expect(html.scan('Direct Cause').size).to eq(2)
    expect(html.scan('Root Cause').size).to eq(2)
    expect(html).to include('Jobparent-record', 'Unavailable job (root)')
  end

  it 'batches shared direct and root ancestors once for the complete table', if: JobContext::Dashboard.table_supported? do
    first = job(id: 'first', stack: %w[root parent first], payload: { 'version' => 1, 'attributes' => [{}] })
    second = job(id: 'second', stack: %w[root parent second], payload: { 'version' => 1, 'attributes' => [{}] })
    root = job(id: 'root-record', stack: [], payload: { 'version' => 1, 'attributes' => [{}] }).tap { |record| record.active_job_id = 'root' }
    parent = job(id: 'parent-record', stack: [], payload: { 'version' => 1, 'attributes' => [{}] }).tap { |record| record.active_job_id = 'parent' }
    expect(GoodJob::Job).to receive(:where).with(active_job_id: %w[parent root]).once.and_return([root, parent])

    html = render_partial('good_job/jobs/table', { jobs: [first, second], filter: Filter.new(2) }, paths: [JobContext::Dashboard.common_view_path, JobContext::Dashboard.table_view_path])
    expect(html).to include('Jobroot-record')
    expect(html).to include('Jobparent-record')
    expect(html).to include('data-checkbox-toggle', 'mass_action')
  end

  it 'renders deleted ancestors as unavailable and preserves initial origin' do
    initial = job(id: 'initial', stack: ['initial'], payload: { 'version' => 1, 'attributes' => [{ 'controller' => 'orders', 'action' => 'create' }] })
    expect(render_partial('good_job/custom_job_details', job: initial)).to include('orders#create')
    expect(render_partial('good_job/custom_job_details', job: initial)).not_to include('Unavailable job')
    deleted = job(id: 'current', stack: %w[root current], payload: { 'version' => 1, 'attributes' => [{}] })
    allow(GoodJob::Job).to receive(:where).with(active_job_id: ['root']).and_return([])
    expect(render_partial('good_job/custom_job_details', job: deleted)).to include('Unavailable job (root)')
    existing = job(id: 'current', stack: %w[root current], payload: { 'version' => 1, 'attributes' => [{}] })
    root = job(id: 'root-record', stack: [], payload: { 'version' => 1, 'attributes' => [{}] }).tap { |record| record.active_job_id = 'root' }
    allow(GoodJob::Job).to receive(:where).with(active_job_id: ['root']).and_return([root])
    expect(render_partial('good_job/custom_job_details', job: existing)).to include('href="/good_job/jobs/root-record"')
  end
  partials = ['good_job/custom_job_details']
  partials << 'good_job/jobs/table' if JobContext::Dashboard.table_supported?
  partials.each do |partial|
    context partial do
      def render_job(partial, record)
        locals = partial.end_with?('table') ? { jobs: [record], filter: Filter.new(1) } : { job: record }
        render_partial(partial, locals)
      end

      [[], [42], [{ 'ordinary' => 'option' }], [{ '__metadata__' => {} }]].each do |arguments|
        it "handles absent correlation metadata in #{arguments.inspect}" do
          record = job(id: 'plain', stack: [])
          record.serialized_params = { 'arguments' => arguments }
          expect(GoodJob::Job).not_to receive(:where)
          html = render_job(partial, record)
          expect(html.scan('Unknown origin').size).to eq(2)
        end
      end

      it 'renders the initial origin twice without fetching its own job' do
        record = job(id: 'initial', stack: ['initial'], payload: { 'version' => 1, 'attributes' => [{ 'controller' => 'orders', 'action' => 'create' }] })
        expect(GoodJob::Job).not_to receive(:where)
        expect(render_job(partial, record).scan('orders#create').size).to eq(2)
      end

      it 'retains missing ancestor IDs without linking to deleted jobs' do
        record = job(id: 'child', stack: %w[root parent child], payload: { 'version' => 1, 'attributes' => [{}] })
        expect(GoodJob::Job).to receive(:where).with(active_job_id: %w[parent root]).once.and_return([])
        html = render_job(partial, record)
        expect(html).to include('Unavailable job (root)', 'Unavailable job (parent)')
        expect(html).not_to include('href="/good_job/jobs/root"', 'href="/good_job/jobs/parent"')
      end
    end
  end

end
