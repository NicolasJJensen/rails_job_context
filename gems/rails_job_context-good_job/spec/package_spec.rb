require 'spec_helper'
require 'rubygems/package'
require 'tmpdir'
require 'open3'

RSpec.describe 'Gem packages' do
  let(:root) { File.expand_path('../../..', __dir__) }

  it 'packages an independent core and an automatically loaded companion' do
    Dir.mktmpdir('job-context-packages-') do |directory|
      specifications = Dir[File.join(root, 'gems/*/*.gemspec')].sort.map do |path|
        Dir.chdir(File.dirname(path)) { Gem::Specification.load(File.basename(path)) }
      end
      specifications.each do |specification|
        source = File.join(root, 'gems', specification.name)
        destination = File.join(directory, specification.name)
        Dir.mkdir(destination)
        Dir.chdir(source) do
          artifact = File.join(directory, "#{specification.full_name}.gem")
          Gem::Package.build(specification, false, false, artifact)
          Gem::Package.new(artifact).extract_files(destination)
        end
      end

      core = specifications.find { |specification| specification.name == 'rails_job_context' }
      expect(core.runtime_dependencies.map(&:name)).to contain_exactly('activejob', 'activesupport')
      expect(core.files.grep(/good_job|\.erb\z/)).to be_empty
      expect(specifications.map(&:version).uniq.length).to eq(1)

      script = <<~'SCRIPT'
        $LOAD_PATH.unshift(*ARGV.drop(1))
        require 'rails_job_context'
        abort 'Core loaded Rails' if defined?(Rails)
        abort 'Core loaded GoodJob' if defined?(GoodJob)
        abort 'Loaded repository core' unless File.realpath(JobContext.method(:perform_all_later).source_location.first).start_with?(File.realpath(ARGV.fetch(0)) + File::SEPARATOR)
        require 'rails_job_context-good_job'
        require 'action_controller/railtie'
        require 'active_job/railtie'
        require 'tmpdir'
        Dir.mktmpdir('job-context-package-app-') do |root|
          application = Class.new(Rails::Application) do
            config.root = root
            config.eager_load = false
            config.global_id.app = 'job-context-package-spec'
            config.secret_key_base = 'test' * 32
            config.logger = Logger.new(File::NULL)
          end
          application.initialize!
          abort 'Details disabled' unless JobContext::Dashboard.config.details
          controller = GoodJob::ApplicationController.new
          job = Struct.new(:serialized_params).new({ 'job_context' => { 'version' => 1, 'contexts' => { 'TenantCurrent' => [{ 'account_id' => 42 }] } } })
          html = controller.render_to_string(partial: 'good_job/custom_job_details', locals: { job: job }, layout: false)
          abort 'Missing packaged views' unless html.include?('TenantCurrent')
          abort 'Loaded repository views' unless File.realpath(JobContext::Dashboard.common_view_path).start_with?(File.realpath(ARGV.fetch(0)) + File::SEPARATOR)
        end
      SCRIPT
      libraries = specifications.map { |specification| File.join(directory, specification.name, 'lib') }
      output, errors, status = Open3.capture3(
        RbConfig.ruby, '-e', script, directory, *libraries
      )
      expect(status.success?).to be(true), "#{errors}\n#{output}"
    end
  end
end
