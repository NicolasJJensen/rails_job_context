# frozen_string_literal: true

require_relative 'lib/job_context/version'

Gem::Specification.new do |spec|
  spec.name = 'rails_job_context'
  spec.version = JobContext::VERSION
  spec.authors = ['Nicolas J Jensen']
  spec.email = ['nicolasjensen9@gmail.com']
  spec.summary = 'Active Job context propagation and GoodJob causation views'
  spec.description = 'Copies selected CurrentAttributes into a namespaced field of the Active Job payload ' \
                     'and restores them around perform. The snapshot is taken before Rails can defer the ' \
                     'enqueue to transaction commit, so a job sees the values its caller held. Every job ' \
                     'also carries the IDs of the jobs that caused it. An optional GoodJob dashboard ' \
                     'integration shows the direct and root cause of each job.'
  spec.homepage = 'https://github.com/NicolasJJensen/rails_job_context'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'
  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues"
  }
  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*.rb', 'app/views/**/*', 'integrations/**/*',
        'README.md', 'CHANGELOG.md', 'LICENSE.txt', 'LICENSE.good_job.txt']
      .select { |path| File.file?(path) }
  end
  spec.require_paths = ['lib']
  spec.add_dependency 'activejob', '>= 7.2', '< 9.0'
  spec.add_dependency 'activesupport', '>= 7.2', '< 9.0'
end
