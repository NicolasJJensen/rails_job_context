require 'rails/engine'
require_relative 'dashboard'

module JobContext
  class Engine < ::Rails::Engine
    isolate_namespace JobContext
    # Only the selected GoodJob integration should participate in view lookup.
    paths['app/views'].to_ary.clear

    initializer 'job_context.good_job_dashboard', after: :load_config_initializers do |app|
      app.config.to_prepare { JobContext::Dashboard.install! }
    end
  end
end
