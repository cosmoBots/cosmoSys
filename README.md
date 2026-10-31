# cosmoSys

Version 0.2.7: snapshots retain attachment source IDs and pass
the imported attachment ID map to registered reference rewriters. Plugins own
their macro syntax; cosmoSys does not depend on CAD or the document catalog
for attachment identity. Rewriting runs after file restoration for items,
documents, restored wiki content and imported presentation baselines.

Version 0.2.6: Figure, Table, Formula and Model document families
extend the catalog. Cite with `document:di123` or include the document's Markdown
description with `{{document_embed(di123)}}`. Project report settings choose
catalog ordering or first-inclusion numbering per family. The `doc` item profile
offers optional indexes for all seven families; the related-document section
installer creates them together. No schema migration is needed.
Automatic captions use italic blockquotes. `{{image_gap(0.5cm)}}` (also mm/px)
adds transparent spacing within a row of images; keep the macro and images in
the same paragraph. Export fits table images to their cell widths so their
intrinsic size cannot force tables beyond page margins.

Version 0.2.5 fixes project combined and dependency diagrams with cross-project
traversal: only the focal project's items seed discovery. Enabled causal paths
and their visible ancestors are included, but disconnected subproject items
and unrelated branches are not. No database migration is added.

Version 0.2.4: database migrations and runtime queries use Rails/Arel for
database portability, with schema reconciliation for existing installations
and larger payload capacity. The workspace functional suite passes 55/55 on
PostgreSQL, MySQL and SQLite. Existing-installation schema reconciliation is
validated against PostgreSQL; full populated rollback of all optional plugins
is not certified. New bounded text/binary columns request 16 MiB minus one byte
through Rails. This does not preallocate space, impose an upload policy or
shrink existing wider/unbounded columns.

Version 0.2.3 introduced project subtree deletion that preserves external datum
consumers and rolls back child failures. Administrators can audit project trees
and explicitly retry scheduled deletions with the scripts in `scripts/`.
Missing consolidated evidence is reported separately from content drift;
viewing an item never creates approval evidence.

