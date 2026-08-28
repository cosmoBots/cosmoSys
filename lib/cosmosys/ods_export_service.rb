require 'stringio'
require 'digest'
require 'json'
require 'securerandom'

module Cosmosys
  class OdsExportService
    Result = Struct.new(:data, :filename, :content_type, :export_id, :payload_sha256, :summary, keyword_init: true)
    CONTENT_TYPE = 'application/vnd.oasis.opendocument.spreadsheet'.freeze
    FORMAT_VERSION = 'cosmosys-ods-v3'.freeze
    CONTROL_HEADERS = %w[row_key row_uuid base_signature base_values].freeze
    HEADER_SCAN_LIMIT = 128
    WRITERS = %w[rows indexed].freeze
    DEFAULT_WRITER = 'rows'.freeze

    class ExportError < StandardError; end

    attr_reader :project, :user

    def initialize(project, user:, base_url:, template_path: nil, include_subprojects: false, progress: nil, writer: DEFAULT_WRITER)
      @project = project
      @user = user
      @base_url = base_url.to_s.sub(%r{/+\z}, '')
      @include_subprojects = include_subprojects
      @progress = progress
      @writer = writer.to_s.presence || DEFAULT_WRITER
      raise ExportError, "Unknown ODS writer: #{@writer}" unless WRITERS.include?(@writer)
      @template_resolution = project.cosmosys_effective_ods_template unless template_path
      configured_path = Pathname(template_path || @template_resolution.path)
      @template_path = configured_path.absolute? ? configured_path : Rails.root.join(configured_path)
    end

    def call
      raise ExportError, "ODS export template not found: #{@template_path}" unless @template_path.file?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      report_progress(2, 'opening', 'writer' => @writer)
      OdsItems.load_rspreadsheet!
      workbook = trace_phase('ods_export.open', 6, 'opening') { ::Rspreadsheet.open(@template_path.to_s) }
      @row_writer = Cosmosys::OdsRowWriter.new if @writer == 'rows'
      items_sheet = workbook.worksheets('Items') || raise(ExportError, 'ODS template has no Items sheet')
      extra_sheet = workbook.worksheets('ExtraFields') || raise(ExportError, 'ODS template has no ExtraFields sheet')
      dictionary = workbook.worksheets('Dict') || raise(ExportError, 'ODS template has no Dict sheet')
      documents_sheet = workbook.worksheets('Documents') || raise(ExportError, 'ODS template has no Documents sheet')
      catalog_sheet = workbook.worksheets('Catalog') || raise(ExportError, 'ODS template has no Catalog sheet')
      controls = {
        'items' => workbook.worksheets('ItemsCtrl') || raise(ExportError, 'ODS template has no ItemsCtrl sheet'),
        'documents' => workbook.worksheets('DocumentsCtrl') || raise(ExportError, 'ODS template has no DocumentsCtrl sheet'),
        'catalog' => workbook.worksheets('CatalogCtrl') || raise(ExportError, 'ODS template has no CatalogCtrl sheet')
      }
      manifest_sheet = workbook.worksheets('Cosmosys') || workbook.add_worksheet('Cosmosys')

      @export_id = SecureRandom.uuid
      @exported_at = Time.current.utc

      sections = trace_phase('ods_export.collect', 12, 'collecting') do
        export_projects.flat_map { |scope_project| MainReportService.new(scope_project, user: user).outline }
      end
      chapter_by_issue_id = sections.to_h { |section| [section.issue.id, section.chapter] }
      issues = sections.map(&:issue)

      trace_phase('ods_export.dictionary', 16, 'dictionary') { populate_dictionary(dictionary) }
      locations = template_field_locations(items_sheet, extra_sheet)
      trace_phase('ods_export.preload', 20, 'preloading') do
        prepare_issue_export_data(issues, include_last_notes: locations.key?('last_notes'))
      end
      Cosmosys::PerformanceTrace.measure('ods_export.items', project_id: project.id, rows: issues.length, writer: @writer) do
        issues.each_with_index do |issue, index|
          write_issue(
            issue,
            row: index + 2,
            sheets: { 'items' => items_sheet, 'extra' => extra_sheet },
            locations: locations,
            chapter: chapter_by_issue_id[issue.id]
          )
          write_control_row(controls['items'], index + 2, issue.csid, @issue_control_values)
          report_progress(20 + (((index + 1).to_f / [issues.length, 1].max) * 45).floor, 'items')
        end
      end
      trace_phase('ods_export.documents', 69, 'documents') { populate_documents(documents_sheet) }
      trace_phase('ods_export.catalog', 73, 'catalog') { populate_catalog(catalog_sheet) }
      payload_sha256 = nil
      trace_phase('ods_export.controls', 82, 'controls') do
        write_control_rows(controls['documents'], @document_rows, key: 'source_id')
        write_control_rows(controls['catalog'], @catalog_rows, key: 'markdown_reference')
        populate_unused_control_rows(controls['items'], visible_sheet: 'Items', visible_column: 'D', start_row: issues.length + 2)
        populate_unused_control_rows(controls['documents'], visible_sheet: 'Documents', visible_column: 'B', start_row: @document_rows.length + 2)
        populate_unused_control_rows(controls['catalog'], visible_sheet: 'Catalog', visible_column: 'F', start_row: @catalog_rows.length + 2)
        payload_sha256 = payload_sha256_for(issues)
        populate_manifest(manifest_sheet, payload_sha256: payload_sha256)
      end
      trace_phase('ods_export.protection', 86, 'protecting') { Cosmosys::OdsProtectionService.apply!(workbook, project: project) }

      output = StringIO.new(''.b)
      trace_phase('ods_export.serialize', 96, 'serializing') { workbook.save(output) }
      duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      Result.new(
        data: output.string,
        filename: "#{safe_filename(project.identifier)}#{@include_subprojects ? '-tree' : ''}-items-#{@exported_at.strftime('%Y%m%dT%H%M%SZ')}.ods",
        content_type: CONTENT_TYPE,
        export_id: @export_id,
        payload_sha256: payload_sha256,
        summary: {
          'items' => issues.length,
          'documents' => @document_rows.length,
          'catalog_refs' => @catalog_rows.length,
          'include_subprojects' => @include_subprojects,
          'writer' => @writer,
          'duration_seconds' => duration_seconds.round(3)
        }
      )
    rescue ExportError
      raise
    rescue StandardError => error
      Rails.logger.error("cosmoSys ODS export failed: #{error.class}: #{error.message}")
      raise ExportError, error.message
    end

    private

    def report_progress(percent, phase, details = {})
      @progress&.call(percent, phase, details)
    end

    def trace_phase(event, percent, phase, &block)
      report_progress([percent - 3, 0].max, phase)
      result = Cosmosys::PerformanceTrace.measure(event, project_id: project.id, writer: @writer, &block)
      report_progress(percent, phase)
      result
    end

    def writable_cell(sheet, row, column)
      @row_writer ? @row_writer.cell(sheet, row, column) : sheet.cell(row, column)
    end

    def export_projects
      @export_projects ||= begin
        candidates = @include_subprojects ? project.self_and_descendants.order(:lft, :id) : [project]
        candidates.select { |candidate| candidate.visible?(user) }
      end
    end

    def populate_dictionary(sheet)
      writable_cell(sheet, 2, 2).value = @base_url
      writable_cell(sheet, 3, 2).value = nil
      writable_cell(sheet, 4, 2).value = project.identifier
      writable_cell(sheet, 5, 2).value = project.cscode

      project_ids = export_projects.map(&:id)
      write_dictionary_column(sheet, 5, Member.where(project_id: project_ids).includes(:principal).filter_map { |member| member.principal&.login })
      write_dictionary_column(sheet, 6, Version.where(project_id: project_ids).map(&:name))
      write_dictionary_column(sheet, 7, export_projects.flat_map { |scope_project| scope_project.trackers.sorted.map(&:name) })
      write_dictionary_column(sheet, 8, IssueStatus.sorted.map(&:name))
      write_dictionary_column(sheet, 9, IssuePriority.active.sorted.map(&:name))
      write_dictionary_column(sheet, 10, IssueCategory.where(project_id: project_ids).map(&:name))
    end

    def write_dictionary_column(sheet, column, values)
      (2..sheet.rowcount).each do |row|
        cell = sheet.cell(row, column)
        writable_cell(sheet, row, column).value = nil if cell.formula.blank? && cell.value.present?
      end
      Array(values).uniq.each_with_index do |value, index|
        cell = sheet.cell(index + 2, column)
        writable_cell(sheet, index + 2, column).value = value unless cell.value == value
      end
    end

    def template_field_locations(items_sheet, extra_sheet)
      locations = {}
      { 'items' => items_sheet, 'extra' => extra_sheet }.each do |sheet_key, sheet|
        (1..HEADER_SCAN_LIMIT).each do |column|
          header = sheet.cell(1, column).value.to_s.strip
          next if header.blank? || locations.key?(header)

          locations[header] = { sheet: sheet_key, column: column }
        end
      end
      locations
    end

    def write_issue(issue, row:, sheets:, locations:, chapter:)
      values = native_values(issue, chapter: chapter).merge(Cosmosys::OdsItemFieldRegistry.values_for(issue))
      values['last_notes'] = @last_notes_by_issue[issue.id] if locations.key?('last_notes')
      values['row_uuid'] = SecureRandom.uuid
      importable_values = importable_issue_values(issue)
      (@importable_values_by_issue_id ||= {})[issue.id] = importable_values
      values['base_values'] = JSON.generate(importable_values)
      values['base_signature'] = Digest::SHA256.hexdigest(values['base_values'])
      @issue_control_values = values.slice(*CONTROL_HEADERS.drop(1))
      custom_values = issue.visible_custom_field_values(user).index_by { |entry| entry.custom_field.name }
      locations.each do |header, location|
        sheet = sheets.fetch(location.fetch(:sheet))
        cell = writable_cell(sheet, row, location.fetch(:column))
        next if cell.formula && !values.key?(header)

        value = if values.key?(header)
                  values[header]
                elsif (custom_value = custom_values[header])
                  custom_field_value(custom_value)
                end
        desired_value = blank_value?(value) ? nil : value
        cell.value = desired_value unless cell.value == desired_value
      end
    end

    def populate_documents(sheet)
      documents = Document.where(project_id: export_projects.map(&:id)).includes(:project, :category).order(:project_id, :category_id, :title, :id).select { |document| document.visible?(user) }
      @document_rows = documents.map do |document|
        {
          'redmine_id' => document.id,
          'source_id' => "d#{document.id}",
          'project' => document.project.identifier,
          'title' => document.title,
          'category' => document.category&.name,
          'external_code' => document.external_code,
          'document_date' => document.cosmosys_document_date,
          'document_version' => document.cosmosys_document_version,
          'description' => document.description,
          'row_uuid' => SecureRandom.uuid,
          'base_values' => JSON.generate(importable_document_values(document))
        }
      end
      @document_rows.each { |row| row['base_signature'] = Digest::SHA256.hexdigest(row.fetch('base_values')) }
      write_tabular_rows(sheet, @document_rows)
    end

    def populate_catalog(sheet)
      references = Cosmosys::CatalogRef
                   .joins(:document_catalog_entry)
                   .where(cosmosys_document_catalog_entries: { project_id: export_projects.map(&:id) })
                   .includes(:issue, document_catalog_entry: :document)
                   .order(:id)
                   .select { |catalog_ref| catalog_ref.visible?(user) }
      @catalog_rows = references.map do |catalog_ref|
        {
          'item' => catalog_ref.issue.csid,
          'family' => catalog_ref.family,
          'document' => "d#{catalog_ref.document_id}",
          'sense' => catalog_ref.sense,
          'location' => catalog_ref.location,
          'markdown_reference' => catalog_ref.markdown_reference,
          'row_uuid' => SecureRandom.uuid,
          'base_values' => JSON.generate(importable_catalog_values(catalog_ref))
        }
      end
      @catalog_rows.each { |row| row['base_signature'] = Digest::SHA256.hexdigest(row.fetch('base_values')) }
      write_tabular_rows(sheet, @catalog_rows)
    end

    def write_tabular_rows(sheet, rows)
      headers = (1..HEADER_SCAN_LIMIT).to_h do |column|
        [sheet.cell(1, column).value.to_s.strip, column]
      end.reject { |header, _column| header.blank? }

      rows.each_with_index do |values, index|
        row = index + 2
        headers.each do |header, column|
          cell = writable_cell(sheet, row, column)
          next if cell.formula && !values.key?(header)

          value = values[header]
          desired_value = blank_value?(value) ? nil : value
          cell.value = desired_value unless cell.value == desired_value
        end
      end
    end

    def write_control_rows(sheet, rows, key:)
      rows.each_with_index { |values, index| write_control_row(sheet, index + 2, values.fetch(key), values) }
    end

    def write_control_row(sheet, row, row_key, values)
      headers = sheet_headers(sheet)
      { 'row_key' => row_key }.merge(values.slice(*CONTROL_HEADERS.drop(1))).each do |name, value|
        writable_cell(sheet, row, headers.fetch(name)).value = value
      end
    end

    def native_values(issue, chapter:)
      {
        'redmine_id' => issue.id,
        'csid' => issue.csid,
        'project' => issue.project.identifier,
        'chapter' => chapter,
        'subject' => issue.subject,
        'description' => issue.description,
        'tracker' => issue.tracker&.name,
        'status' => issue.status&.name,
        'parent' => issue.parent&.csid,
        'precedent_items' => incoming_relation_csids(issue, 'precedes'),
        'blocking_items' => incoming_relation_csids(issue, 'blocks'),
        'related_items' => incoming_relation_csids(issue, 'relates'),
        'done_ratio' => issue.done_ratio,
        'estimated_hours' => issue.estimated_hours,
        'assignee' => issue.assigned_to&.login,
        'author' => issue.author&.login,
        'priority' => issue.priority&.name,
        'version' => issue.fixed_version&.name,
        'category' => issue.category&.name,
        'start_date' => issue.start_date,
        'due_date' => issue.due_date
      }
    end

    def importable_issue_values(issue)
      native_values(issue, chapter: nil).merge(Cosmosys::OdsItemFieldRegistry.values_for(issue)).slice(
        'project', 'subject', 'description', 'tracker', 'status', 'parent',
        'precedent_items', 'blocking_items', 'related_items', 'done_ratio',
        'estimated_hours', 'assignee', 'priority', 'version', 'category',
        'start_date', 'due_date', *Cosmosys::OdsItemFieldRegistry.names
      ).transform_values { |value| canonical_value(value) }
    end

    def importable_document_values(document)
      {
        'project' => document.project.identifier,
        'title' => document.title,
        'category' => document.category&.name,
        'external_code' => document.external_code,
        'document_date' => document.cosmosys_document_date,
        'document_version' => document.cosmosys_document_version,
        'description' => document.description
      }.transform_values { |value| canonical_value(value) }
    end

    def importable_catalog_values(catalog_ref)
      {
        'item' => catalog_ref.issue.csid,
        'family' => catalog_ref.family,
        'document' => "d#{catalog_ref.document_id}",
        'sense' => catalog_ref.sense,
        'location' => catalog_ref.location,
        'markdown_reference' => catalog_ref.markdown_reference
      }.transform_values { |value| canonical_value(value) }
    end

    def populate_unused_control_rows(sheet, visible_sheet:, visible_column:, start_row:)
      headers = sheet_headers(sheet)
      last_row = start_row + 149
      (start_row..last_row).each do |row|
        key_cell = writable_cell(sheet, row, headers.fetch('row_key'))
        key_cell.value = nil if key_cell.value.present?
        expected_formula = %(=IF(LEN([$#{visible_sheet}.#{visible_column}#{row}])>0;[$#{visible_sheet}.#{visible_column}#{row}];""))
        key_cell.formula = expected_formula unless key_cell.formula == expected_formula
        uuid_cell = writable_cell(sheet, row, headers.fetch('row_uuid'))
        uuid_cell.value = SecureRandom.uuid if uuid_cell.value.blank?
      end
    end

    def populate_manifest(sheet, payload_sha256:)
      values = {
        'format_version' => FORMAT_VERSION,
        'export_id' => @export_id,
        'project_identifier' => project.identifier,
        'project_root_id' => project.project_root.id,
        'exported_at' => @exported_at.iso8601(6),
        'exported_by_id' => user.id,
        'include_subprojects' => @include_subprojects ? '1' : '0',
        'project_profile' => project.cosmosys_project_profile_definition.key,
        'template' => @template_resolution&.identifier || @template_path.to_s,
        'payload_sha256' => payload_sha256
      }
      values.each_with_index do |(key, value), index|
        writable_cell(sheet, index + 1, 1).value = key
        writable_cell(sheet, index + 1, 2).value = value
      end
    end

    def payload_sha256_for(issues)
      payload = {
        'format_version' => FORMAT_VERSION,
        'export_id' => @export_id,
        'project' => project.identifier,
        'items' => issues.map { |issue| [issue.csid, @importable_values_by_issue_id.fetch(issue.id)] },
        'documents' => @document_rows.map { |row| row.except('row_uuid', 'base_signature') },
        'catalog' => @catalog_rows.map { |row| row.except('row_uuid', 'base_signature') }
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def sheet_headers(sheet)
      (1..HEADER_SCAN_LIMIT).to_h do |column|
        [sheet.cell(1, column).value.to_s.strip, column]
      end.reject { |header, _column| header.blank? }
    end

    def canonical_value(value)
      case value
      when Date, Time, DateTime then value.iso8601
      else value.to_s.unicode_normalize(:nfc).gsub(/\r\n?/, "\n")
      end
    end

    def incoming_relation_csids(issue, relation_type)
      @incoming_relation_csids.dig(issue.id, relation_type).to_a.join(',')
    end

    def prepare_issue_export_data(issues, include_last_notes:)
      ActiveRecord::Associations::Preloader.new(
        records: issues,
        associations: [:status, :priority, :author, :assigned_to, :fixed_version, :category, :custom_values]
      ).call
      ids = issues.map(&:id)
      @incoming_relation_csids = Hash.new { |hash, issue_id| hash[issue_id] = {} }
      IssueRelation.where(issue_to_id: ids, relation_type: %w[blocks precedes relates]).includes(issue_from: :project).find_each do |relation|
        source = relation.issue_from
        next unless source&.visible?(user)

        (@incoming_relation_csids[relation.issue_to_id][relation.relation_type] ||= []) << source.csid
      end
      @last_notes_by_issue = if include_last_notes
                               Journal.where(journalized_type: 'Issue', journalized_id: ids)
                                      .where.not(notes: [nil, ''])
                                      .order(:id)
                                      .pluck(:journalized_id, :notes)
                                      .to_h
                             else
                               {}
                             end
    end

    def custom_field_value(custom_value)
      custom_field = custom_value.custom_field
      value = custom_value.value
      values = value.is_a?(Array) ? value : [value]
      values.filter_map do |entry|
        next if entry.blank?
        next User.find_by(id: entry.to_i)&.login if custom_field.field_format == 'user'

        entry
      end.join(',')
    end

    def blank_value?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def safe_filename(value)
      value.to_s.gsub(/[^0-9A-Za-z._-]+/, '_').gsub(/\A_+|_+\z/, '').presence || 'cosmosys'
    end
  end
end
