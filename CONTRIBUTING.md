# Contributing

Please report bugs or propose changes through
[GitHub issues](https://github.com/NicolasJJensen/rails_job_context/issues).
For bug reports, include the Ruby, Rails, and queue adapter versions, plus a small
example that reproduces the behavior.

## Repository layout

- `gems/rails_job_context`: context capture, restoration, and job ancestry.
- `gems/rails_job_context-good_job`: GoodJob dashboard integration and templates.
- `spec/spec_helper.rb`: shared test setup.
- `gemfiles`: dependency combinations used by the compatibility workflow.

Run development commands from the repository root.

## Running tests

```sh
bundle install
bundle exec rake
```

The transaction and dashboard request specs require PostgreSQL. They create and
drop uniquely named scratch databases. By default, they connect to
`postgres:///postgres` for database administration. The connected user must have
permission to create databases.

To use another administrative connection:

```sh
JOB_CONTEXT_PG_URL=postgres://localhost/postgres bundle exec rake
```

Application tables are created in scratch databases, not in the administrative
database. Database cleanup runs after the examples.

## Compatibility tests

The workflow covers Rails 7.2, 8.0, and 8.1, plus the supported GoodJob template
boundaries. It also tests the core without GoodJob in the bundle:

```sh
BUNDLE_GEMFILE=gemfiles/core_rails_8_0.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/core_rails_8_0.gemfile bundle exec rspec gems/rails_job_context/spec
```

To run a GoodJob combination:

```sh
BUNDLE_GEMFILE=gemfiles/good_job_4_18.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/good_job_4_18.gemfile bundle exec rspec
```

The package specs build and extract both gems, then boot Rails and render the
companion's packaged views. Loading specs also check the default Bundler entrypoint
and ensure the core does not load Rails or GoodJob.

See [Compatibility internals](docs/compatibility.md) before changing Active Job
capture hooks or copied GoodJob templates.

## Documentation

The root README is the main usage guide. Keep the core package README focused on
a standalone quickstart, and keep GoodJob instructions in the companion README.
Use repository URLs for links from packaged READMEs to files outside their package.

## Building and releasing

Both gems currently use matching versions. The companion depends on the exact
matching core version.

1. Update both version files and the root and package changelogs.
2. Run the test suite and relevant compatibility combinations.
3. Build both packages:

   ```sh
   bundle exec rake build
   ```

4. Inspect the artifacts in `pkg/` and verify their version and contents.
5. Publish the core artifact first, then the companion artifact.

Each package includes its own README and license. Preserve the GoodJob copyright
notice when updating derived templates.
