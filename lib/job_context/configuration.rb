module JobContext
  class Configuration
    DashboardOptions = Struct.new(:details, :table, keyword_init: true)
    attr_accessor :current_attributes, :attributes, :except, :correlation_attribute
    attr_reader :good_job

    def initialize
      @attributes = []
      @except = []
      @correlation_attribute = :correlation_stack
      @good_job = DashboardOptions.new(details: true, table: false)
    end

    def current_class
      current = current_attributes.respond_to?(:call) ? current_attributes.call : current_attributes
      unless current.is_a?(Class) && current < ActiveSupport::CurrentAttributes
        raise ArgumentError, 'Configure current_attributes with a CurrentAttributes class or a callable returning one'
      end
      current
    end

    def selected_names(current = current_class)
      declared = current.defaults.keys
      unless attributes == :all || attributes.is_a?(Array)
        raise ArgumentError, 'attributes must be :all or an array of attribute names'
      end
      names = attributes == :all ? declared : attributes.map(&:to_sym)
      unknown = names - declared
      raise ArgumentError, "Unknown Current attributes: #{unknown.join(', ')}" unless unknown.empty?
      unless declared.include?(correlation_attribute.to_sym)
        raise ArgumentError, "Declare Current attribute #{correlation_attribute} for job correlation"
      end
      names - Array(self.except).map(&:to_sym) - [correlation_attribute.to_sym]
    end
  end
end
