# frozen_string_literal: true

require_relative 'lib/job_context/version'

Gem::Specification.new do |spec|
  spec.name = 'rails_job_context'
  spec.version = JobContext::VERSION
  spec.authors = ['Nicolas J Jensen']
  spec.email = ['nicolasjensen9@gmail.com']
  spec.summary = 'Named CurrentAttributes snapshots and ancestry for Active Job'
  spec.description = 'Carries selected attributes from named CurrentAttributes classes through Active Job. ' \
                     'Restores each context during execution and tracks one job ancestry stack.'
  spec.homepage = 'https://github.com/NicolasJJensen/rails_job_context'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'
  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues"
  }
  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*.rb', 'README.md', 'CHANGELOG.md', 'LICENSE.txt']
      .select { |path| File.file?(path) }
  end
  spec.require_paths = ['lib']
  spec.add_dependency 'activejob', '>= 7.2', '< 9.0'
  spec.add_dependency 'activesupport', '>= 7.2', '< 9.0'
end
