module Cosmosys
  class MainReportFieldRegistry
    ResolvedField = Struct.new(:key, :label, :value, :representation, :rich_text, keyword_init: true)

    TEST_CUSTOM_FIELD_PREFIX = 'cst_'.freeze
    DEFAULT_HIDDEN_COLUMN_NAMES = %w[project].freeze
    DEFAULT_CORE_COLUMN_NAMES = %w[project tracker status priority author assigned_to start_date due_date done_ratio].freeze
    DEFAULT_REPRESENTATION_MODE = 'metadata'.freeze
    REPRESENTATION_MODES = %w[metadata section].freeze

    def initialize(user:, column_names: nil, field_presentations: nil)
      @user = user
      @column_names = Array(column_names).map(&:to_s).reject(&:blank?)
      @field_presentations = Hash(field_presentations).transform_keys(&:to_s).transform_values(&:to_s)
    end

    def self.query(user:)
      IssueQuery.new(name: 'cosmosys-main-report-fields').tap do |query|
        query.user = user if query.respond_to?(:user=)
      end
    end

    def self.query_for_project(project, user:)
      IssueQuery.new(name: 'cosmosys-main-report-fields', project: project).tap do |query|
        query.user = user if query.respond_to?(:user=)
      end
    end

    def self.available_inline_columns(user:)
      query(user: user).available_inline_columns.reject(&:frozen?)
    end

    def self.available_inline_columns_for_project(project, user:)
      query_for_project(project, user: user).available_inline_columns.reject(&:frozen?)
    end

    def self.available_column_names(user:)
      available_inline_columns(user: user).map { |column| column.name.to_s }
    end

    def self.available_column_names_for_project(project, user:)
      available_inline_columns_for_project(project, user: user).map { |column| column.name.to_s }
    end

    def self.default_column_names(user:)
      default_column_names_from_columns(available_inline_columns(user: user))
    end

    def self.default_column_names_for_project(project, user:)
      default_column_names_from_columns(available_inline_columns_for_project(project, user: user))
    end

    def self.valid_representation_mode?(mode)
      REPRESENTATION_MODES.include?(mode.to_s)
    end

    def self.default_column_names_from_columns(available_columns)
      available_names = available_columns.map { |column| column.name.to_s }
      custom_names = available_columns.filter_map do |column|
        custom_field = column.respond_to?(:custom_field) ? column.custom_field : nil
        next unless custom_field&.name.to_s.start_with?(TEST_CUSTOM_FIELD_PREFIX)

        column.name.to_s
      end

      default_core_names = DEFAULT_CORE_COLUMN_NAMES.reject { |name| DEFAULT_HIDDEN_COLUMN_NAMES.include?(name) }
      (default_core_names.select { |name| available_names.include?(name) } + custom_names).uniq
    end

    def fields_for(issue)
      columns_by_name = self.class.available_inline_columns_for_project(issue.project, user: @user).index_by { |column| column.name.to_s }
      representation_by_name = effective_field_presentations(issue)

      effective_column_names(issue).filter_map do |column_name|
        column = columns_by_name[column_name.to_s]
        next unless column

        value = normalize_value(column, column.value_object(issue))
        next if blank_value?(value)

        ResolvedField.new(
          key: column_name.to_s,
          label: normalize_label(column.caption),
          value: value,
          representation: representation_by_name[column_name.to_s] || DEFAULT_REPRESENTATION_MODE,
          rich_text: column.respond_to?(:cosmosys_report_rich_text?) && column.cosmosys_report_rich_text?
        )
      end
    end

    private

    def effective_column_names(issue)
      available_names = self.class.available_column_names_for_project(issue.project, user: @user)
      selected_names =
        if @column_names.present?
          @column_names.select { |name| available_names.include?(name) }
        else
          issue.project.cosmosys_report_column_names(user: @user)
        end

      selected_names.presence || issue.project.cosmosys_report_column_names(user: @user)
    end

    def effective_field_presentations(issue)
      base =
        if @field_presentations.present?
          @field_presentations
        else
          issue.project.cosmosys_report_field_presentations(user: @user)
        end

      effective_column_names(issue).each_with_object({}) do |name, result|
        mode = base[name].to_s
        result[name] = self.class.valid_representation_mode?(mode) ? mode : DEFAULT_REPRESENTATION_MODE
      end
    end

    def normalize_value(column, value)
      values = value.is_a?(Array) ? value : [value]
      rendered = values.filter_map { |entry| normalize_scalar(column, entry) }
      return nil if rendered.empty?
      return rendered.first if rendered.one?

      rendered.join(', ')
    end

    def normalize_scalar(column, value)
      return nil if value.blank?
      return I18n.l(value) if value.is_a?(Date) || value.is_a?(Time)
      return I18n.l(value.to_date) if value.respond_to?(:to_date) && !value.is_a?(String)
      return "#{value}%" if column.name.to_s == 'done_ratio'
      return value.name if value.respond_to?(:name)

      value.to_s.strip
    end

    def blank_value?(value)
      value.respond_to?(:blank?) ? value.blank? : value.nil?
    end

    def normalize_label(caption)
      caption.is_a?(Symbol) ? I18n.t(caption) : caption.to_s
    end
  end
end
