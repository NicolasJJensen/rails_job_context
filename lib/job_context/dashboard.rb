module JobContext
  module Dashboard
    class << self
      def context_for(job)
        params = job.serialized_params || {}
        envelope = params[JobContext::Job::KEY] || params[JobContext::Job::KEY.to_sym]

        if envelope.is_a?(Hash)
          attributes = envelope['attributes'] || envelope[:attributes]
          attributes = attributes.first if attributes.is_a?(Array)
          attributes = attributes.to_h if attributes.respond_to?(:to_h) && !attributes.is_a?(Hash)
          return {
            'attributes' => attributes.is_a?(Hash) ? attributes : {},
            'correlation_stack' => envelope['correlation_stack'] || envelope[:correlation_stack] || []
          }
        end

        legacy_attributes = Array(params['arguments'] || params[:arguments]).last
        current_attributes = if legacy_attributes.is_a?(Hash)
          legacy_attributes['__metadata__'] || legacy_attributes[:__metadata__]
        end
        current_attributes = if current_attributes.is_a?(Hash)
          current_attributes['current_attributes'] || current_attributes[:current_attributes]
        end
        current_attributes = current_attributes.is_a?(Hash) ? current_attributes : {}
        {
          'attributes' => current_attributes,
          'correlation_stack' => current_attributes['correlation_stack'] || current_attributes[:correlation_stack] || []
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
    end
  end
end
