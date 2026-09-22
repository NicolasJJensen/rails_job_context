require 'spec_helper'

RSpec.describe JobContext::Configuration do
  class ConfigurationCurrent < ActiveSupport::CurrentAttributes
    attribute :account_id
  end

  it 'starts with an empty context array' do
    expect(described_class.new.contexts).to eq([])
  end

  it 'accepts appended and assigned definitions' do
    config = described_class.new
    config.contexts << { current_attributes: -> { ConfigurationCurrent }, attributes: [:account_id] }
    expect(config.resolved_contexts.map(&:name)).to eq(['ConfigurationCurrent'])
    config.contexts = []
    config.contexts.push('current_attributes' => -> { ConfigurationCurrent })
    expect(config.resolved_contexts.first.selected_names).to eq([])
  end

  it 'does not resolve callables until an operation uses the definitions' do
    config = described_class.new
    config.contexts = [{ current_attributes: -> { DelayedConfigurationCurrent }, attributes: [] }]
    stub_const('DelayedConfigurationCurrent', Class.new(ActiveSupport::CurrentAttributes))
    expect(config.resolved_contexts.first.name).to eq('DelayedConfigurationCurrent')
  end

  it 'normalizes and rejects malformed entries at resolution' do
    config = described_class.new
    config.contexts.push('current_attributes' => -> { ConfigurationCurrent })
    expect(config.resolved_contexts.first.name).to eq('ConfigurationCurrent')
    config.contexts << Object.new
    expect { config.resolved_contexts }.to raise_error(ArgumentError, /hash/)
  end

  it 'rejects anonymous and non CurrentAttributes classes' do
    config = described_class.new
    config.contexts = [{ current_attributes: Class.new }]
    expect { config.resolved_contexts }
      .to raise_error(ArgumentError, /CurrentAttributes/)
    config.contexts = [{ current_attributes: Object.new }]
    expect { config.resolved_contexts }
      .to raise_error(ArgumentError, /CurrentAttributes/)
  end

  it 'rejects duplicate configured classes' do
    config = described_class.new
    config.contexts = [
      { current_attributes: -> { ConfigurationCurrent } },
      { current_attributes: -> { ConfigurationCurrent } }
    ]
    expect { config.resolved_contexts }.to raise_error(ArgumentError, /Duplicate/)
  end

  it 'keeps extension registrations when contexts are assigned' do
    config = described_class.new
    definition = { current_attributes: -> { ConfigurationCurrent }, attributes: [:account_id] }
    expect(config.register_context(**definition)).to eq(config.register_context(**definition))
    config.contexts = []
    expect(config.resolved_contexts.map(&:name)).to eq(['ConfigurationCurrent'])
    config.register_context(current_attributes: -> { ConfigurationCurrent }, attributes: [:missing])
    expect { config.resolved_contexts }
      .to raise_error(ArgumentError, /Conflicting/)
  end
end
