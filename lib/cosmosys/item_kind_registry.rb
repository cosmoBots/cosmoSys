module Cosmosys
  module ItemKindRegistry
    Profile = Struct.new(
      :key,
      :label,
      :description,
      :provider,
      :diagram_shape,
      :diagram_fill_color,
      :diagram_border_color,
      :diagram_font_color,
      :diagram_font_name,
      :reference_mode,
      :dependency_rankdir,
      :diagram_visible,
      :report_diagrams,
      :report_metadata,
      :report_placeholder_kinds,
      :can_have_children,
      :can_split,
      :aggregate_children,
      :allowed_parent_profiles,
      :dsm_mode,
      :reference_tracker,
      :closed_presentation,
      :allow_unsuccessful_closure_when_blocked,
      :validate_blocking_maturity,
      :tree_visible,
      :report_visible,
      :chapter_numbered,
      :allowed_child_profiles,
      :defines_project_data,
      :user_defined_csid,
      :consumes_csid_sequence,
      :resolved_project_data_links,
      :physical_delete_policy,
      keyword_init: true
    ) do
      def value(attribute, issue, **context)
        configured = public_send(attribute)
        configured.respond_to?(:call) ? configured.call(issue, **context) : configured
      end
    end

    module_function

    DEFAULT_KEY = 'normal'.freeze
    EFFECTS = [
      { key: :diagram_shape, label: :label_cosmosys_item_profile_shape, scope: :text_cosmosys_item_profile_scope_all_nodes },
      { key: :diagram_fill_color, label: :label_cosmosys_item_profile_fill_color, scope: :text_cosmosys_item_profile_scope_all_nodes },
      { key: :diagram_border_color, label: :label_cosmosys_item_profile_border_color, scope: :text_cosmosys_item_profile_scope_all_nodes },
      { key: :diagram_font_name, label: :label_cosmosys_item_profile_font_name, scope: :text_cosmosys_item_profile_scope_all_nodes },
      { key: :diagram_font_color, label: :label_cosmosys_item_profile_font_color, scope: :text_cosmosys_item_profile_scope_all_nodes },
      { key: :reference_mode, label: :label_cosmosys_item_profile_reference, scope: :text_cosmosys_item_profile_scope_reference },
      { key: :dependency_rankdir, label: :label_cosmosys_item_profile_direction, scope: :text_cosmosys_item_profile_scope_dependency },
      { key: :diagram_visible, label: :label_cosmosys_item_profile_diagram_visible, scope: :text_cosmosys_item_profile_scope_diagram_visible },
      { key: :report_diagrams, label: :label_cosmosys_item_profile_report_diagrams, scope: :text_cosmosys_item_profile_scope_report_diagrams },
      { key: :report_metadata, label: :label_cosmosys_item_profile_report_metadata, scope: :text_cosmosys_item_profile_scope_report_metadata },
      { key: :report_placeholder_kinds, label: :label_cosmosys_item_profile_report_placeholders, scope: :text_cosmosys_item_profile_scope_report_placeholders },
      { key: :can_have_children, label: :label_cosmosys_item_profile_can_have_children, scope: :text_cosmosys_item_profile_scope_can_have_children },
      { key: :can_split, label: :label_cosmosys_item_profile_can_split, scope: :text_cosmosys_item_profile_scope_can_split },
      { key: :aggregate_children, label: :label_cosmosys_item_profile_aggregate_children, scope: :text_cosmosys_item_profile_scope_aggregate_children },
      { key: :allowed_parent_profiles, label: :label_cosmosys_item_profile_allowed_parents, scope: :text_cosmosys_item_profile_scope_allowed_parents },
      { key: :dsm_mode, label: :label_cosmosys_item_profile_dsm_mode, scope: :text_cosmosys_item_profile_scope_dsm_mode },
      { key: :reference_tracker, label: :label_cosmosys_item_profile_reference_tracker, scope: :text_cosmosys_item_profile_scope_reference_tracker },
      { key: :closed_presentation, label: :label_cosmosys_item_profile_closed_presentation, scope: :text_cosmosys_item_profile_scope_closed_presentation },
      { key: :allow_unsuccessful_closure_when_blocked, label: :label_cosmosys_item_profile_unsuccessful_closure, scope: :text_cosmosys_item_profile_scope_unsuccessful_closure },
      { key: :validate_blocking_maturity, label: :label_cosmosys_item_profile_maturity_validation, scope: :text_cosmosys_item_profile_scope_maturity_validation },
      { key: :tree_visible, label: :label_cosmosys_item_profile_tree_visible, scope: :text_cosmosys_item_profile_scope_tree_visible },
      { key: :report_visible, label: :label_cosmosys_item_profile_report_visible, scope: :text_cosmosys_item_profile_scope_report_visible },
      { key: :chapter_numbered, label: :label_cosmosys_item_profile_chapter_numbered, scope: :text_cosmosys_item_profile_scope_chapter_numbered },
      { key: :allowed_child_profiles, label: :label_cosmosys_item_profile_allowed_children, scope: :text_cosmosys_item_profile_scope_allowed_children },
      { key: :defines_project_data, label: :label_cosmosys_item_profile_defines_project_data, scope: :text_cosmosys_item_profile_scope_defines_project_data },
      { key: :user_defined_csid, label: :label_cosmosys_item_profile_user_defined_csid, scope: :text_cosmosys_item_profile_scope_user_defined_csid },
      { key: :consumes_csid_sequence, label: :label_cosmosys_item_profile_consumes_csid_sequence, scope: :text_cosmosys_item_profile_scope_consumes_csid_sequence },
      { key: :resolved_project_data_links, label: :label_cosmosys_item_profile_data_links, scope: :text_cosmosys_item_profile_scope_data_links },
      { key: :physical_delete_policy, label: :label_cosmosys_item_profile_physical_delete, scope: :text_cosmosys_item_profile_scope_physical_delete }
    ].map { |effect| effect.freeze }.freeze

    def register(key, label: nil, description: nil, provider:, **attributes)
      normalized_key = normalize_key(key)
      raise ArgumentError, 'item kind key must contain only lowercase letters, numbers and underscores' unless normalized_key.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "#{DEFAULT_KEY} is the reserved, immutable default item profile" if normalized_key == DEFAULT_KEY
      raise ArgumentError, "item profile #{normalized_key} is already registered" if profiles.key?(normalized_key)

      profiles[normalized_key] = build_profile(
        key: normalized_key,
        label: label || normalized_key.humanize,
        description: description,
        provider: provider,
        **attributes
      )
    end

    def fetch(key)
      profiles[normalize_key(key)] || default
    end

    def default
      profiles.fetch(DEFAULT_KEY)
    end

    def effects
      EFFECTS
    end

    def registered?(key)
      profiles.key?(normalize_key(key))
    end

    def all
      profiles.values.sort_by { |profile| [profile.key == DEFAULT_KEY ? 0 : 1, profile.key] }
    end

    def normalize_key(key)
      key.to_s.strip.downcase.presence || DEFAULT_KEY
    end

    def profiles
      @profiles ||= {
        DEFAULT_KEY => build_profile(
          key: DEFAULT_KEY,
          label: 'Normal',
          description: :text_cosmosys_item_profile_normal,
          provider: :cosmosys,
          diagram_shape: 'Mrecord',
          reference_mode: 'csid',
          dependency_rankdir: 'TB',
          diagram_visible: true,
          report_diagrams: true,
          report_metadata: true,
          can_have_children: true,
          can_split: true,
          aggregate_children: true,
          dsm_mode: 'leaves',
          closed_presentation: 'struck',
          allow_unsuccessful_closure_when_blocked: false,
          validate_blocking_maturity: false,
          tree_visible: true,
          report_visible: true,
          chapter_numbered: true,
          defines_project_data: false,
          user_defined_csid: false,
          consumes_csid_sequence: true,
          resolved_project_data_links: false,
          physical_delete_policy: 'redmine'
        )
      }
    end

    def build_profile(**attributes)
      attributes = {
        can_have_children: true,
        can_split: true,
        aggregate_children: true,
        allowed_parent_profiles: nil,
        dsm_mode: 'leaves',
        reference_tracker: true,
        closed_presentation: 'struck',
        allow_unsuccessful_closure_when_blocked: false,
        validate_blocking_maturity: false,
        tree_visible: true,
        report_visible: true,
        chapter_numbered: true,
        allowed_child_profiles: nil,
        defines_project_data: false,
        user_defined_csid: false,
        consumes_csid_sequence: true,
        resolved_project_data_links: false,
        physical_delete_policy: 'redmine'
      }.merge(attributes)
      immutable_attributes = attributes.transform_values { |value| value.nil? || value.frozen? ? value : value.freeze }
      Profile.new(**immutable_attributes).freeze
    end
  end
