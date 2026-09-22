module JobContext
  module Job
    extend ActiveSupport::Concern
    KEY = 'job_context'.freeze

    module SplitEnqueue
      private

      def _raw_enqueue
        # Active Job 8.1 calls this private hook after enqueue callbacks and before adapter handoff.
        capture_job_context!
        super
      end
    end

    def self.split_enqueue?
      ActiveJob::Base.private_method_defined?(:_raw_enqueue)
    end

    included do
      around_perform :with_job_context, prepend: true
      include JobContext::Job::SplitEnqueue if JobContext::Job.split_enqueue?
    end

    def capture_job_context!
      return @serialized_job_context if @serialized_job_context

      contexts = JobContext.config.resolved_contexts
      values = contexts.to_h do |context|
        attributes = context.selected_names.to_h do |attribute|
          value = context.current_class.public_send(attribute)
          begin
            ActiveJob::Arguments.serialize([value])
          rescue ActiveJob::SerializationError => error
            raise ActiveJob::SerializationError, "Context #{context.name}.#{attribute}: #{error.message}"
          end
          [attribute, value]
        end
        [context.name, ActiveJob::Arguments.serialize([attributes])]
      end
      # Deferred enqueue and retry paths retain the job object, so detach every value from Current.
      @serialized_job_context = { 'version' => 1, 'contexts' => values }.deep_dup
    end

    def job_context_for(current_class)
      payload = capture_job_context!.fetch('contexts')
      name = current_class.respond_to?(:name) ? current_class.name : nil
      return nil if name.nil?

      serialized = payload[name]
      serialized && detach_context_value(ActiveJob::Arguments.deserialize(serialized).first)
    end

    def serialize
      super.merge(KEY => capture_job_context!.deep_dup)
    end

    def deserialize(data)
      payload = data[KEY]
      if payload
        raise ArgumentError, 'Unsupported job_context version' unless payload['version'] == 1

        @serialized_job_context = payload.deep_dup
      end
      super(data)
    end

    private

    def raw_enqueue
      # Rails versions before 8.1 run callbacks before this private hook. Rails 8.1 uses _raw_enqueue.
      capture_job_context! if !JobContext::Job.split_enqueue? || deferred_enqueue?
      super
    end

    def deferred_enqueue?
      self.class.respond_to?(:enqueue_after_transaction_commit) && self.class.enqueue_after_transaction_commit
    end

    def with_job_context
      payload = capture_job_context!
      configured = JobContext.config.resolved_contexts
      payload_contexts = payload.fetch('contexts')
      missing = configured.map(&:name) - payload_contexts.keys
      raise ArgumentError, "Missing configured context payload: #{missing.join(', ')}" unless missing.empty?

      values = configured.to_h do |context|
        raw = detach_context_value(ActiveJob::Arguments.deserialize(payload_contexts.fetch(context.name)).first)
        [context.name, raw.slice(*context.selected_names)]
      end
      set_contexts(configured, values, 0) { yield }
    end

    def set_contexts(configured, values, index, &block)
      return block.call if index == configured.length

      context = configured.fetch(index)
      context.current_class.set(**values.fetch(context.name)) do
        set_contexts(configured, values, index + 1, &block)
      end
    end

    def detach_context_value(value)
      case value
      when Hash
        value.to_h { |key, nested| [key, detach_context_value(nested)] }
      when Array
        value.map { |nested| detach_context_value(nested) }
      when String
        value.dup
      else
        value
      end
    end
  end
end
