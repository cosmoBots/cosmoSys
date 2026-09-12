require_dependency 'project'

module Cosmosys
  module ProjectPatch
    extend ActiveSupport::Concern

    included do
      has_one :cosmosys_report_setting_record, class_name: 'Cosmosys::ProjectReportSetting', foreign_key: :project_id, dependent: :destroy
      has_many :cosmosys_pending_relations,
               class_name: 'Cosmosys::PendingRelation',
               foreign_key: :root_project_id,
               dependent: :destroy
      belongs_to :cosmosys_ods_template_asset,
                 class_name: 'Cosmosys::TemplateAsset',
                 foreign_key: :csys_ods_template_asset_id,
                 optional: true,
                 inverse_of: :ods_overriding_projects
      belongs_to :cosmosys_report_template_asset,
                 class_name: 'Cosmosys::TemplateAsset',
                 foreign_key: :csys_report_template_asset_id,
                 optional: true,
                 inverse_of: :report_overriding_projects

      safe_attributes 'cscode', 'csys_language', 'csys_report_code', 'csys_report_export_format'
      safe_attributes 'csys_project_profile', if: ->(project, _user) { project.new_record? }
      safe_attributes 'csys_modules_explicit', if: ->(project, _user) { project.new_record? }

      before_validation :cosmosys_normalize_project_identity
      before_validation :cosmosys_apply_initial_module_defaults
      before_validation :cosmosys_ensure_required_modules

      validates :cscode, presence: true
      validates :cscode, format: { with: /\A[a-zA-Z0-9]+\z/ }
      validates :csys_language, inclusion: { in: ->(_project) { Cosmosys::ProjectLanguage.available }, allow_blank: true }
      validates :csys_report_code, length: { maximum: 255 }
      validates :csys_report_export_format, inclusion: { in: Cosmosys::ReportFormat::FORMATS, allow_blank: true }
      validate :cosmosys_validate_project_profile

      validate :cosmosys_validate_project_identity_uniqueness
      validate :cosmosys_validate_root_stability
      validate :cosmosys_validate_project_identity_immutable, on: :update
      validate :cosmosys_validate_required_trackers
      validate :cosmosys_validate_report_template_selection
      after_create :cosmosys_apply_initial_profile_contract!
      after_commit :cosmosys_invalidate_language_dependent_diagrams, on: :update, if: :saved_change_to_csys_language?

      attr_readonly :cscode
      attr_accessor :csys_modules_explicit
    end

    def project_root
      root
    end

    def cosmosys_scope
      {
        root_project: project_root,
        project_code: cscode,
        cslast_id: cslast_id.to_i
      }
    end

    def find_item_by_csid(csid)
      Cosmosys::ItemResolver.new(project: self).resolve(csid)
    end

    def cosmosys_chapter_map(issues = nil)
      Cosmosys::ChapterMap.for_project(self, issues)
    end

    def cosmosys_project_profile_definition
      Cosmosys::ProjectProfileRegistry.fetch(csys_project_profile)
    end

    def cosmosys_locale
      (csys_language.presence || Cosmosys::ProjectLanguage.instance_default).to_sym
    end

    def cosmosys_effective_language = cosmosys_locale.to_s

    def with_cosmosys_locale(&block)
      I18n.with_locale(cosmosys_locale, &block)
    end

    def cosmosys_effective_ods_template
      Cosmosys::TemplateResolver.ods_for(self)
    end

    def cosmosys_effective_report_template
      Cosmosys::TemplateResolver.report_for(self)
    end

    def cosmosys_validate_report_template_selection
      if csys_report_template_key.present? && csys_report_template_asset_id.present?
        errors.add(:base, 'Only one report template override may be selected')
      end
      if csys_report_template_key.present? && !Cosmosys::ReportTemplateCatalog.registered?(csys_report_template_key)
        errors.add(:csys_report_template_key, :invalid)
      end
      if cosmosys_report_template_asset && cosmosys_report_template_asset.kind != 'report'
        errors.add(:cosmosys_report_template_asset, :invalid)
      end
    end

    def cosmosys_effective_project_passphrase
      candidate = self
      while candidate
        return candidate.csys_project_passphrase if candidate.csys_project_passphrase.present?
        candidate = candidate.parent
      end
      identifier
    end

    def cosmosys_project_passphrase_source
      candidate = self
      while candidate
        return candidate if candidate.csys_project_passphrase.present?
        candidate = candidate.parent
      end
      self
    end

    def cosmosys_required_trackers
      keys = cosmosys_project_profile_definition.required_trackers.map { |entry| entry.fetch(:key) }
      Tracker.where(csys_key: keys)
    end

    def cosmosys_effective_root_tracker_key
      csys_root_tracker_key.presence || cosmosys_project_profile_definition.default_root_tracker
    end

    def cosmosys_root_tracker
      key = cosmosys_effective_root_tracker_key
      key.present? && key != 'free' ? trackers.find_by(csys_key: key) : nil
    end

    def cosmosys_enable_required_trackers!
      self.trackers = (trackers.to_a | cosmosys_required_trackers.to_a)
    end

    def cosmosys_apply_profile_module_defaults!
      self.enabled_module_names = cosmosys_profile_default_module_names(enabled_module_names)
    end

    def cosmosys_apply_initial_module_defaults
      return unless new_record?
      return if ActiveModel::Type::Boolean.new.cast(csys_modules_explicit)

      self.enabled_module_names = cosmosys_profile_default_module_names
    end

    def cosmosys_profile_default_module_names(base_names = Setting.default_projects_modules)
      profile = cosmosys_project_profile_definition
      names = Array(base_names).map(&:to_s)
      names |= profile.default_enabled_modules
      names -= profile.default_disabled_modules
      names | profile.required_modules
    end

    def cosmosys_profile_module_impact(profile_key)
      profile = Cosmosys::ProjectProfileRegistry.fetch(profile_key)
      current = enabled_module_names.map(&:to_s)
      target = cosmosys_profile_default_module_names_for(profile, Setting.default_projects_modules)
      { enable: target - current, disable: current - target, required: profile.required_modules }
    end

    def cosmosys_reconfigure_modules_for_profile!
      self.enabled_module_names = cosmosys_profile_default_module_names
    end

    def cosmosys_ensure_required_modules
      required = cosmosys_project_profile_definition.required_modules
      self.enabled_module_names = enabled_module_names | required if required.any?
    end

    def cosmosys_validate_project_profile
      return if Cosmosys::ProjectProfileRegistry.registered?(csys_project_profile)

      errors.add(:csys_project_profile, :inclusion)
    end

    def cosmosys_apply_initial_profile_contract!
      cosmosys_enable_required_trackers!
      cosmosys_ensure_required_modules
      save! if changed?
    end

    def cosmosys_profile_default_module_names_for(profile, base_names)
      names = Array(base_names).map(&:to_s)
      names |= profile.default_enabled_modules
      names -= profile.default_disabled_modules
      names | profile.required_modules
    end

    def cosmosys_invalidate_language_dependent_diagrams
      issue_ids = issues.select(:id)
      Cosmosys::Diagram.where(project_id: id).or(Cosmosys::Diagram.where(issue_id: issue_ids))
                       .update_all(state: 'obsolete', updated_at: Time.current)
    end

    def tracker_ids=(ids)
      requested_ids = Array(ids).filter_map do |value|
        parsed = value.to_i
        parsed if parsed.positive?
      end
      return super(requested_ids) if new_record?

      required_ids = cosmosys_required_trackers.pluck(:id)
      if (required_ids - requested_ids).any?
        errors.add(:tracker_ids, 'cannot remove trackers required by the project profile')
        return tracker_ids
      end
      super(requested_ids)
    end

    def trackers=(records)
      requested = Array(records)
      return super(requested) if new_record?

      required_ids = cosmosys_required_trackers.pluck(:id)
      if (required_ids - requested.map(&:id)).any?
        errors.add(:tracker_ids, 'cannot remove trackers required by the project profile')
        return trackers
      end
      super(requested)
    end

    def cosmosys_report_column_names(user: User.current)
      saved_names = cosmosys_report_setting_record&.column_names_array.to_a
      available_names = Cosmosys::MainReportFieldRegistry.available_column_names_for_project(self, user: user)

      selected_names =
        if saved_names.present?
          saved_names.select { |name| available_names.include?(name) }
        elsif cosmosys_project_profile_definition.default_report_columns.any?
          cosmosys_project_profile_definition.default_report_columns.select { |name| available_names.include?(name) }
        else
          Cosmosys::MainReportSettings.global_column_names(user: user).select { |name| available_names.include?(name) }
        end

      selected_names.presence || Cosmosys::MainReportFieldRegistry.default_column_names_for_project(self, user: user)
    end

    def cosmosys_report_field_presentations(user: User.current)
      selected_names = cosmosys_report_column_names(user: user)
      saved_modes =
        if cosmosys_report_setting_record&.report_payload&.key?('field_presentations')
          cosmosys_report_setting_record.field_presentations_hash.to_h
        else
          Cosmosys::MainReportSettings.global_field_presentations(user: user).merge(
            cosmosys_project_profile_definition.default_report_field_presentations
          )
        end

      selected_names.each_with_object({}) do |name, result|
        mode = saved_modes[name].to_s
        result[name] = Cosmosys::MainReportFieldRegistry.valid_representation_mode?(mode) ? mode : Cosmosys::MainReportFieldRegistry::DEFAULT_REPRESENTATION_MODE
      end
    end

    def cosmosys_report_options
      if cosmosys_report_setting_record&.report_payload&.key?('options')
        cosmosys_report_setting_record.report_options_hash
      else
        Cosmosys::MainReportSettings.global_options.merge(
          cosmosys_project_profile_definition.default_report_options
        )
      end
    end

    def cosmosys_item_list_column_names
      available_names = IssueQuery.new(name: 'cosmosys-profile-item-list', project: self).available_inline_columns.map { |column| column.name.to_s }
      payload = cosmosys_report_setting_record&.report_payload || {}
      selected_names =
        if payload.key?('item_list_columns')
          cosmosys_report_setting_record.item_list_column_names_array
        elsif cosmosys_project_profile_definition.default_item_list_columns.any?
          cosmosys_project_profile_definition.default_item_list_columns
        else
          Array(Setting.issue_list_default_columns).map(&:to_s)
        end

      selected_names.select { |name| available_names.include?(name) }
    end

    def cosmosys_report_landscape_scale_threshold
      cosmosys_report_setting_record&.landscape_scale_threshold || 55
    end

    def cosmosys_effective_report_export_format
      project = self
      while project
        format = Cosmosys::ReportFormat.normalize(project.csys_report_export_format, allow_blank: true)
        return format if format.present?

        project = project.parent
      end
      Cosmosys::ReportFormat.global_default
    end

    def cosmosys_combined_diagram_layout_mode
      mode = cosmosys_report_setting_record&.combined_layout_mode.to_s
      Cosmosys::CombinedDiagramRenderer.valid_layout_mode?(mode) ? mode : Cosmosys::CombinedDiagramRenderer::DEFAULT_LAYOUT_MODE
    end

    def cosmosys_combined_diagram_render_variant
      variant = cosmosys_report_setting_record&.combined_render_variant.to_s
      Cosmosys::CombinedDiagramRenderer.valid_render_variant?(variant) ? variant : Cosmosys::CombinedDiagramRenderer::DEFAULT_RENDER_VARIANT
    end

    private

    def cosmosys_validate_required_trackers
      return if new_record?

      missing = cosmosys_required_trackers.where.not(id: tracker_ids).pluck(:name)
      errors.add(:tracker_ids, "must include #{missing.join(', ')}") if missing.any?
    end

    def cosmosys_normalize_project_identity
      self.cscode = cosmosys_normalize_code(cscode)
    end

    def cosmosys_validate_root_stability
      return unless persisted?
      return unless will_save_change_to_parent_id?

      previous_parent_id = attribute_in_database('parent_id')
      previous_root = previous_parent_id.present? ? Project.find(previous_parent_id).root : self
      new_root = parent.present? ? parent.root : self
      return if previous_root.id == new_root.id

      errors.add(:parent_id, :invalid)
    end

    def cosmosys_validate_project_identity_uniqueness
      return if cscode.blank?

      scope_ids = cosmosys_tree_project_ids
      return if scope_ids.empty?

      siblings = Project.where(id: scope_ids).where.not(id: id)

      if siblings.where('LOWER(projects.cscode) = ?', cscode.downcase).exists?
        errors.add(:cscode, :taken)
      end
    end

    def cosmosys_validate_project_identity_immutable
      errors.add(:cscode, :readonly) if will_save_change_to_cscode?
    end

    def cosmosys_tree_project_ids
      if parent.present?
        parent.root.self_and_descendants.pluck(:id)
      elsif persisted?
        root.self_and_descendants.pluck(:id)
      else
        []
      end
    end

    def cosmosys_normalize_code(value)
      normalized = value.to_s.strip
      normalized.presence
    end
  end
end
