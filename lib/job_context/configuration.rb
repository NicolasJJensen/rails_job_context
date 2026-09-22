module JobContext
  class Configuration
    Context = Struct.new(:name, :current_attributes, :attributes, :except, :resolved_class, keyword_init: true) do
      def current_class
        current = resolved_class || if current_attributes.is_a?(Class)
          current_attributes
        elsif current_attributes.respond_to?(:call)
          current_attributes.call
        end
        unless current.is_a?(Class) && current < ActiveSupport::CurrentAttributes
          raise ArgumentError, "Context #{name.inspect} must resolve to an ActiveSupport::CurrentAttributes class"
        end
        current
      end

      def selected_names(current = current_class, correlation_attribute: nil)
        declared = current.defaults.keys.map(&:to_sym)
        unless attributes == :all || attributes.is_a?(Array)
          raise ArgumentError, "Context #{name.inspect} attributes must be :all or an array"
        end
        names = if attributes == :all
          declared
        else
          attributes.map { |attribute| normalize_attribute(attribute) }
        end
        unknown = names - declared
        raise ArgumentError, "Unknown attributes for context #{name.inspect}: #{unknown.join(', ')}" unless unknown.empty?

        names - Array(except).map { |attribute| normalize_attribute(attribute) } - Array(correlation_attribute).map { |attribute| normalize_attribute(attribute) }
      end

      private

      def normalize_attribute(attribute)
        return attribute.to_sym if attribute.respond_to?(:to_sym)

        raise ArgumentError, "Context #{name.inspect} attributes must contain names"
      end
    end

    attr_reader :contexts, :correlation_context, :correlation_attribute

    def initialize
      @contexts = {}
      @correlation_context = nil
      @correlation_attribute = :correlation_stack
    end

    def contexts=(value)
      unless value.is_a?(Hash) && !value.empty?
        raise ArgumentError, 'contexts must be a non-empty hash'
      end
      normalized = {}
      value.each do |key, options|
        name = normalize_name(key)
        raise ArgumentError, "Duplicate context name #{name.inspect}" if normalized.key?(name)
        raise ArgumentError, "Context #{name.inspect} must be configured with a hash" unless options.is_a?(Hash)
        normalized[name] = Context.new(
          name: name,
          current_attributes: options[:current_attributes] || options['current_attributes'],
          attributes: options.key?(:attributes) ? options[:attributes] : options.fetch('attributes', []),
          except: options.key?(:except) ? options[:except] : options.fetch('except', [])
        )
      end
      @contexts = normalized
    end

    def correlation_context=(value)
      @correlation_context = normalize_name(value)
    end

    def correlation_attribute=(value)
      unless value.respond_to?(:to_sym)
        raise ArgumentError, 'correlation_attribute must be a name'
      end
      @correlation_attribute = value.to_sym
    end

    def resolved_contexts
      resolved = validate_contexts!
      @contexts.transform_values { |context| context.dup.tap { |copy| copy.resolved_class = resolved.fetch(context.name) } }
    end

    private

    def validate_contexts!
      owner = @correlation_context
      unless owner && @contexts.key?(owner)
        raise ArgumentError, 'correlation_context must name a configured context'
      end
      raise ArgumentError, 'Each context must configure current_attributes' if @contexts.values.any? { |context| context.current_attributes.nil? }

      resolved = @contexts.transform_values(&:current_class)
      raise ArgumentError, 'Each context must resolve to a distinct CurrentAttributes class' if resolved.values.uniq.length != resolved.length

      correlation = @correlation_attribute.to_sym
      owner_current = resolved.fetch(owner)
      unless owner_current.defaults.key?(correlation)
        raise ArgumentError, "Declare Current attribute #{correlation} for correlation_context #{owner.inspect}"
      end
      @contexts.each do |name, context|
        owner_attribute = name == owner ? correlation : nil
        context.selected_names(resolved.fetch(name), correlation_attribute: owner_attribute)
      end
      resolved
    end

    def normalize_name(value)
      name = value.to_s
      raise ArgumentError, "Invalid context name #{value.inspect}" unless name.match?(/\A[a-z][a-z0-9_]*\z/i)
      name
    end
  end
end