Base plugin for [Redmine](https://www.redmine.org), providing a shared
engineering model on which domain extensions are built.

cosmoSys turns Redmine into a workspace where tasks, requirements, documents
and their relations form a live model of the project. Teams can navigate that
model as a tree, analyse it through diagrams and matrices, and turn it into
professional documentation without leaving the shared workspace. It is free,
open source, and has no per-seat limits.

Domain extensions such as [cosmoSys-Req](https://github.com/cosmoBots/cosmoSys_Req)
add specialised capabilities on top of this base.

You can find more information about cosmoSys in the [cosmoBots.eu site](https://cosmobots.eu/projects/csys/wiki/CosmoSys)

## Project history

This is not a new project created by this repository. It is a refactoring and
continuation of the earlier
[`cosmosys_rm`](https://github.com/cosmoBots/cosmosys_rm) Redmine plugin.
That line of development runs from its first commit on 28 November 2020
through the current 2026 refactoring. The repository history was deliberately
restarted to publish a clean software artifact; this does not erase or replace
the project's earlier history and authorship.

## Status

The current code declares **0.2.7**. Release 0.2.6 extends document
families on top of release 0.2.5 while retaining database portability and
schema reconciliation.
It retains explicit recovery of
interrupted snapshot imports, cooperative cancellation of abandoned diagram
renders, safer project deletion and diagnostics for missing approval evidence.
It retains server-side LaTeX report export and complete macro preservation.
It includes the tree editor, report image layout fixes, independent settings
tabs and global snapshot imports from 0.2.1. These workflows were validated in
Redmine 3001. Publication and deployment pinning are separate steps.

This repository contains an early alpha artifact. It is suitable for controlled
evaluation and is not yet declared production-ready. You can install it and try
it, but expect breaking changes.

## Requirements

cosmoSys requires a working [Redmine](https://www.redmine.org) installation.
It is developed and validated against **Redmine 7.0.1** (Rails 8). Earlier
major versions are not supported. It is licensed under GPLv3 by cosmoBots.eu.

In addition to the normal Redmine runtime, cosmoSys needs:

- **System packages**: `graphviz` (diagrams), `imagemagick` (rasterizing
  diagrams and composing report images), `librsvg2-bin` and
  `libreoffice-writer` (report export to ODT/DOCX/PDF), `libxml2-dev` and
  `pkg-config` (build `libxml-ruby`), and `git` (dependency resolution).
- **Ruby gems** (declared in this plugin's `Gemfile`):
  - `libxml-ruby >= 6.0`;
  - [rspreadsheet](https://github.com/cosmoBots/rspreadsheet), pinned by
    revision, used for ODS export/import and materialisation. Without
    `RSPREADSHEET_PATH`, Bundler resolves it from Git; you can also check out
    the pinned revision locally and point `RSPREADSHEET_PATH` at it.
- **Runtime gems** installed into the plugin environment by the deployment
  image: `andand` and `rubyzip`.

## Installation (classic, no Docker)

Install cosmoSys into an existing Redmine instance the same way you install any
Redmine plugin. You do not need Docker or the deployment repository for this.

1. **Stop the web server** (or run migrations while no requests are served).

2. **Place the plugin in the plugins directory.** From the Redmine root,
   either clone the repository or copy the plugin files so that
   `plugins/cosmosys` exists:

   ```bash
   cd /path/to/redmine
   git clone https://github.com/cosmoBots/cosmoSys.git plugins/cosmosys
   ```

   A packaged release can be unpacked to `plugins/cosmosys` instead. Only the
   plugin directory itself is required; cosmoSys has no install-time dependency
   on this workspace.

3. **Install dependencies.** Redmine resolves plugins from its own `Gemfile`.
   For a local installation of the `ruby4-libxml6` fork, follow
   [Installing rspreadsheet from source](#installing-rspreadsheet-from-source)
   below, then return to step 4. Otherwise, cosmoSys' gems must be available
   to the Redmine bundle, so run from the Redmine root:

   ```bash
   bundle install
   ```

   Install the additional runtime gems in the same Ruby environment used by
   Redmine:

   ```bash
   gem install andand 'rubyzip:>= 3.0, < 4' 'libxml-ruby:>= 6.0' --no-document
   ```

4. **Run the plugin migrations.** cosmoSys extends the Redmine schema with its
   own tables and columns. From the Redmine root:

   ```bash
   RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=cosmosys
   ```

   For a development or test environment, set `RAILS_ENV=development` (or
   `test`) accordingly. Migrations `001`–`009` are sealed by releases through
   0.1.6. Migration `009` adds the snapshot wiki-page count only if the column
   is absent, so it also repairs databases where an earlier 0.1.5 build already
   added it. An upgrade from an earlier release migrates through the latest
   available migration. Release 0.1.9 seals migration `010`, which enables
   missing required profile trackers on existing projects. Release 0.1.11
   seals migration `011`, adding the per-project requirement-chain-validity
   setting (enabled by default). Release 0.2.0 seals migration `012`, which
   stores fingerprints for post-migration contract reconciliation.

5. **Normalise item query names (recommended).** cosmoSys sets the visible
   domain vocabulary to `item`/`items` (and `ítem`/`ítems` in Spanish) and
   normalises the persisted names of public queries that Redmine installs.
   After migrating, run its normalisation script once from the Redmine root:

   ```bash
   RAILS_ENV=production bundle exec rails runner \
     plugins/cosmosys/scripts/normalize_item_query_names.rb
   ```

   This matches the behaviour of the reference bootstrap (see
   `scripts/bootstrap_redmine.sh` in the workspace). You can skip it if you
   prefer Redmine's default issue vocabulary, but the plugin's own data and
   report labels then stay inconsistent with the visible item terms.

6. **Restart Redmine** so the plugin is loaded, then open the administration
   screen to see the cosmoSys entries (item kinds, templates, and visual
   identity) and confirm the plugin is listed.

### Installing rspreadsheet from source

Use the cosmoBots fork's
[`ruby4-libxml6` branch](https://github.com/cosmoBots/rspreadsheet/tree/ruby4-libxml6)
for Ruby 4 / libxml-ruby 6 compatibility. Run Ruby commands with the same Ruby
installation and gem environment as Redmine (including its version manager,
if any).

1. **Install build prerequisites.** On Debian/Ubuntu:

   ```bash
   sudo apt-get update
   sudo apt-get install -y build-essential git libxml2-dev pkg-config
   gem install andand 'rubyzip:>= 3.0, < 4' 'libxml-ruby:>= 6.0' --no-document
   ```

   Ruby development headers must also be available; with a distribution Ruby,
   install the matching `ruby-dev` package. Other operating systems need the
   equivalent compiler, libxml2 development files and pkg-config packages.

2. **Clone the branch** into a permanent directory readable by Redmine:

   ```bash
   mkdir -p "$HOME/src"
   cd "$HOME/src"
   git clone --branch ruby4-libxml6 --single-branch https://github.com/cosmoBots/rspreadsheet.git
   cd rspreadsheet
   ```

   To reproduce the revision currently pinned by cosmoSys' `Gemfile` and the
   reference deployment, check it out before building:

   ```bash
   git checkout --detach c01d413abc728db9d62aa1bebe776f548ee69999
   ```

   Omit that checkout only if you intend to evaluate the latest branch commit.

3. **Build and install the gem** from that checkout:

   ```bash
   gem build rspreadsheet.gemspec --output rspreadsheet-local.gem
   gem install ./rspreadsheet-local.gem --no-document
   ruby -r rspreadsheet -e 'puts Gem.loaded_specs.fetch("rspreadsheet").full_gem_path'
   ```

   Installing the generated file ensures you install this fork rather than
   the gem published on RubyGems under the same name.

4. **Select the checkout in Redmine's bundle.** Installing a gem alone does
   not override the Git source declared by cosmoSys. From the Redmine root:

   ```bash
   cd /path/to/redmine
   export RSPREADSHEET_PATH="$HOME/src/rspreadsheet"
   bundle install
   bundle exec ruby -r rspreadsheet -e 'puts Gem.loaded_specs.fetch("rspreadsheet").full_gem_path'
   ```

   The last command must print the checkout directory. Set `RSPREADSHEET_PATH`
   to that same **absolute path** in the Redmine service environment as well,
   for both web processes and background jobs, and keep it set for migrations
   and future Bundler commands. Use a shared directory if the service user
   cannot access your home directory. Keep the checkout: Bundler loads its
   source through `path:`, as in the reference Dockerfile's `/opt/rspreadsheet`
   installation. Return to installation step 4 to migrate and restart Redmine.

### Upgrading an existing installation

To update cosmoSys in place:

```bash
cd /path/to/redmine
git -C plugins/cosmosys fetch
git -C plugins/cosmosys checkout <new-tag-or-sha>
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=cosmosys
# restart Redmine
```

Migration `010` repairs existing projects by enabling the available required
trackers of their registered profile, including `csNegative`, without removing
existing assignments. It is idempotent and keeps these assignments on rollback.
This addresses the 0.1.8 upgrade failure when bootstrap saves legacy help
projects. Ordinary project saves no longer validate unrelated tracker state;
the tracker assignment methods continue to reject removal of required trackers.

After plugin migrations have run, the web server runs
`Cosmosys::ConsolidationService` at startup. It compares the current registered
profile-contract fingerprints with the stored fingerprints and reconciles only
the affected profile scopes. The initial consolidator ensures that existing
projects have the required trackers for their profile; it does not remove
trackers. Plugin migrations remain conventional and do not need to call this
service. `rails runner` and migration tasks do not trigger startup
consolidation; restart the web server after applying migrations.

The migration base is developed fast and the project is still in alpha: the
schema is not yet backward-compatible by design, so back up the database
before upgrading.

## Installation with Docker Compose

For a reproducible Docker installation, use the separate
[`cosmoSys_deploy`](https://github.com/cosmoBots/cosmoSys_deploy) repository.
It defines the Redmine image, pins compatible cosmoSys revisions, runs the
migrations and bootstrap, and provides health checks, backups and update/restore
scripts. You do not need to clone or install this plugin separately.

Clone the deployment repository, create its environment file and set the
required database, Redmine secret and initial administrator credentials as
described in its [README](https://github.com/cosmoBots/cosmoSys_deploy#configure):

```bash
git clone https://github.com/cosmoBots/cosmoSys_deploy.git
cd cosmoSys_deploy
cp .env.example .env
# Edit .env and replace the required example credentials.
```

To run Redmine with cosmoSys only:

```bash
docker compose -f compose.yml build
docker compose -f compose.yml up -d
```

The deployment repository also provides a Requirements variant with
cosmoSys-Req. Its full setup, configuration, upgrade and backup instructions
are maintained in [`cosmoSys_deploy/README.md`](https://github.com/cosmoBots/cosmoSys_deploy#requirements-variant).
For a manual Compose start, use both files:

```bash
docker compose -f compose.yml -f compose.requirements.yml build
docker compose -f compose.yml -f compose.requirements.yml up -d
```

### Project-profile trackers

Every cosmoSys project profile inherits the base trackers `csInfo`, `csRefDoc`,
`csData`, `csDatum` and `csNegative`. Domain plugins add only their own trackers;
for example, the Architecture PBS profile adds `archNode` without enabling
requirement trackers. `csNegative` is cosmoSys' report placeholder for listing
unsuccessfully closed items and is available in specialized profiles as well.

### Report exports

Report spacing normalization leaves Redmine macro sources intact, including
indentation, CRLF/LF line endings and line continuations. Redmine expands macros
before HTML-specific export preparation; the report does not rewrite their
embedded diagram code.


When `redmine_cbots_latex` is installed, static ODT/DOCX/PDF export invokes its
server-side renderer before importing HTML into Writer. Browser MathJax is not
used for document export. Formula images keep their CSS print dimensions so
inline formulas and table cells retain their layout. Unsupported expressions
remain readable as source text; the static renderer supports a subset of TeX.


Report metadata renders user custom fields by user name, including fields with
multiple selections. ODT/DOCX/PDF exports center natural-size raster images
inside the printable width with transparent padding instead of scaling visible
pixels. Consecutive images that are the only contents of a Markdown paragraph
are composed side by side and bottom-aligned; paragraphs with text or explicit
image sizing keep their authored layout.

These report improvements and startup contract reconciliation are included in
cosmoSys since 0.2.0. Version 0.2.1 also fixes composition of explicitly sized
inline HTML images and centers the composed row within the printable width.
Validation runs against Redmine 3001 before publication and deployment.

## Project settings and snapshot imports

Project settings use separate General, Reports, Item list, Diagrams and Branding
sections. Each form saves only its submitted settings and returns to that
section. Save before switching sections.

Administrators can import directly from the global Projects list, New project
or Administration via `/cosmosys/snapshots/import`, without creating an origin
project. The parent is optional and defaults to root-level placement. Global
and project-scoped uploads and results remain separately bound to their owner.

Snapshot preflight lets administrators choose private (default) or public
visibility for the entire new tree; changing it requires a new confirmation.
Confirmed browser `.csys` imports run via the configured ActiveJob adapter and
show phase/count progress with recent results retained for seven days in
`tmp/cosmosys/snapshot-import-operations`. The web server and workers must share
that temporary directory. The uploaded work package is removed after success or
failure. This uses the same job infrastructure as ODS; the `async` adapter does
not resume interrupted jobs after restarting the server. Do not restart during
an import. No new database migration is required.

## Repository

The canonical repository for this project is
[github.com/cosmoBots/cosmoSys](https://github.com/cosmoBots/cosmoSys).
Forks and mirrors are welcome under the terms of the GPLv3, but they are not
maintained by cosmoBots.eu and may diverge from this source.

## Contact and licence

- Contact: cosmosys@elporis.com
- Licence: GNU General Public License version 3; see [`LICENSE`](LICENSE).
