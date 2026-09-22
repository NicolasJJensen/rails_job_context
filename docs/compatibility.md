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

## GoodJob dashboard templates

The details integration adds a view path for GoodJob's documented
`good_job/custom_job_details` extension point. The table option replaces GoodJob's
complete jobs-table template, so the companion carries one template for each
upstream structural revision.

| GoodJob range | Companion template |
| --- | --- |
| `>= 3.99, < 4` | `gems/rails_job_context-good_job/integrations/good_job/views/v3` |
| `>= 4.0, < 4.13.1` | `gems/rails_job_context-good_job/integrations/good_job/views/v4_0` |
| `>= 4.13.1, < 4.17` | `gems/rails_job_context-good_job/integrations/good_job/views/v4_13` |
| `>= 4.17, < 4.18` | `gems/rails_job_context-good_job/integrations/good_job/views/v4_17` |
| `>= 4.18, < 5` | `gems/rails_job_context-good_job/integrations/good_job/views/v4_18` |

GoodJob 4.13.1 changed row actions to forms. GoodJob 4.17 changed row selection
controllers. GoodJob 4.18 added the `job_action_states` helper. The companion
selects a template by the loaded GoodJob version.

Application view paths keep higher priority than the companion paths. Set dashboard
options during application boot, then restart after changing them. Rails reloads
reinstall the managed paths without adding duplicates. If `config.table` is true
for a GoodJob version outside the table range, a runtime check rejects it.
The companion also declares `good_job >= 3.99, < 5` as a dependency. That range
applies even when only details are enabled; disabling the table does not permit
an unsupported GoodJob version.

The table batches direct and root ancestor lookups in one GoodJob query per render.
Dashboard details and table rendering read serialized context values without
resolving GlobalIDs or instantiating custom serialized objects.

## Core namespace and payload

The core defines the top-level `JobContext` module. Loading it raises a clear
error if another library has already defined `JobContext` as a class.

Job context lives in a namespaced `job_context` field beside Active Job's
arguments. The envelope contains a version, serialized values keyed by context
name, the correlation owner, and one ancestry stack. Execution restores contexts
inside nested `Current.set` blocks. Keep payload handling independent of the
GoodJob dashboard; the core must work without loading the companion.