end

Cosmosys::ItemKindRegistry.register(
  'info',
  label: :label_cosmosys_item_profile_info,
  description: :text_cosmosys_item_profile_info,
  provider: :cosmosys,
  diagram_shape: 'folder',
  diagram_fill_color: 'white',
  reference_mode: 'chapter',
  dependency_rankdir: 'TB',
  diagram_visible: true,
  report_diagrams: false,
  report_metadata: false,
  can_have_children: true,
  can_split: false,
  aggregate_children: false,
  dsm_mode: 'none',
  reference_tracker: false
)
Cosmosys::ItemKindRegistry.register(
  'doc',
  label: :label_cosmosys_item_profile_doc,
  description: :text_cosmosys_item_profile_doc,
  provider: :cosmosys,
  diagram_shape: 'note',
  reference_mode: 'chapter',
  dependency_rankdir: 'TB',
  diagram_visible: false,
  report_diagrams: false,
  report_metadata: false,
  can_have_children: false,
  can_split: false,
  aggregate_children: false,
  allowed_parent_profiles: %w[info].freeze,
  dsm_mode: 'none',
  report_placeholder_kinds: %w[reference_documents applicable_documents compliance_documents].freeze
)

Cosmosys::ItemKindRegistry.register(
  'data_section',
  label: :label_cosmosys_item_profile_data_section,
  description: :text_cosmosys_item_profile_data_section,
  provider: :cosmosys,
  diagram_visible: false,
  report_diagrams: false,
  report_metadata: false,
  can_have_children: true,
  can_split: false,
  aggregate_children: false,
  allowed_child_profiles: %w[datum].freeze,
  dsm_mode: 'none',
  reference_mode: 'chapter',
  reference_tracker: false,
  report_placeholder_kinds: %w[project_data].freeze
)

