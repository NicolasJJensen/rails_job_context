require 'rails_job_context'
require 'rails'

module JobContext
  # The dashboard integration reads GoodJob's models and prepends view paths to
  # GoodJob's controller. Both are internal to GoodJob, so the range is explicit.
  GOOD_JOB_REQUIREMENT = ['>= 3.99', '< 5'].freeze
end

begin
  gem 'good_job', *JobContext::GOOD_JOB_REQUIREMENT
rescue Gem::LoadError => error
  raise JobContext::Error,
        "rails_job_context-good_job supports good_job #{JobContext::GOOD_JOB_REQUIREMENT.join(', ')}. " \
        "Bundler resolved a version outside that range. Original error: #{error.message}"
end

require 'good_job'
require_relative 'engine'

module JobContext
  module Dashboard
    # The table override is a full copy of GoodJob's jobs-table template, so the
    # gem carries one copy per structural revision of that template. The splits
    # match the upstream releases that changed what the template calls:
    #   4.13.1 replaced the rails-ujs row action links with job_action_form and
    #          job_destroy_form button forms. 4.13.0 still ships the links.
    #   4.17.0 moved row selection onto the Stimulus checkbox-toggle controller.
    #   4.18.0 added the job_action_states helper, which earlier releases lack.
    # Ranges are contiguous and cover every release from 3.99 up to 5.
    TABLE_SERIES = [
      { directory: 'v3', requirement: Gem::Requirement.new('>= 3.99', '< 4') },
      { directory: 'v4_0', requirement: Gem::Requirement.new('>= 4.0', '< 4.13.1') },
      { directory: 'v4_13', requirement: Gem::Requirement.new('>= 4.13.1', '< 4.17') },
      { directory: 'v4_17', requirement: Gem::Requirement.new('>= 4.17', '< 4.18') },
      { directory: 'v4_18', requirement: Gem::Requirement.new('>= 4.18', '< 5') }
    ].freeze
    SUPPORTED_TABLE_RANGE = TABLE_SERIES
                            .map { |series| "#{series[:requirement]} (#{series[:directory]})" }
                            .join(', ').freeze

    class << self
      def common_view_path
        File.expand_path('../../app/views', __dir__)
      end

      def details_view_path
        File.expand_path('../../integrations/good_job/details', __dir__)
      end

      def table_view_paths
        TABLE_SERIES.map { |series| table_view_path_for(series[:directory]) }
      end

      def table_view_path
        series = table_series
        raise table_error unless series

        table_view_path_for(series[:directory])
      end

      def table_supported?
        !table_series.nil?
      end

      def install!
        controller = GoodJob::ApplicationController
        managed = [common_view_path, details_view_path, *table_view_paths]
        paths = controller.view_paths.to_a.reject { |path| managed.include?(path.to_s) }
        original = GoodJob::Engine.root.join('app/views').to_s
        # Insert before GoodJob's own templates, retaining the host application's
        # higher-priority overrides. to_prepare repeats this after Rails reloads.
        position = paths.index { |path| path.to_s == original } || paths.length
        selected = [common_view_path]
        selected << details_view_path if config.details
        selected << table_view_path if table_selected?
        paths.insert(position, *selected)
        controller.view_paths = paths
      end

      private

      def good_job_version
        Gem::Version.new(::GoodJob::VERSION)
      end

      def table_series
        version = good_job_version
        TABLE_SERIES.find { |series| series[:requirement].satisfied_by?(version) }
      end

      def table_view_path_for(directory)
        File.expand_path("../../integrations/good_job/views/#{directory}", __dir__)
      end

      def table_selected?
        return false unless config.table
        return true if table_supported?

        raise table_error
      end

      def table_error
        JobContext::Error.new(
          "JobContext::Dashboard.config.table replaces GoodJob's complete jobs-table template. " \
          "The gem ships one copy per GoodJob series, matching good_job #{SUPPORTED_TABLE_RANGE}. " \
          "This application loads good_job #{::GoodJob::VERSION}. " \
          'Set JobContext::Dashboard.config.table = false and keep details = true.'
        )
      end

    end
  end
end
