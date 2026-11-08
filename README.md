# cosmoSys

> **PRODUCTION:** cosmoSys is intended for production use on the supported
> Redmine versions and documented configurations. Optional experimental plugins
> are separate, opt-in integrations; they do not share this production status.

Version **0.2.10-dirty**.

## Capabilities

- Navigate items, relationships, trees, diagrams and matrices.
- Generate HTML, ODT, DOCX and PDF reports.
- Organize references and embed Figure, Table, Formula and Model documents with
  `{{document_embed(di123)}}`. Each project can number families by catalog order
  or first appearance. Use `{{image_gap(0.5cm)}}` to space adjacent images.
- Exchange project data through ODS and project snapshots. Attachment references
  within the captured scope are remapped on import.
- Preview a YAML model without creating or changing items: use **Preview YAML
  model** from an item or project. Select an example scope, paste YAML, use an
  attachment or upload a file. Changing the example scope replaces unsaved text.
  Drafts are limited to 1 MiB, 500 items and 2,000 relations.

ODS imports are incremental: rows absent from the workbook leave existing items
untouched; absent columns leave those attributes unchanged. An empty cell in a
present column explicitly clears that attribute where permitted. Importing only
new rows adds those items without replacing the project. ODS import never
deletes items: change their status or delete them in Redmine instead.

To embed a model in documentation, write `{{cosmosys_diagram` on an opening
line, a complete model YAML beneath it, and `}}` on its own closing line.
Use the preview's generated examples for the format and the types and fields
supported by each installed project profile. The macro renders a static diagram
and also works in report exports. Neither the preview nor the macro creates or
synchronizes model records; normal source-item visibility permissions apply.

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


cosmoSys is a production plugin, not an early-alpha evaluation artifact.
Production upgrades must follow the documented compatibility requirements,
validation and backup procedures. Experimental extensions remain optional and
have their own warnings; installing one introduces its experimental risks into
the instance.

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
   gem install andand --no-document
   gem install rubyzip --version '>= 3.0, < 4' --no-document
   gem install libxml-ruby --version '>= 6.0' --no-document
   ```

4. **Run the plugin migrations.** cosmoSys extends the Redmine schema with its
   own tables and columns. From the Redmine root:

   ```bash
   RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=cosmosys
   ```

   For development or tests, set `RAILS_ENV=development` or `test`.
   Run all available migrations when upgrading.

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
   gem install andand --no-document
   gem install rubyzip --version '>= 3.0, < 4' --no-document
   gem install libxml-ruby --version '>= 6.0' --no-document
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

### ODS template fields and dictionaries

The `Dict` sheet contains the base catalogs. Domain plugins register their
own dictionary sheets, columns and accepted values through
`Cosmosys::OdsItemFieldRegistry`. Template preparation creates their catalogs
and range-based selectors without reserving columns in `Dict`; export fills
catalog values and preserves the template structure. A registered
`header` can differ from the internal attribute name. Import accepts that
header only, rejects prefixed alternatives and duplicate columns, and never
uses workbook catalogs to override model validation. Unused tracker/status
selectors remain empty. For new items, choose a valid tracker; blank status
and priority retain the import defaults.

### Upgrading an existing installation

To update cosmoSys in place:

```bash
cd /path/to/redmine
git -C plugins/cosmosys fetch
git -C plugins/cosmosys checkout <new-tag-or-sha>
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=cosmosys
# restart Redmine
```

Restart the web server after migrations so registered project profiles are
reconciled. Existing tracker assignments are retained.

Back up the database and validate the documented upgrade path before upgrading.
Follow release-specific migration instructions; returning to an earlier image
does not undo schema changes and may require restoring the matching backup.

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
