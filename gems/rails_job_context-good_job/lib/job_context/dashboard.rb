module JobContext
  module Dashboard
    Options = Struct.new(:details, keyword_init: true)

    class << self
      def config
        @config ||= Options.new(details: true)
      end

      def configure
        yield config
      end

      def details_partials
        @details_partials ||= []
      end

      def register_details_partial(path)
        details_partials << path unless details_partials.include?(path)
      end

      def context_for(job)
        params = job.serialized_params || {}
        envelope = params[Job::KEY] || params[Job::KEY.to_sym]
        return {} unless envelope.is_a?(Hash) && (envelope['version'] || envelope[:version]) == 1

        contexts = envelope['contexts'] || envelope[:contexts]
        return {} unless contexts.is_a?(Hash)

        contexts.transform_keys(&:to_s).transform_values do |serialized|
          attributes = serialized.is_a?(Array) ? serialized.first : serialized
          attributes.is_a?(Hash) ? display_value(attributes) : {}
        end
      end

      private

      def display_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if %w[_aj_symbol_keys _aj_ruby2_keywords _aj_hash_with_indifferent_access].include?(key.to_s)

            result[key.to_s] = display_value(child)
          end
        when Array
          value.map { |child| display_value(child) }
        else
          value
        end
      end
    end
  end
end
