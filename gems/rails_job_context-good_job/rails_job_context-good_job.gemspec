# frozen_string_literal: true

require_relative 'lib/job_context/dashboard/version'

Gem::Specification.new do |spec|
  spec.name = 'rails_job_context-good_job'
  spec.version = JobContext::Dashboard::VERSION
  spec.authors = ['Nicolas J Jensen']
  spec.email = ['nicolasjensen9@gmail.com']
  spec.summary = 'Saved job contexts in the GoodJob dashboard'
  spec.description = 'Displays saved CurrentAttributes in GoodJob using rails_job_context.'
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
        'README.md', 'CHANGELOG.md', 'LICENSE.txt']
      .select { |path| File.file?(path) }
  end
  spec.require_paths = ['lib']
  spec.add_dependency 'rails_job_context', "= #{spec.version}"
  spec.add_dependency 'railties', '>= 7.2', '< 9.0'
  spec.add_dependency 'good_job', '>= 3.99', '< 5'
end
