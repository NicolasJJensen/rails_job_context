require 'spec_helper'

RSpec.describe JobContext::Configuration do
  let(:request_current) { Class.new(ActiveSupport::CurrentAttributes) { attribute :correlation_stack } }
  let(:tenant_current) { Class.new(ActiveSupport::CurrentAttributes) { attribute :account } }

  def configure(request_class: nil, tenant_class: nil, owner: :request)
    request_class ||= request_current
    tenant_class ||= tenant_current
    described_class.new.tap do |config|
      config.contexts = {
        request: { current_attributes: request_class, attributes: :all },
        tenant: { current_attributes: tenant_class, attributes: :all }
      }
      config.correlation_context = owner
    end
  end

  it 'rejects duplicate normalized context names' do
    config = described_class.new
    expect do
      config.contexts = { request: { current_attributes: request_current }, 'request' => { current_attributes: tenant_current } }
    end.to raise_error(ArgumentError, /Duplicate context name/)
  end

  it 'rejects duplicate Current classes and unknown owners' do
    expect { configure(tenant_class: request_current).resolved_contexts }
      .to raise_error(ArgumentError, /distinct CurrentAttributes/)
    config = configure
    config.correlation_context = :missing
    expect { config.resolved_contexts }.to raise_error(ArgumentError, /configured context/)
  end

  it 'returns string names and resolved classes' do
    resolved = configure.resolved_contexts
    expect(resolved.keys).to eq(%w[request tenant])
    expect(resolved['request'].current_class).to eq(request_current)
  end
end
