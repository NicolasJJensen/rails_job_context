require 'rails_job_context'
require 'rails'
require 'good_job'
require_relative 'engine'

module JobContext
  module Dashboard
    class << self
      def common_view_path
        File.expand_path('../../app/views', __dir__)
      end

      def details_view_path
        File.expand_path('../../integrations/good_job/details', __dir__)
      end

      def install!
        controller = GoodJob::ApplicationController
        managed = [common_view_path, details_view_path]
        paths = controller.view_paths.to_a.reject { |path| managed.include?(path.to_s) }
        original = GoodJob::Engine.root.join('app/views').to_s
        # Keep application overrides ahead of the gem when Rails reloads views.
        position = paths.index { |path| path.to_s == original } || paths.length
        selected = [common_view_path]
        selected << details_view_path if config.details || details_partials.any?
        paths.insert(position, *selected)
        controller.view_paths = paths
      end
    end
  end
end
