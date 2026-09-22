module JobContext
  module Dashboard
    Options = Struct.new(:details, :table, keyword_init: true)

    class << self
      def config
        @config ||= Options.new(details: true, table: false)
      end

      def configure
        yield config
      end

      def context_for(job)
        params = job.serialized_params || {}
        envelope = params[Job::KEY] || params[Job::KEY.to_sym]
        return empty_context unless envelope.is_a?(Hash)

        version = envelope['version'] || envelope[:version]
        return empty_context unless version == 1

        raw_contexts = envelope['contexts'] || envelope[:contexts] || {}
        return empty_context unless raw_contexts.is_a?(Hash)

        contexts = raw_contexts.each_with_object({}) do |(name, attributes), result|
          result[name.to_s] = display_attributes(attributes)
        end
        owner = (envelope['correlation_context'] || envelope[:correlation_context]).to_s
        stack = envelope['correlation_stack'] || envelope[:correlation_stack]
        {
          'attributes' => contexts.fetch(owner, {}),
          'contexts' => contexts,
          'correlation_stack' => stack.is_a?(Array) ? stack : []
        }
      end

      def ancestor_ids(jobs)
        jobs.flat_map do |job|
          stack = context_for(job)['correlation_stack']
          next [] if stack.length < 2

          [stack[-2], stack[0]]
        end.compact.uniq
      end

      def common_view_path
        File.expand_path('../../app/views', __dir__)
      end

      def ancestor_jobs(ids)
        return {} if ids.empty?

        GoodJob::Job.where(active_job_id: ids).index_by(&:active_job_id)
      end

      def cause_label(current_attributes, cause_id, cause_jobs: {})
        if cause_id
          cause_job = cause_jobs[cause_id]
          if cause_job
            return { type: :link, text: cause_job.job_class, job: cause_job }
          end

          return { type: :unavailable, text: "Unavailable job (#{cause_id})" }
        end

        controller = current_attributes['controller'] || current_attributes[:controller]
        action = current_attributes['action'] || current_attributes[:action]
        origin = [controller, action].compact_blank.join('#')
        { type: :origin, text: origin.presence || 'Unknown origin' }
      end

      private

      def empty_context
        { 'attributes' => {}, 'contexts' => {}, 'correlation_stack' => [] }
      end

      def display_attributes(serialized)
        value = serialized.is_a?(Array) ? serialized.first : serialized
        value = strip_internal_markers(value)
        value.is_a?(Hash) ? value : {}
      end

      def strip_internal_markers(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if %w[_aj_symbol_keys _aj_ruby2_keywords _aj_hash_with_indifferent_access].include?(key.to_s)

            result[key.to_s] = strip_internal_markers(child)
          end
        when Array
          value.map { |child| strip_internal_markers(child) }
        else
          value
        end
      end
    end
  end
end
