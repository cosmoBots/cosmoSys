require_dependency 'issue_query'

module Cosmosys
  module IssueQueryPatch
    POSITIVE_FILTER = 'cosmosys_positive'.freeze

    def self.prepended(base)
      column = QueryColumn.new(
        :csid,
        sortable: "#{Issue.table_name}.csid",
        caption: :label_cosmosys_csid,
        frozen: true
      )

      unless base.available_columns.any? { |available_column| available_column.name == :csid }
        id_index = base.available_columns.find_index { |available_column| available_column.name == :id }
        insert_at = id_index ? id_index + 1 : base.available_columns.length
        base.available_columns.insert(insert_at, column)
      end

      chapter_column = QueryColumn.new(
        :chapter_label,
        sortable: -> { Cosmosys::ChapterSort.sql },
        caption: :label_cosmosys_chapter
      )
      unless base.available_columns.any? { |available_column| available_column.name == :chapter_label }
        csid_index = base.available_columns.find_index { |available_column| available_column.name == :csid }
        base.available_columns.insert(csid_index ? csid_index + 1 : base.available_columns.length, chapter_column)
      end
    end

    def initialize_available_filters
      super
      add_available_filter('csid', type: :string, name: :label_cosmosys_csid) unless available_filters.key?('csid')
      if IssueStatus.column_names.include?('csys_closed_outcome') && !available_filters.key?(POSITIVE_FILTER)
        add_available_filter(
          POSITIVE_FILTER,
          type: :list,
          name: :label_cosmosys_positive,
          values: lambda { [[l(:label_cosmosys_positive_yes), '1'], [l(:label_cosmosys_positive_no), '0']] }
        )
      end
    end

    def sql_for_field(field, operator, value, db_table, db_field, is_custom_filter = false)
      return super unless field == POSITIVE_FILTER

      positive = "(#{IssueStatus.table_name}.is_closed = #{self.class.connection.quoted_false} OR #{IssueStatus.table_name}.csys_closed_outcome = 'successful')"
      return positive if operator == '=' && value.include?('1')
      return "NOT #{positive}" if operator == '!' && value.include?('1')
      return "NOT #{positive}" if operator == '=' && value.include?('0')
      return positive if operator == '!' && value.include?('0')

      '1=0'
    end

    def initialize(attributes = nil, *args)
      super
      cosmosys_apply_project_profile_default_status_filter
    end

    def default_columns_names
      names = project.present? ? project.cosmosys_item_list_column_names.map(&:to_sym) : []
      (names.presence || super.dup) - [:csid]
    end

    def columns
      cols = super.dup
      csid_column = available_columns.find { |column| column.name == :csid }
      return cols unless csid_column

      cols.reject! { |column| column.name == :csid }
      anchor_index = cols.index { |column| column.name == :id }

      if anchor_index
        cols.insert(anchor_index + 1, csid_column)
      else
        cols.unshift(csid_column)
      end

      cols
    end

    private

    def cosmosys_apply_project_profile_default_status_filter
      return unless project&.respond_to?(:cosmosys_project_profile_definition)
      return unless project.cosmosys_project_profile_definition.key == 'requirements'
      return unless filters == { 'status_id' => { operator: 'o', values: [''] } }
      return unless IssueStatus.column_names.include?('csys_closed_outcome')

      unsuccessful_ids = IssueStatus.where(csys_closed_outcome: 'unsuccessful').pluck(:id).map(&:to_s)
      self.filters = { 'status_id' => { operator: '!', values: unsuccessful_ids } } if unsuccessful_ids.any?
    end
  end
end
