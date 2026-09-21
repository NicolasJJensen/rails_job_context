module JobContext
  module Job
    extend ActiveSupport::Concern
    KEY = 'job_context'.freeze

    # Active Job 8.1 split raw_enqueue in two: raw_enqueue now runs the enqueue
    # callbacks around a new private _raw_enqueue, and the transaction deferral
    # hook wraps both. Earlier versions ran the callbacks before raw_enqueue.
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
      current = config.current_class
      values = config.selected_names(current).to_h do |name|
        value = current.public_send(name)
        begin
          ActiveJob::Arguments.serialize([value])
        rescue ActiveJob::SerializationError => error
          raise ActiveJob::SerializationError, "Current.#{name}: #{error.message}"
        end
        [name, value]
      end
      stack = Array(current.public_send(config.correlation_attribute)).dup
      stack << job_id unless stack.last == job_id
      # Detach nested strings and collections from the request before a transaction
      # can defer the adapter call. Repeated serialization and retries reuse this snapshot.
      @serialized_job_context = {
        'version' => 1,
        'attributes' => ActiveJob::Arguments.serialize([values]),
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
      else
        data = restore_legacy_context(data)
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
      self.class.respond_to?(:enqueue_after_transaction_commit) &&
        self.class.enqueue_after_transaction_commit
    end

    def with_job_context
      context = capture_job_context!
      config = JobContext.config
      current = config.current_class
      values = ActiveJob::Arguments.deserialize(context.fetch('attributes')).first.symbolize_keys
      values = values.slice(*config.selected_names(current))
      values[config.correlation_attribute.to_sym] = context.fetch('correlation_stack').dup
      current.set(**values) { yield }
    end

    def restore_legacy_context(data)
      options = data['arguments']&.last
      return data unless options.is_a?(Hash) && options.key?('__metadata__')

      metadata = ActiveJob::Arguments.deserialize([options['__metadata__']]).first
      values = (metadata[:current_attributes] || metadata['current_attributes'] || {}).symbolize_keys
      stack = values.delete(JobContext.config.correlation_attribute.to_sym) || []
      @serialized_job_context = {
        'version' => 1,
        'attributes' => ActiveJob::Arguments.serialize([values]),
        'correlation_stack' => stack
      }.deep_dup
      cleaned = data.deep_dup
      options = cleaned['arguments'].last
      options.delete('__metadata__')
      %w[_aj_symbol_keys _aj_ruby2_keywords].each do |key|
        options[key]&.delete('__metadata__')
      end
      cleaned['arguments'].pop if (options.keys - %w[_aj_symbol_keys _aj_ruby2_keywords]).empty?
      cleaned
    end
  end
end
