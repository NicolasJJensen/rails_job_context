# This gem owns the top-level JobContext module. Reopening a constant another
# library defined as a class raises an obscure TypeError deep in the require chain.
if defined?(::JobContext) && ::JobContext.is_a?(::Class)
  raise TypeError, 'rails_job_context defines the top-level constant JobContext as a module, ' \
                   'but JobContext is already defined as a class by another library. ' \
                   'Remove or rename the conflicting constant before loading rails_job_context.'
end

require 'active_job'
require 'active_support/current_attributes'
require 'active_support/core_ext'
require_relative 'job_context/version'
require_relative 'job_context/configuration'
require_relative 'job_context/job'

module JobContext
  class Error < StandardError; end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def perform_all_later(*jobs)
      jobs.flatten.each { |job| job.capture_job_context! if job.is_a?(Job) }
      ActiveJob.perform_all_later(*jobs)
    end
  end
end
