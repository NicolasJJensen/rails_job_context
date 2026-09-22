require 'spec_helper'
require 'action_view'
require 'rails_job_context-good_job'
require 'tmpdir'
require 'fileutils'

RSpec.describe JobContext::Dashboard do
  def render_details(payload)
    lookup = ActionView::LookupContext.new([described_class.common_view_path, described_class.details_view_path])
    view = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
    view.render partial: 'good_job/custom_job_details', locals: { job: Struct.new(:serialized_params).new(payload) }
  end

  let(:payload) do
    { 'job_context' => { 'version' => 1, 'contexts' => {
      'RequestCurrent' => [{ 'user' => { '_aj_globalid' => 'gid://app/User/123' }, '_aj_symbol_keys' => ['user'] }],
      'TenantCurrent' => [{ 'account_id' => 42, 'label' => '<script>alert(1)</script>' }]
    } } }
  end

  it 'displays contexts by class name without resolving serialized records' do
    expect(ActiveJob::Arguments).not_to receive(:deserialize)
    expect(GlobalID::Locator).not_to receive(:locate)
    html = render_details(payload)
    expect(html).to include('RequestCurrent', 'TenantCurrent', 'gid://app/User/123', 'account_id', '42')
    expect(html).not_to include('_aj_symbol_keys', '<script>', 'Root Cause', 'Direct Cause')
    expect(html).to include('&lt;script&gt;')
  end

  it 'renders no context panel for absent or malformed context data' do
    [{}, { 'job_context' => { 'version' => 1, 'contexts' => 'invalid' } },
     { 'job_context' => { 'version' => 2, 'contexts' => {} } }].each do |data|
      expect(render_details(data)).not_to include('Context attributes')
    end
  end

  it 'renders a registered extension once even when context details are disabled' do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, '_extra.html.erb'), 'Extension details')
      described_class.register_details_partial('extra')
      described_class.register_details_partial('extra')
      described_class.config.details = false
      lookup = ActionView::LookupContext.new([directory, described_class.common_view_path, described_class.details_view_path])
      view = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
      html = view.render partial: 'good_job/custom_job_details', locals: { job: Struct.new(:serialized_params).new(payload) }
      expect(html.scan('Extension details').length).to eq(1)
      expect(html).not_to include('Context attributes')
    end
  end
end
