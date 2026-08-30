require 'date'
require 'digest'
require 'json'
require 'securerandom'
require 'stringio'
require 'tempfile'

module Cosmosys
  class OdsImportService
    FORMAT_VERSION = OdsExportService::FORMAT_VERSION
    MAX_ROWS = 10_000
    EMPTY_ROW_LIMIT = 10
    TECHNICAL_HEADERS = %w[row_uuid base_signature base_values].freeze
    ITEM_ID_HEADERS = %w[csid source_id].freeze
    ITEM_FIELDS = %w[
      project subject description tracker status parent blocking_items precedent_items
      related_items done_ratio estimated_hours assignee priority version category start_date due_date
    ].freeze
    DOCUMENT_FIELDS = %w[project title category external_code document_date document_version description].freeze
    CATALOG_FIELDS = %w[item family document sense location markdown_reference].freeze

    class ImportError < StandardError; end

    attr_reader :transfer, :project, :user

    def initialize(transfer, user: transfer.user)
      @transfer = transfer
      @project = transfer.project
      @user = user
    end

    def analyse!
      clear_events!
      transfer.update!(state: 'analysed')
      workbook_data = read_workbook
      validate_manifest!(workbook_data.fetch('manifest'))
      payload_sha256 = semantic_digest(workbook_data)
      transfer.update!(payload_sha256: payload_sha256, export_id: workbook_data.dig('manifest', 'export_id'), format_version: workbook_data.dig('manifest', 'format_version'))
      duplicate = Cosmosys::OdsTransfer.where(project_id: project.id, direction: 'import', state: 'applied', payload_sha256: payload_sha256).where.not(id: transfer.id).exists?
      event!('error', 'duplicate_payload', message: I18n.t(:error_cosmosys_ods_duplicate_payload)) if duplicate

      plan = build_plan(workbook_data)
      blocking = transfer.events.where(severity: 'error').exists?
      transfer.summary = plan.merge('blocking' => blocking, 'payload_sha256' => payload_sha256)
      transfer.state = blocking ? 'rejected' : 'awaiting_confirmation'
      transfer.save!
      transfer
    rescue StandardError => error
      event!('error', 'analysis_failed', message: error.message) unless transfer.events.where(code: 'analysis_failed').exists?
      transfer.update!(state: 'failed', summary: { 'blocking' => true, 'exception' => error.class.name })
      transfer
    end

    def apply!
      raise ImportError, 'Import is not awaiting confirmation' unless transfer.applicable?
      raise ImportError, 'The current user cannot edit this project' unless user.allowed_to?(:edit_project, project)

      current_data = read_workbook
      current_digest = semantic_digest(current_data)
      raise ImportError, 'Uploaded workbook changed after analysis' unless current_digest == transfer.payload_sha256

      transfer.update!(state: 'applying')
      result = { 'created_items' => 0, 'updated_items' => 0, 'created_documents' => 0, 'updated_documents' => 0, 'created_catalog_refs' => 0, 'updated_catalog_refs' => 0 }
      resolved_items = {}
      resolved_documents = {}
      provisional_markers = {}

      ActiveRecord::Base.transaction do
        apply_items!(current_data.fetch('items'), current_data.fetch('extra'), resolved_items, result)
        apply_item_hierarchy_and_relations!(current_data.fetch('items'), resolved_items)
        apply_documents!(current_data.fetch('documents'), resolved_documents, result)
        apply_catalog!(current_data.fetch('catalog'), resolved_items, resolved_documents, provisional_markers, result)
        replace_provisional_markers!(resolved_items.values.compact.uniq, provisional_markers)
      end

      reconciled = reconcile_workbook(current_data, resolved_items, resolved_documents, provisional_markers)
      transfer.summary = transfer.summary.merge(result).merge('provisional_markers' => provisional_markers)
      transfer.update!(state: 'applied', result_data: reconciled)
      transfer
    rescue StandardError => error
      event!('error', 'application_failed', message: error.message)
      transfer.update!(state: 'failed', summary: transfer.summary.merge('application_exception' => error.class.name))
      transfer
    end

    private

    def item_fields
      ITEM_FIELDS + Cosmosys::OdsItemFieldRegistry.names
    end

    def read_workbook
      with_workbook do |workbook|
        {
          'manifest' => read_manifest(workbook),
          'items' => read_controlled_rows(workbook, 'Items', 'ItemsCtrl', ITEM_ID_HEADERS + %w[subject], 'csid'),
          'extra' => read_rows(workbook, 'ExtraFields', ITEM_ID_HEADERS, required: false),
          'documents' => read_controlled_rows(workbook, 'Documents', 'DocumentsCtrl', %w[source_id redmine_id title], 'source_id'),
          'catalog' => read_controlled_rows(workbook, 'Catalog', 'CatalogCtrl', %w[item markdown_reference], 'markdown_reference')
        }
      end
    end

    def with_workbook
      OdsItems.load_rspreadsheet!
      Tempfile.create(['cosmosys-import', '.ods']) do |file|
        file.binmode
        file.write(transfer.file_data)
        file.flush
        yield ::Rspreadsheet.open(file.path)
      end
    end

    def read_manifest(workbook)
      sheet = workbook.worksheets('Cosmosys') || raise(ImportError, 'Missing Cosmosys manifest sheet')
      (1..64).each_with_object({}) do |row, values|
        key = sheet.cell(row, 1).value.to_s.strip
        values[key] = sheet.cell(row, 2).value.to_s if key.present?
      end
    end

    def read_rows(workbook, sheet_name, identity_headers, required: true)
      sheet = workbook.worksheets(sheet_name)
      raise ImportError, "Missing #{sheet_name} sheet" if required && sheet.nil?
      return [] unless sheet

      headers = (1..128).filter_map do |column|
        name = sheet.cell(1, column).value.to_s.strip
        [name, column] if name.present?
      end.to_h
      empty = 0
      rows = []
      (2..MAX_ROWS).each do |row_number|
        values = headers.to_h { |name, column| [name, normalize_cell(sheet.cell(row_number, column).value)] }
        present = identity_headers.any? { |header| values[header].present? }
        if !present
          empty += 1
          break if empty >= EMPTY_ROW_LIMIT
          next
        end
        empty = 0
        rows << values.merge('_sheet' => sheet_name, '_row' => row_number)
      end
      rows
    end

    def normalize_cell(value)
      value = value.to_i if value.is_a?(Float) && value.to_i == value
      value.nil? ? '' : value.to_s
    end

    def read_controlled_rows(workbook, sheet_name, control_name, identity_headers, visible_key)
      rows = read_rows(workbook, sheet_name, identity_headers)
      control = workbook.worksheets(control_name) || raise(ImportError, "Missing #{control_name} sheet")
      headers = sheet_headers(control)
      missing = OdsExportService::CONTROL_HEADERS - headers.keys
      raise ImportError, "#{control_name} lacks #{missing.join(', ')}" if missing.any?

      rows.each do |row|
        number = row.fetch('_row')
        visible_identity = row[visible_key].to_s
        control_identity = normalize_cell(control.cell(number, headers.fetch('row_key')).value)
        unless control_identity == visible_identity
          raise ImportError, "#{sheet_name} row #{number} no longer matches #{control_name}; rows must not be inserted, deleted or reordered"
        end
        OdsExportService::CONTROL_HEADERS.drop(1).each do |field|
          row[field] = normalize_cell(control.cell(number, headers.fetch(field)).value)
        end
      end
      rows
    end

    def validate_manifest!(manifest)
      event!('error', 'unsupported_format', message: "Unsupported ODS format #{manifest['format_version'].inspect}") unless manifest['format_version'] == FORMAT_VERSION
      event!('error', 'wrong_project', message: "Workbook belongs to #{manifest['project_identifier']}") unless manifest['project_identifier'] == project.identifier
      event!('error', 'wrong_project_tree', message: 'Workbook belongs to another project tree') unless manifest['project_root_id'].to_i == project.project_root.id
      event!('error', 'missing_export_id', message: 'Workbook has no export lineage') if manifest['export_id'].blank?
    end

    def semantic_digest(data)
      canonical = {
        'format_version' => data.dig('manifest', 'format_version'),
        'export_id' => data.dig('manifest', 'export_id'),
        'project' => data.dig('manifest', 'project_identifier'),
        'items' => semantic_rows(data.fetch('items'), item_fields + %w[csid row_uuid]),
        'extra' => semantic_rows(data.fetch('extra'), data.fetch('extra').flat_map(&:keys).uniq - %w[_sheet _row base_signature base_values]),
        'documents' => semantic_rows(data.fetch('documents'), DOCUMENT_FIELDS + %w[redmine_id source_id row_uuid]),
        'catalog' => semantic_rows(data.fetch('catalog'), CATALOG_FIELDS + %w[row_uuid])
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def semantic_rows(rows, fields)
      rows.map { |row| fields.to_h { |field| [field, row[field].to_s] } }
    end

    def build_plan(data)
      validate_duplicate_rows!(data)
      item_counts = inspect_rows(data.fetch('items'), 'Item') { |row| resolve_item(row) }
      document_counts = inspect_rows(data.fetch('documents'), 'Document') { |row| resolve_document(row) }
      inspect_catalog_rows(data.fetch('catalog'), data)
      {
        'items' => item_counts,
        'documents' => document_counts,
        'catalog_refs' => { 'rows' => data.fetch('catalog').length },
        'event_counts' => transfer.events.group(:severity).count
      }
    end

    def validate_duplicate_rows!(data)
      [['Items', data.fetch('items'), 'row_uuid'], ['Documents', data.fetch('documents'), 'row_uuid'], ['Catalog', data.fetch('catalog'), 'row_uuid']].each do |sheet, rows, field|
        duplicates = rows.map { |row| row[field] }.reject(&:blank?).tally.select { |_key, count| count > 1 }.keys
        duplicates.each { |key| event!('error', 'duplicate_row_identity', sheet: sheet, entity_key: key, message: "Duplicate row identity #{key}") }
      end
      duplicates = data.fetch('items').map { |row| row['csid'] }.reject(&:blank?).tally.select { |_key, count| count > 1 }.keys
      duplicates.each { |key| event!('error', 'duplicate_item_source', sheet: 'Items', entity_key: key, message: "Duplicate item identifier #{key}") }
    end

    def inspect_rows(rows, entity_type)
      counts = { 'create' => 0, 'update' => 0, 'unchanged' => 0 }
      rows.each do |row|
        entity = yield(row)
        if entity
          changes = conflicting_changes(entity_type, entity, row)
          counts[changes.empty? ? 'unchanged' : 'update'] += 1
        else
          counts['create'] += 1
          validate_new_row_identity!(row, entity_type)
        end
      end
      counts
    end

    def inspect_catalog_rows(rows, data)
      item_keys = data.fetch('items').map { |row| row['csid'] }
      document_keys = data.fetch('documents').flat_map { |row| [row['source_id'], row['redmine_id']] }.reject(&:blank?)
      rows.each do |row|
        event!('error', 'invalid_catalog_family', row_context(row).merge(message: "Invalid family #{row['family']}")) unless Cosmosys::DocumentCatalogEntry::FAMILIES.include?(row['family'])
        event!('error', 'unknown_catalog_item', row_context(row).merge(message: "Unknown item #{row['item']}")) unless item_keys.include?(row['item']) || resolve_item_by_key(row['item'])
        event!('error', 'unknown_catalog_document', row_context(row).merge(message: "Unknown document #{row['document']}")) unless document_keys.include?(row['document']) || resolve_document_by_key(row['document'])
      end
    end

    def conflicting_changes(entity_type, entity, row)
      fields = entity_type == 'Item' ? item_fields : DOCUMENT_FIELDS
      base = parse_base(row)
      current = entity_type == 'Item' ? current_item_values(entity) : current_document_values(entity)
      fields.each_with_object({}) do |field, changes|
        next unless row.key?(field)
        proposed = canonical_text(row[field])
        original = canonical_text(base[field])
        now = canonical_text(current[field])
        next if proposed == original
        if now != original && now != proposed
          event!('conflict', 'concurrent_field_change', row_context(row).merge(field_name: field, entity_type: entity_type, entity_key: entity_identifier(entity), message: "#{field} changed in Redmine and ODS", details: { 'base' => original, 'current' => now, 'proposed' => proposed }))
          next
        end
        changes[field] = proposed
      end
    end

    def validate_new_row_identity!(row, entity_type)
      if row['row_uuid'].blank?
        event!('error', 'missing_row_uuid', row_context(row).merge(entity_type: entity_type, message: 'New row has no stable UUID'))
      end
      if entity_type == 'Item' && row['csid'].blank?
        event!('error', 'uncalculated_formula', row_context(row).merge(field_name: 'csid', message: 'Items temporary identifier is empty; recalculate and save the workbook'))
      elsif entity_type == 'Document' && row['source_id'].blank?
        event!('error', 'uncalculated_formula', row_context(row).merge(field_name: 'source_id', message: 'Documents temporary identifier is empty; recalculate and save the workbook'))
      end
    end

    def apply_items!(rows, extra_rows, resolved, result)
      extras = extra_rows.index_by { |row| row['csid'] }
      rows.each do |row|
        issue = resolve_item(row)
        new_record = issue.nil?
        issue ||= Issue.new(project: row_project(row), author: user)
        # Items is authoritative when a template repeats a header in both sheets.
        # ExtraFields only enriches the visible item row; it must never replace a
        # populated Items value with an empty duplicate cell.
        apply_item_fields(issue, (extras[row['csid']] || {}).merge(row), new_record: new_record)
        issue.notify = false
        issue.save! if new_record || issue.changed?
        resolved[row['csid']] = issue
        record_identity!(row, 'Issue', issue.id) if new_record
        result[new_record ? 'created_items' : 'updated_items'] += 1
      end
    end

    def apply_item_fields(issue, row, new_record:)
      base = parse_base(row)
      current = current_item_values(issue)
      proposed = item_fields.to_h { |field| [field, canonical_text(row[field])] }
      allowed = safe_proposals(base, current, proposed, row, issue)
      issue.project = row_project(row) if new_record
      issue.tracker = tracker_for(allowed['tracker'].presence || row['tracker'], issue.project) if new_record || allowed.key?('tracker')
      issue.status ||= IssueStatus.sorted.first
      issue.priority ||= IssuePriority.default || IssuePriority.active.sorted.first
      issue.subject = normalized_text(allowed.fetch('subject', row['subject'].presence || row['csid']), row, 'subject') if new_record || allowed.key?('subject')
      issue.description = normalized_text(allowed.fetch('description', row['description']), row, 'description') if new_record || allowed.key?('description')
      assign_status(issue, allowed['status'], row) if allowed.key?('status')
      issue.priority = IssuePriority.active.find_by(name: allowed['priority']) if allowed.key?('priority')
      issue.done_ratio = allowed['done_ratio'].to_i if allowed.key?('done_ratio')
      issue.estimated_hours = allowed['estimated_hours'].presence if allowed.key?('estimated_hours')
      assign_assignee(issue, allowed['assignee'], row) if allowed.key?('assignee')
      issue.fixed_version = issue.project.versions.find_by(name: allowed['version']) if allowed.key?('version')
      issue.category = issue.project.issue_categories.find_by(name: allowed['category']) if allowed.key?('category')
      issue.start_date = parse_date(allowed['start_date']) if allowed.key?('start_date')
      issue.due_date = parse_date(allowed['due_date']) if allowed.key?('due_date')
      apply_custom_fields(issue, row)
      Cosmosys::OdsItemFieldRegistry.apply(issue, allowed)
    end

    def safe_proposals(base, current, proposed, row, entity)
      proposed.each_with_object({}) do |(field, value), safe|
        next if value == canonical_text(base[field]) && entity.persisted?
        if entity.persisted? && canonical_text(current[field]) != canonical_text(base[field]) && canonical_text(current[field]) != value
          next
        end
        safe[field] = value
      end
    end

    def assign_status(issue, name, row)
      status = IssueStatus.find_by(name: name)
      unless status
        event!('warning', 'unknown_status', row_context(row).merge(field_name: 'status', message: "Unknown status #{name}"))
        return
      end
      allowed = issue.new_record? ? [status] : issue.new_statuses_allowed_to(user)
      if issue.new_record? || allowed.include?(status) || issue.status == status
        issue.status = status
      else
        event!('warning', 'workflow_rejected', row_context(row).merge(field_name: 'status', entity_key: issue.csid, message: "Workflow rejected #{issue.status&.name} -> #{name}"))
      end
    end

    def assign_assignee(issue, login, row)
      if login.blank?
        issue.assigned_to = nil
        return
      end
      candidate = User.find_by(login: login)
      if candidate && issue.assignable_users.include?(candidate)
        issue.assigned_to = candidate
      else
        event!('warning', 'unknown_assignee', row_context(row).merge(field_name: 'assignee', message: "Assignee #{login} is not available; current assignment retained"))
      end
    end

    def apply_custom_fields(issue, row)
      fields = IssueCustomField.where(name: row.keys).index_by(&:name)
      return if fields.empty?
      values = fields.to_h { |name, field| [field.id, row[name]] }
      issue.custom_field_values = values
    end

    def apply_item_hierarchy_and_relations!(rows, resolved)
      rows.each do |row|
        issue = resolved.fetch(row['csid']).reload
        if row.key?('parent')
          parent = row['parent'].present? ? resolved[row['parent']] || resolve_item_by_key(row['parent']) : nil
          raise ImportError, "Unknown parent #{row['parent']}" if row['parent'].present? && parent.nil?
          # Redmine's parent_issue_id= stores a virtual @parent_issue and only
          # copies it to parent_id from its before_save callback. Therefore
          # changed? remains false until save runs and cannot guard this write.
          if issue.parent_id != parent&.id
            issue.parent_issue_id = parent&.id
            issue.save!
          end
        end
        reconcile_relations!(issue, row, resolved)
      end
    end

    def reconcile_relations!(issue, row, resolved)
      { 'blocking_items' => 'blocks', 'precedent_items' => 'precedes', 'related_items' => 'relates' }.each do |field, type|
        next unless row.key?(field)
        desired = split_references(row[field]).filter_map { |key| resolved[key] || resolve_item_by_key(key) }.map(&:id).uniq
        existing = issue.relations_to.select { |relation| relation.relation_type == type }
        existing.each { |relation| relation.destroy! unless desired.include?(relation.issue_from_id) }
        existing_ids = existing.map(&:issue_from_id)
        (desired - existing_ids).each { |from_id| IssueRelation.create!(issue_from_id: from_id, issue_to: issue, relation_type: type) }
      end
    end

    def apply_documents!(rows, resolved, result)
      rows.each do |row|
        document = resolve_document(row)
        new_record = document.nil?
        document ||= Document.new(project: row_project(row))
        base = parse_base(row)
        current = current_document_values(document)
        safe = safe_proposals(base, current, DOCUMENT_FIELDS.to_h { |field| [field, canonical_text(row[field])] }, row, document)
        document.title = normalized_text(safe.fetch('title', row['title']), row, 'title') if new_record || safe.key?('title')
        document.description = normalized_text(safe.fetch('description', row['description']), row, 'description') if new_record || safe.key?('description')
        document.external_code = safe['external_code'] if safe.key?('external_code')
        document.csys_document_version = safe['document_version'] if safe.key?('document_version')
        if safe.key?('document_date')
          document.csys_document_date = safe['document_date'].blank? ? nil : Date.iso8601(safe['document_date'].to_s)
        end
        if new_record || safe.key?('category')
          category = DocumentCategory.active.find_by(name: safe.fetch('category', row['category']))
          raise ImportError, "Unknown document category #{row['category']}" unless category
          document.category = category
        end
        document.save!
        resolved[row['source_id']] = document
        resolved[document.id.to_s] = document
        resolved["d#{document.id}"] = document
        record_identity!(row, 'Document', document.id) if new_record
        result[new_record ? 'created_documents' : 'updated_documents'] += 1
      end
    end

    def apply_catalog!(rows, items, documents, provisional, result)
      rows.each do |row|
        issue = items[row['item']] || resolve_item_by_key(row['item']) || raise(ImportError, "Unknown catalog item #{row['item']}")
        document = documents[row['document']] || resolve_document_by_key(row['document']) || raise(ImportError, "Unknown catalog document #{row['document']}")
        catalog_ref = resolve_catalog_ref(row)
        new_record = catalog_ref.nil?
        if catalog_ref && (catalog_ref.issue_id != issue.id || catalog_ref.document_id != document.id || catalog_ref.family != row['family'])
          raise ImportError, "Persistent catalog reference #{row['markdown_reference']} changed identity"
        end
        entry = Cosmosys::DocumentCatalogEntry.find_or_create_for!(document: document, family: row['family'])
        catalog_ref ||= Cosmosys::CatalogRef.new(issue: issue, document_catalog_entry: entry)
        catalog_ref.sense = normalized_text(row['sense'], row, 'sense')
        catalog_ref.location = normalized_text(row['location'], row, 'location')
        catalog_ref.save!
        if row['markdown_reference'].start_with?('document:dii')
          provisional[row['markdown_reference']] = catalog_ref.markdown_reference
        end
        record_identity!(row, 'Cosmosys::CatalogRef', catalog_ref.id) if new_record
        result[new_record ? 'created_catalog_refs' : 'updated_catalog_refs'] += 1
      end
    end

    def replace_provisional_markers!(issues, replacements)
      return if replacements.empty?
      issues.each do |issue|
        changed = false
        text = issue.description.to_s
        replacements.each do |source, target|
          replaced = text.gsub(source, target)
          changed ||= replaced != text
          text = replaced
        end
        next unless changed
        issue.description = text
        issue.save!
      end
    end

    def reconcile_workbook(data, items, documents, provisional)
      with_workbook do |workbook|
        item_replacements = items.transform_values(&:csid)
        document_replacements = documents.transform_values { |document| "d#{document.id}" }
        replace_sheet_values(workbook.worksheets('Items'), 'csid', item_replacements)
        replace_sheet_values(workbook.worksheets('ItemsCtrl'), 'row_key', item_replacements)
        replace_sheet_values(workbook.worksheets('Documents'), 'source_id', document_replacements)
        replace_sheet_values(workbook.worksheets('DocumentsCtrl'), 'row_key', document_replacements)
        sheet = workbook.worksheets('Catalog')
        headers = sheet_headers(sheet)
        (2..sheet.rowcount).each do |row|
          marker = sheet.cell(row, headers['markdown_reference']).value.to_s
          sheet.cell(row, headers['markdown_reference']).value = provisional[marker] if provisional.key?(marker)
        end
        replace_sheet_values(workbook.worksheets('CatalogCtrl'), 'row_key', provisional)
        Cosmosys::OdsProtectionService.apply!(workbook, project: project)
        output = StringIO.new(''.b)
        workbook.save(output)
        output.string
      end
    end

    def replace_sheet_values(sheet, header, mapping)
      headers = sheet_headers(sheet)
      column = headers[header]
      return unless column
      (2..sheet.rowcount).each do |row|
        value = sheet.cell(row, column).value.to_s
        replacement = mapping[value]
        sheet.cell(row, column).value = replacement if replacement.present?
      end
    end

    def resolve_item(row)
      identity_entity(row, 'Issue') || resolve_item_by_key(row['csid']) || (Issue.find_by(id: row['redmine_id']) if row['redmine_id'].present?)
    end

    def resolve_item_by_key(key)
      return if key.blank? || key.start_with?('n')
      Issue.where(project_id: project.project_root.self_and_descendants.select(:id)).find_by('LOWER(csid) = ?', key.downcase)
    end

    def resolve_document(row)
      identity_entity(row, 'Document') || resolve_document_by_key(row['source_id']) || (Document.find_by(id: row['redmine_id']) if row['redmine_id'].present?)
    end

    def resolve_document_by_key(key)
      id = key.to_s.sub(/\Ad/, '')
      return unless id.match?(/\A\d+\z/)
      Document.where(project_id: project.project_root.self_and_descendants.select(:id)).find_by(id: id)
    end

    def resolve_catalog_ref(row)
      identity_entity(row, 'Cosmosys::CatalogRef') || begin
        id = row['markdown_reference'].to_s[/\Adocument:di(\d+)\z/, 1]
        Cosmosys::CatalogRef.find_by(id: id) if id
      end
    end

    def identity_entity(row, entity_type)
      return if row['row_uuid'].blank?
      identity = Cosmosys::OdsImportIdentity.find_by(project_id: project.id, export_id: transfer.export_id, row_uuid: row['row_uuid'], entity_type: entity_type)
      entity_type.constantize.find_by(id: identity.entity_id) if identity
    end

    def record_identity!(row, entity_type, entity_id)
      return if row['row_uuid'].blank?
      Cosmosys::OdsImportIdentity.find_or_create_by!(project: project, export_id: transfer.export_id, row_uuid: row['row_uuid']) do |identity|
        identity.entity_type = entity_type
        identity.entity_id = entity_id
      end
    end

    def row_project(row)
      identifier = row['project'].presence || project.identifier
      candidate = project.project_root.self_and_descendants.find_by(identifier: identifier)
      raise ImportError, "Project #{identifier} is outside the import tree" unless candidate
      candidate
    end

    def tracker_for(name, target_project)
      tracker = Tracker.find_by(name: name)
      raise ImportError, "Unknown or unavailable tracker #{name}" unless tracker && target_project.trackers.exists?(tracker.id)
      tracker
    end

    def parse_base(row)
      JSON.parse(row['base_values'].presence || '{}')
    rescue JSON::ParserError
      {}
    end

    def current_item_values(issue)
      return {} unless issue.persisted?
      {
        'project' => issue.project.identifier, 'subject' => issue.subject, 'description' => issue.description,
        'tracker' => issue.tracker&.name, 'status' => issue.status&.name, 'parent' => issue.parent&.csid,
        'blocking_items' => relation_csids(issue, 'blocks'), 'precedent_items' => relation_csids(issue, 'precedes'),
        'related_items' => relation_csids(issue, 'relates'), 'done_ratio' => issue.done_ratio,
        'estimated_hours' => issue.estimated_hours, 'assignee' => issue.assigned_to&.login,
        'priority' => issue.priority&.name, 'version' => issue.fixed_version&.name,
        'category' => issue.category&.name, 'start_date' => issue.start_date, 'due_date' => issue.due_date
      }.merge(Cosmosys::OdsItemFieldRegistry.values_for(issue))
    end

    def current_document_values(document)
      return {} unless document.persisted?
      {
        'project' => document.project.identifier,
        'title' => document.title,
        'category' => document.category&.name,
        'external_code' => document.external_code,
        'document_date' => document.csys_document_date,
        'document_version' => document.csys_document_version,
        'description' => document.description
      }
    end

    def relation_csids(issue, type)
      issue.relations_to.select { |relation| relation.relation_type == type }.filter_map { |relation| relation.issue_from&.csid }.sort.join(',')
    end

    def split_references(value)
      value.to_s.split(',').map(&:strip).reject(&:blank?)
    end

    def normalized_text(value, row, field)
      result = OdsTextNormalizer.call(value)
      result.repairs.each { |repair| event!('info', "text_#{repair}", row_context(row).merge(field_name: field, message: "Normalised #{repair} in #{field}")) }
      result.text
    end

    def canonical_text(value)
      OdsTextNormalizer.call(value).text
    end

    def parse_date(value)
      value.present? ? Date.parse(value.to_s) : nil
    rescue Date::Error
      nil
    end

    def entity_identifier(entity)
      entity.respond_to?(:csid) ? entity.csid : entity.id.to_s
    end

    def row_context(row)
      { sheet: row['_sheet'], row_number: row['_row'] }
    end

    def event!(severity, code, attributes = {})
      details = attributes.delete(:details)
      transfer.events.create!({ severity: severity, code: code, message: code }.merge(attributes).merge(details: details || {}))
    end

    def clear_events!
      transfer.events.delete_all
    end

    def sheet_headers(sheet)
      (1..128).filter_map do |column|
        name = sheet.cell(1, column).value.to_s.strip
        [name, column] if name.present?
      end.to_h
    end
  end
end
