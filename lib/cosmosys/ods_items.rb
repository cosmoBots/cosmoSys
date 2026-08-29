require 'yaml'
require 'fileutils'
require 'date'
require 'pathname'
require 'set'
require 'active_support/core_ext/object/blank'

module Cosmosys
  module OdsItems
    HEADERS = %w[
      rm_number link redmine_id source_id row_number subject description tracker
      relevant status parent blocking_items precedent_items poris_min poris_default
      poris_max poris_default_text version priority
    ].freeze
    SOURCE_TRACKER_NAMES = {
      'csinfo' => 'csInfo',
      'csrefdoc' => 'csRefDoc',
      'csdocref' => 'csRefDoc'
    }.freeze

    def self.load_rspreadsheet!
      require 'rspreadsheet'
    end

    class Reader
      MAX_ROWS = 10_000
      EMPTY_ID_LIMIT = 10

      def initialize(path, sheet_name: 'Items')
        @path = Pathname(path)
        @sheet_name = sheet_name
      end

      def read
        OdsItems.load_rspreadsheet!
        workbook = ::Rspreadsheet.open(@path.to_s)
        sheet = workbook.worksheets(@sheet_name) || raise("ODS sheet #{@sheet_name.inspect} not found")
        validate_headers!(sheet)
        items = []
        empty_ids = 0
        (2..MAX_ROWS).each do |row_index|
          values = HEADERS.each_index.map { |column_index| cell_value(sheet, row_index, column_index + 1) }
          source_id = text(values[3])
          if source_id.blank?
            empty_ids += 1
            break if empty_ids >= EMPTY_ID_LIMIT
            next
          end

          empty_ids = 0
          item = HEADERS.zip(values).to_h
          item['source_id'] = source_id
          item['parent'] = text(item['parent'])
          item['tracker'] = normalize_tracker(item['tracker'])
          item['blocking_items'] = references(item['blocking_items'])
          item['precedent_items'] = references(item['precedent_items'])
          item['source_row'] = row_index
          items << item.compact
        end
        raise "No items found in #{@path}" if items.empty?

        {
          'format' => 'cosmosys-items-v1',
          'source' => @path.basename.to_s,
          'source_sheet' => @sheet_name,
          'items' => items
        }
      end

      private

      def validate_headers!(sheet)
        actual = HEADERS.each_index.map { |index| cell_value(sheet, 1, index + 1).to_s }
        expected = ['RM#', 'link', 'RMID', 'ID', 'row#', 'subject', 'description', 'tracker', 'Rlv?', 'status', 'parent', 'blocking_items', 'precedent_items', 'prMin', 'prDefault', 'prMax', 'prDefaultText', 'version', 'priority']
        return if actual == expected

        raise "Unexpected Items columns: #{actual.inspect}"
      end

      def cell_value(sheet, row, column)
        value = sheet.cell(row, column).value
        value.is_a?(Float) && value.to_i == value ? value.to_i : value
      rescue RuntimeError => error
        raise "Cannot read #{@sheet_name}!R#{row}C#{column}: #{error.message}"
      end

      def normalize_tracker(value)
        tracker = text(value)
        SOURCE_TRACKER_NAMES.fetch(tracker.downcase, 'csRq')
      end

      def references(value)
        text(value).split(',').map(&:strip).reject(&:blank?)
      end

      def text(value)
        value.to_s.strip
      end
    end

    class FixtureWriter
      def initialize(source_path:, yaml_path:, normalized_ods_path:)
        @source_path = Pathname(source_path)
        @yaml_path = Pathname(yaml_path)
        @normalized_ods_path = Pathname(normalized_ods_path)
      end

      def write!
        payload = Reader.new(@source_path).read
        FileUtils.mkdir_p(@yaml_path.dirname)
        File.write(@yaml_path, YAML.dump(payload))
        write_normalized_ods!(payload.fetch('items'))
        payload
      end

      private

      def write_normalized_ods!(items)
        OdsItems.load_rspreadsheet!
        FileUtils.mkdir_p(@normalized_ods_path.dirname)
        workbook = ::Rspreadsheet.open(@source_path.to_s)
        sheet = workbook.worksheets('Items') || raise('ODS sheet "Items" not found')
        items.each { |item| sheet.cell(item.fetch('source_row'), 8).value = item.fetch('tracker') }
        workbook.save(@normalized_ods_path.to_s)
      end
    end

    class ProjectImporter
      attr_reader :project

      def initialize(project:, fixture_path:, author:)
        @project = project
        @fixture_path = Pathname(fixture_path)
        @author = author
      end

      def import!
        payload = YAML.safe_load_file(@fixture_path, permitted_classes: [Date, Time], aliases: false)
        items = payload.fetch('items')
        dangling_references = validate_references!(items)
        tracker_map = tracker_map!
        status = IssueStatus.order(:position, :id).first || raise('No item status available')
        priority = IssuePriority.default || IssuePriority.active.order(:position, :id).first
        imported = {}

        Project.transaction do
          pending = items.dup
          until pending.empty?
            ready, pending = pending.partition { |item| item.fetch('parent', '').blank? || imported.key?(item.fetch('parent')) }
            raise "Unresolvable parent cycle: #{pending.map { |item| item.fetch('source_id') }.join(', ')}" if ready.empty?

            ready.each do |item|
              issue = Issue.new(
                project: project,
                tracker: tracker_map.fetch(item.fetch('tracker')),
                status: status,
                priority: priority,
                author: @author,
                subject: item.fetch('subject').to_s.presence || item.fetch('source_id'),
                description: item.fetch('description', '').to_s,
                parent_issue_id: imported[item.fetch('parent', '')]&.id
              )
              issue.notify = false
              issue.save!
              imported[item.fetch('source_id')] = issue
            end
          end

          create_relations!(items, imported)
        end

        {
          project: project.reload,
          items: imported,
          relation_count: relation_count(imported.values),
          dangling_references: dangling_references
        }
      end

      private

      def tracker_map!
        trackers = {
          'normal' => Tracker.where(csys_item_kind: 'normal').order(:position, :id).first,
          'csInfo' => Tracker.find_by(csys_key: 'cs_info'),
          'csRefDoc' => Tracker.find_by(csys_key: 'cs_ref_doc'),
          'csRq' => Tracker.find_by(csys_key: 'requirement')
        }
        missing = trackers.select { |_name, tracker| tracker.nil? }.keys
        raise "Missing fixture trackers: #{missing.join(', ')}" if missing.any?

        project.trackers = (project.trackers.to_a | trackers.values)
        trackers
      end

      def validate_references!(items)
        ids = items.map { |item| item.fetch('source_id') }
        duplicates = ids.tally.select { |_id, count| count > 1 }.keys
        raise "Duplicate source IDs: #{duplicates.join(', ')}" if duplicates.any?

        missing_parents = items.map { |item| item.fetch('parent', '') }.reject(&:blank?).uniq - ids
        raise "Unknown parent references: #{missing_parents.join(', ')}" if missing_parents.any?

        relation_references = items.flat_map do |item|
          [*item.fetch('blocking_items', []), *item.fetch('precedent_items', [])]
        end.reject(&:blank?).uniq
        relation_references - ids
      end

      def create_relations!(items, imported)
        seen = Set.new
        items.each do |item|
          current = imported.fetch(item.fetch('source_id'))
          item.fetch('blocking_items', []).each do |source_id|
            create_relation!(imported[source_id], current, 'blocks', seen)
          end
          item.fetch('precedent_items', []).each do |source_id|
            create_relation!(imported[source_id], current, 'precedes', seen)
          end
        end
      end

      def create_relation!(from, to, type, seen)
        return if from.nil? || to.nil?

        key = [from.id, to.id, type]
        return unless seen.add?(key)

        IssueRelation.create!(issue_from: from, issue_to: to, relation_type: type)
      end

      def relation_count(issues)
        ids = issues.map(&:id)
        IssueRelation.where(issue_from_id: ids).or(IssueRelation.where(issue_to_id: ids)).count
      end
    end
  end
end