Cosmosys::ItemKindRegistry.register(
  'datum',
  label: :label_cosmosys_item_profile_datum,
  description: :text_cosmosys_item_profile_datum,
  provider: :cosmosys,
  diagram_visible: false,
  report_diagrams: false,
  report_metadata: false,
  can_have_children: false,
  can_split: false,
  aggregate_children: false,
  dsm_mode: 'none',
  reference_mode: 'csid',
  reference_tracker: false,
  tree_visible: false,
  report_visible: false,
  chapter_numbered: false,
  defines_project_data: true,
  user_defined_csid: true,
  consumes_csid_sequence: false,
  resolved_project_data_links: :user_choice
)

Cosmosys::ItemKindRegistry.register(
  'negative',
  label: :label_cosmosys_item_profile_negative,
  description: :text_cosmosys_item_profile_negative,
  provider: :cosmosys,
  diagram_visible: false,
  report_diagrams: false,
  report_metadata: false,
  can_have_children: false,
  can_split: false,
  aggregate_children: false,
  allowed_parent_profiles: %w[info].freeze,
  dsm_mode: 'none',
  reference_mode: 'chapter',
  reference_tracker: false
)

Cosmosys::ItemKindRegistry.register(
  'alternate_1',
  label: 'Alternate 1',
  description: :text_cosmosys_item_profile_alternate_1,
  provider: :cosmosys,
  diagram_shape: 'note',
  diagram_fill_color: 'lightyellow',
  dependency_rankdir: 'LR'
)
Cosmosys::ItemKindRegistry.register(
  'alternate_2',
  label: 'Alternate 2',
  description: :text_cosmosys_item_profile_alternate_2,
  provider: :cosmosys,
  diagram_shape: 'component',
  diagram_fill_color: 'lightcyan',
  dependency_rankdir: 'TB'
)
