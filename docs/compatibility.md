# Compatibility notes

This document records the framework and dashboard seams that the two gems rely on.
Use it when upgrading Rails or GoodJob. The consumer setup is in the root
[README](../README.md), and the GoodJob installation guide is in the
[companion README](../gems/rails_job_context-good_job/README.md).

## Rails enqueue hooks

The core gem captures a context before Active Job defers enqueueing until a
transaction commits. The capture hooks use private Active Job methods because the
public enqueue callbacks do not expose the required timing on every supported Rails
release.

- Rails 7.2 and 8.0 use `raw_enqueue`. The capture runs after enqueue callbacks
  enter and before Rails defers the enqueue.
- Rails 8.1 uses `_raw_enqueue` for immediate jobs. The capture runs after enqueue
  callbacks enter.
- Rails 8.1 uses `raw_enqueue` for deferred jobs. The capture runs before Rails
  defers callbacks and enqueueing.

Changes made by deferred callbacks do not replace the saved snapshot. Rails and the
queue adapter still own transaction deferral. The gem does not enable deferral
globally.

Framework upgrades require callback timing checks and the real PostgreSQL
transaction checks in the compatibility suite.

## GoodJob details

The companion installs GoodJob's documented `good_job/custom_job_details` partial.
It displays saved context values without deserializing GlobalIDs or custom objects.
Application view paths take precedence. Repeated Rails preparation must not add
duplicate paths or duplicate extension partial registrations.

The companion depends on GoodJob `>= 3.99, < 5`. Test real Rails boot and rendering
when changing that range. Ancestry tracking and copied ancestry table templates
belong to the separate `rails_job_ancestry` project.

## Context registrations and payload

The core defines the top-level `JobContext` module. Contexts are registered as an
array of hashes. Each class must have a stable name, which identifies its serialized
attributes independently of the array order. The worker resolves only configured
classes and never constantizes class names supplied by a job payload.

A `job_context` envelope contains its version and a `contexts` map. The core assigns
no meaning to any application attribute. Nested `Current.set` blocks restore saved
attributes and recover previous state after execution.

Extensions can call `JobContext.register_context(current_attributes: SomeCurrent,
attributes: [:value])`. Extension registrations are separate from the application's
`config.contexts` array, so assigning that array does not erase extension state.
Repeated equivalent extension registrations must be idempotent.

`job.job_context_for(SomeCurrent)` returns the saved attributes for that class or
nil if it was not captured. Calling it before capture establishes the snapshot.
Returned values must not mutate the stored snapshot when a caller changes them.
