module JobContext
  module Job
    extend ActiveSupport::Concern
    KEY = 'job_context'.freeze

    # Active Job 8.1 split raw_enqueue in two. raw_enqueue now runs enqueue
    # callbacks around a new private _raw_enqueue. Earlier versions ran the
    # callbacks before raw_enqueue.
    module SplitEnqueue
      private

      def _raw_enqueue
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
      config = JobContext.config
      contexts = config.resolved_contexts
      values = contexts.to_h do |name, context|
        current = context.current_class
        owner_attribute = name == config.correlation_context ? config.correlation_attribute : nil
        selected = context.selected_names(current, correlation_attribute: owner_attribute)
        attributes = selected.to_h do |attribute|
          value = current.public_send(attribute)
          begin
            ActiveJob::Arguments.serialize([value])
          rescue ActiveJob::SerializationError => error
            raise ActiveJob::SerializationError, "Context #{name}.#{attribute}: #{error.message}"
          end
          [attribute, value]
        end
        [name, ActiveJob::Arguments.serialize([attributes])]
      end
      owner = contexts.fetch(config.correlation_context)
      stack = Array(owner.current_class.public_send(config.correlation_attribute)).dup
      stack << job_id unless stack.last == job_id
      # Detach nested strings and collections from the request before a transaction
      # can defer the adapter call. Repeated serialization and retries reuse this snapshot.
      @serialized_job_context = {
        'version' => 1,
        'contexts' => values,
        'correlation_context' => config.correlation_context.to_s,
        'correlation_stack' => stack
      }.deep_dup
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

    # This must run before Active Job's transaction deferral, but after the
    # before/around enqueue callbacks have entered the adapter handoff. On
    # Active Job 8.1 those two points are no longer the same method, so capture
    # here only for a deferred enqueue, where the callbacks run after the
    # commit and Current no longer holds the caller's values.
    def raw_enqueue
      capture_job_context! if !JobContext::Job.split_enqueue? || deferred_enqueue?
      super
    end

    def deferred_enqueue?
      self.class.respond_to?(:enqueue_after_transaction_commit) && self.class.enqueue_after_transaction_commit
    end

    def with_job_context
      context = capture_job_context!
      config = JobContext.config
      configured = config.resolved_contexts
      payload_contexts = context.fetch('contexts')
      missing = configured.keys - payload_contexts.keys
      raise ArgumentError, "Missing configured context payload: #{missing.join(', ')}" unless missing.empty?
      if context.fetch('correlation_context').to_s != config.correlation_context.to_s
        raise ArgumentError, 'Job context correlation owner does not match configuration'
      end
      values = configured.to_h do |name, setting|
        raw = ActiveJob::Arguments.deserialize(payload_contexts.fetch(name)).first.symbolize_keys
        owner_attribute = name == config.correlation_context ? config.correlation_attribute : nil
        selected = setting.selected_names(setting.current_class, correlation_attribute: owner_attribute)
        [name, raw.slice(*selected)]
      end
      values.fetch(config.correlation_context)[config.correlation_attribute.to_sym] = context.fetch('correlation_stack').dup
      set_contexts(configured, values, 0) { yield }
    end

    def set_contexts(configured, values, index, &block)
      return block.call if index == configured.length
      name, setting = configured.to_a.fetch(index)
      setting.current_class.set(**values.fetch(name)) do
        set_contexts(configured, values, index + 1, &block)
      end
    end
  end
end
