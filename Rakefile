require 'rspec/core/rake_task'
require 'rubygems/package'
require 'fileutils'

RSpec::Core::RakeTask.new(:spec) do |task|
  task.pattern = 'gems/*/spec/**/*_spec.rb'
end

desc 'Build the core and GoodJob companion gems'
task :build do
  FileUtils.mkdir_p('pkg')
  Dir['gems/*/*.gemspec'].sort.each do |path|
    directory = File.dirname(path)
    artifact = Dir.chdir(directory) do
      specification = Gem::Specification.load(File.basename(path))
      Gem::Package.build(specification)
    end
    FileUtils.mv(File.join(directory, artifact), File.join('pkg', artifact))
  end
end

task default: :spec
