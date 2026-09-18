# cosmoSys

Base plugin for [Redmine](https://www.redmine.org), providing a shared
engineering model on which domain extensions are built.

cosmoSys turns Redmine into a workspace where tasks, requirements, documents
and their relations form a live model of the project. Teams can navigate that
model as a tree, analyse it through diagrams and matrices, and turn it into
professional documentation without leaving the shared workspace. It is free,
open source, and has no per-seat limits.

Domain extensions such as [cosmoSys-Req](https://github.com/cosmoBots/cosmoSys_Req)
add specialised capabilities on top of this base.

## Project history

This is not a new project created by this repository. It is a refactoring and
continuation of the earlier
[`cosmosys_rm`](https://github.com/cosmoBots/cosmosys_rm) Redmine plugin.
That line of development runs from its first commit on 28 November 2020
through the current 2026 refactoring. The repository history was deliberately
restarted to publish a clean software artifact; this does not erase or replace
the project's earlier history and authorship.

## Status

This repository contains an early alpha artifact. It is suitable for controlled
evaluation and is not yet declared production-ready. You can install it and try
it, but expect breaking changes.

## Requirements

cosmoSys requires a working [Redmine](https://www.redmine.org) installation.
It is developed and validated against **Redmine 7.0.1** (Rails 8). Earlier
major versions are not supported. It is licensed under GPLv3 by cosmoBots.eu.

In addition to the normal Redmine runtime, cosmoSys needs:

- **System packages**: `graphviz` (diagrams), `librsvg2-bin` and
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
   cosmoSys' gems must be available to the Redmine bundle, so run from the
   Redmine root:

   ```bash
   bundle install
   ```

   If Bundler cannot read this plugin's `Gemfile` (for example because it uses
   the `RSPREADSHEET_PATH` form), install the gems explicitly in the Redmine
   environment:

   ```bash
   gem install andand rubyzip libxml-ruby
   ```

4. **Run the plugin migrations.** cosmoSys extends the Redmine schema with its
   own tables and columns. From the Redmine root:

   ```bash
   RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=cosmosys
   ```

   For a development or test environment, set `RAILS_ENV=development` (or
   `test`) accordingly. The migration base is sealed from `001` to `008` for
   the current release line; an upgrade from an earlier release migrates `001`
   through the latest sealed number.

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

### Upgrading an existing installation

To update cosmoSys in place:

```bash
cd /path/to/redmine
git -C plugins/cosmosys fetch
git -C plugins/cosmosys checkout <new-tag-or-sha>
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=cosmosys
# restart Redmine
```

The migration base is developed fast and the project is still in alpha: the
schema is not yet backward-compatible by design, so back up the database
before upgrading.

### Deployment with Docker Compose (optional)

If you prefer a packaged, reproducible deployment instead of installing into
an existing Redmine, a sister project provides a Docker Compose stack (Redmine
+ cosmoSys, and a variant with cosmoSys-Req) with pinned plugin revisions,
health checks, backups and restore scripts. It is currently being published at
<https://github.com/cosmoBots/cosmoSys_deploy> and should be available there
shortly.

## Repository

The canonical repository for this project is
[github.com/cosmoBots/cosmoSys](https://github.com/cosmoBots/cosmoSys).
Forks and mirrors are welcome under the terms of the GPLv3, but they are not
maintained by cosmoBots.eu and may diverge from this source.

## Contact and licence

- Contact: txinto@elporis.com
- Licence: GNU General Public License version 3; see [`LICENSE`](LICENSE).
