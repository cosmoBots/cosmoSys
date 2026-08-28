module Cosmosys
  module ProjectProfileRegistry
    Profile = Struct.new(
      :key, :label, :description, :provider, :required_trackers,
      :default_root_tracker, :ods_export_template, :report_export_template,
      :default_disabled_modules, :default_report_columns,
      :default_report_field_presentations, :default_report_options,
      :default_item_list_columns,
      keyword_init: true
    )
    DEFAULT_KEY = 'items'.freeze
    DEFAULT_ODS_EXPORT_TEMPLATE = 'plugins/cosmosys/assets/templates/ods/items_export_template.ods'.freeze
    DEFAULT_REPORT_EXPORT_TEMPLATE = Cosmosys::ReportTemplateCatalog.default.path.freeze
    DEFAULT_REPORT_COLUMNS = %w[tracker status priority author assigned_to start_date due_date done_ratio].freeze
    DEFAULT_REPORT_OPTIONS = {
      'description' => true, 'preferred_diagram' => true,
      'combined_diagram' => false, 'hierarchy_diagram' => false,
      'dependency_diagram' => false, 'item_url_link' => false,
      'info_url_link' => false
    }.freeze
    DEFAULT_ITEM_LIST_COLUMNS = %w[chapter_label subject tracker status priority assigned_to updated_on category fixed_version].freeze
    BASE_TRACKERS = [
      { key: 'cs_info', name: 'csInfo', item_profile: 'info' }.freeze,
      { key: 'cs_ref_doc', name: 'csRefDoc', item_profile: 'doc' }.freeze
    ].freeze

    module_function

    def register(key, label:, description:, provider:, required_trackers:, default_root_tracker: nil, ods_export_template: DEFAULT_ODS_EXPORT_TEMPLATE, report_export_template: DEFAULT_REPORT_EXPORT_TEMPLATE, default_disabled_modules: [], default_report_columns: DEFAULT_REPORT_COLUMNS, default_report_field_presentations: {}, default_report_options: DEFAULT_REPORT_OPTIONS, default_item_list_columns: DEFAULT_ITEM_LIST_COLUMNS)
      key = normalize_key(key)
      raise ArgumentError, "#{DEFAULT_KEY} is the reserved project profile" if key == DEFAULT_KEY
      raise ArgumentError, "project profile #{key} is already registered" if profiles.key?(key)
      candidate = build(key:, label:, description:, provider:, required_trackers: BASE_TRACKERS + required_trackers, default_root_tracker:, ods_export_template:, report_export_template:, default_disabled_modules:, default_report_columns:, default_report_field_presentations:, default_report_options:, default_item_list_columns:)
      validate_contract!(candidate)
      profiles[key] = candidate
    end

    def fetch(key) = profiles[normalize_key(key)] || profiles.fetch(DEFAULT_KEY)
    def registered?(key) = profiles.key?(normalize_key(key))
    def all = profiles.values.sort_by { |profile| [profile.key == DEFAULT_KEY ? 0 : 1, profile.key] }
    def normalize_key(key) = key.to_s.strip.downcase.presence || DEFAULT_KEY

    def profiles
      @profiles ||= {
        DEFAULT_KEY => build(
          key: DEFAULT_KEY,
          label: :label_cosmosys_project_profile_items,
          description: :text_cosmosys_project_profile_items,
          provider: :cosmosys,
          required_trackers: BASE_TRACKERS,
          default_root_tracker: 'cs_info',
          ods_export_template: DEFAULT_ODS_EXPORT_TEMPLATE,
          report_export_template: DEFAULT_REPORT_EXPORT_TEMPLATE,
          default_disabled_modules: [],
          default_report_columns: DEFAULT_REPORT_COLUMNS,
          default_report_field_presentations: {},
          default_report_options: DEFAULT_REPORT_OPTIONS,
          default_item_list_columns: DEFAULT_ITEM_LIST_COLUMNS
        )
      }
    end

    def build(**attributes)
      attributes[:required_trackers] = attributes[:required_trackers].map { |entry| entry.transform_keys(&:to_sym).dup.freeze }.uniq { |entry| entry.fetch(:key) }.freeze
      attributes[:default_disabled_modules] = Array(attributes[:default_disabled_modules]).map(&:to_s).uniq.freeze
      attributes[:default_report_columns] = Array(attributes[:default_report_columns]).map(&:to_s).reject(&:blank?).uniq.freeze
      attributes[:default_report_field_presentations] = Hash(attributes[:default_report_field_presentations]).stringify_keys.transform_values(&:to_s).freeze
      attributes[:default_report_options] = Hash(attributes[:default_report_options]).stringify_keys.transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) }.freeze
      item_list_columns = Array(attributes[:default_item_list_columns]).map(&:to_s).reject(&:blank?).uniq
      attributes[:default_item_list_columns] = (%w[chapter_label subject] + (item_list_columns - %w[chapter_label subject])).freeze
      Profile.new(**attributes.transform_values { |value| value.frozen? ? value : value.freeze }).freeze
    end

    def validate_contract!(candidate)
      template_path = Pathname(candidate.ods_export_template.to_s)
      raise ArgumentError, 'ODS export template path is required' if template_path.to_s.blank?
      raise ArgumentError, 'ODS export template path must be relative to Rails.root' if template_path.absolute? || template_path.each_filename.include?('..')
      raise ArgumentError, 'ODS export template must be an .ods file' unless template_path.extname.casecmp('.ods').zero?

      report_template_path = Pathname(candidate.report_export_template.to_s)
      raise ArgumentError, 'Report export template path is required' if report_template_path.to_s.blank?
      raise ArgumentError, 'Report export template path must be relative to Rails.root' if report_template_path.absolute? || report_template_path.each_filename.include?('..')
      raise ArgumentError, 'Report export template must be an .odt file' unless report_template_path.extname.casecmp('.odt').zero?

      unknown_modules = candidate.default_disabled_modules - Redmine::AccessControl.available_project_modules.map(&:to_s)
      raise ArgumentError, "unknown default-disabled project modules: #{unknown_modules.join(', ')}" if unknown_modules.any?

      unknown_options = candidate.default_report_options.keys - Cosmosys::MainReportSettings::OPTION_NAMES
      raise ArgumentError, "unknown default report options: #{unknown_options.join(', ')}" if unknown_options.any?

      invalid_presentations = candidate.default_report_field_presentations.reject do |_name, mode|
        Cosmosys::MainReportFieldRegistry.valid_representation_mode?(mode)
      end
      raise ArgumentError, "invalid default report presentations: #{invalid_presentations.keys.join(', ')}" if invalid_presentations.any?

      candidate.required_trackers.each do |entry|
        key = entry.fetch(:key).to_s
        item_profile = entry.fetch(:item_profile).to_s
        raise ArgumentError, "invalid tracker key #{key.inspect}" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
        raise ArgumentError, "unknown item profile #{item_profile}" unless Cosmosys::ItemKindRegistry.registered?(item_profile)

        existing = all.flat_map(&:required_trackers).find { |registered| registered.fetch(:key).to_s == key }
        next unless existing
        next if existing.fetch(:name).to_s == entry.fetch(:name).to_s && existing.fetch(:item_profile).to_s == item_profile

        raise ArgumentError, "tracker contract #{key} conflicts with another project profile"
      end

      root_key = candidate.default_root_tracker.to_s
      return if root_key.blank? || candidate.required_trackers.any? { |entry| entry.fetch(:key).to_s == root_key }

      raise ArgumentError, "default root tracker #{root_key} is not required by project profile #{candidate.key}"
    end
  end
end
