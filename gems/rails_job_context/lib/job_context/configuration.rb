module JobContext
  class Configuration
    Context = Struct.new(:name, :current_class, :attributes, :except, keyword_init: true) do
      def selected_names
        declared = current_class.defaults.keys.map(&:to_sym)
        names = if attributes == :all
          declared
        elsif attributes.is_a?(Array)
          attributes.map { |attribute| normalize_attribute(attribute) }
        else
          raise ArgumentError, "Context #{name.inspect} attributes must be :all or an array"
        end
        unknown = names - declared
        raise ArgumentError, "Unknown attributes for context #{name.inspect}: #{unknown.join(', ')}" unless unknown.empty?

        names - Array(except).map { |attribute| normalize_attribute(attribute) }
      end

      private

      def normalize_attribute(attribute)
        return attribute.to_sym if attribute.respond_to?(:to_sym)

        raise ArgumentError, "Context #{name.inspect} attributes must contain names"
      end
    end

    attr_reader :contexts

    def initialize
      @contexts = []
      @registered_contexts = []
    end

    def contexts=(value)
      raise ArgumentError, 'contexts must be an array' unless value.is_a?(Array)

      @contexts = value.map { |definition| normalize_definition(definition) }
    end

    def register_context(current_attributes:, attributes: [], except: [])
      definition = normalize_definition(
        current_attributes: current_attributes,
        attributes: attributes,
        except: except
      )
      existing = @registered_contexts.find { |entry| entry == definition }
      return existing if existing

      @registered_contexts << definition
      definition
    end

    def resolved_contexts
      resolved = []
      @contexts.each do |definition|
        definition = normalize_definition(definition)
        current = resolve_current(definition[:current_attributes])
        name = current.name
        candidate = Context.new(name: name, current_class: current, attributes: definition[:attributes], except: definition[:except])
        existing = resolved.find { |context| context.name == name }
        if existing
          raise ArgumentError, "Duplicate context registration for #{name}"
        end
        resolved << candidate
      end
      @registered_contexts.each do |definition|
        current = resolve_current(definition[:current_attributes])
        name = current.name
        candidate = Context.new(name: name, current_class: current, attributes: definition[:attributes], except: definition[:except])
        existing = resolved.find { |context| context.name == name }
        if existing
          raise ArgumentError, "Conflicting context registration for #{name}" unless equivalent_context?(existing, candidate)
          next
        end
        resolved << candidate
      end
      resolved
    end

    private

    def normalize_definition(definition)
      raise ArgumentError, 'Context must be configured with a hash' unless definition.is_a?(Hash)

      current_attributes = definition[:current_attributes] || definition['current_attributes']
      raise ArgumentError, 'Context must configure current_attributes' if current_attributes.nil?

      attributes = definition.key?(:attributes) ? definition[:attributes] : definition.fetch('attributes', [])
      except = definition.key?(:except) ? definition[:except] : definition.fetch('except', [])
      { current_attributes: current_attributes, attributes: attributes, except: except }
    end

    def resolve_current(value)
      current = if value.is_a?(Class)
        value
      elsif value.respond_to?(:call)
        value.call
      end
      unless current.is_a?(Class) && current < ActiveSupport::CurrentAttributes
        raise ArgumentError, 'Context must resolve to an ActiveSupport::CurrentAttributes class'
      end
      raise ArgumentError, 'Context CurrentAttributes classes must have a stable name' if current.name.nil? || current.name.empty?

      current
    end

    def equivalent_context?(left, right)
      left.attributes == right.attributes && left.except == right.except
    end
  end
end
