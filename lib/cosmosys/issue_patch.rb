require 'set'
require_dependency 'issue'

module Cosmosys
  module IssuePresentationPatch
    def css_classes
      classes = super
      return classes unless cosmosys_closure_outcome == :successful

      [classes, 'cosmosys-closure-successful'].compact.join(' ')
    end
  end

  module IssuePatch
    PREFERRED_REPORT_DIAGRAMS = %w[combined dependency hierarchy no_diagram].freeze

    def self.included(base)
      base.class_eval do
        validate :cosmosys_validate_tree_scope
        validate :cosmosys_validate_parent_scope
        validate :cosmosys_validate_profile_hierarchy
        validate :cosmosys_validate_issue_csid_uniqueness
        validate :cosmosys_validate_user_defined_csid
        validate :cosmosys_validate_issue_identity_immutable, on: :update
        validate :cosmosys_validate_used_project_data_retirement, on: :update
        before_validation :cosmosys_assign_identity, on: :create
        before_validation :cosmosys_assign_position
        before_save :cosmosys_capture_root_transition, if: :cosmosys_tree_structure_pending_change?
        before_destroy :cosmosys_capture_diagram_obsolete_ids
        before_destroy :cosmosys_capture_root_transition
        before_destroy :cosmosys_prevent_used_project_data_deletion
        before_destroy :cosmosys_prevent_unauthorized_physical_delete
        after_save :cosmosys_normalize_sibling_positions, if: :cosmosys_saved_hierarchy_change?
        after_commit :cosmosys_mark_diagrams_obsolete_after_commit, on: [:create, :update]
        after_commit :cosmosys_bump_tree_revision_after_commit, on: [:create, :update]
        after_create :cosmosys_register_project_copy
        after_destroy_commit :cosmosys_mark_diagrams_obsolete_after_destroy
        after_destroy_commit :cosmosys_bump_tree_revision_after_destroy

        validates :csid, presence: true
        validates :csidnum, presence: true
        validates :csposition, presence: true

        attr_readonly :csid, :csidnum

        has_many :cosmosys_catalog_refs,
                 class_name: 'Cosmosys::CatalogRef',
                 foreign_key: :issue_id
        has_many :negative_status_selections,
                 class_name: 'Cosmosys::NegativeStatusSelection',
                 foreign_key: :issue_id,
                 dependent: :destroy,
                 inverse_of: :issue
        has_many :selected_negative_statuses,
                 through: :negative_status_selections,
                 source: :issue_status,
                 class_name: 'IssueStatus'
        before_destroy :cosmosys_remove_catalog_refs_with_issue
        has_one :cosmosys_report_placeholder,
                class_name: 'Cosmosys::ReportPlaceholder',
                foreign_key: :issue_id,
                dependent: :destroy
        safe_attributes 'csys_report_placeholder_kind'
        safe_attributes 'csys_preferred_report_diagram'
        safe_attributes 'csys_negative_status_id'
        safe_attributes 'csys_negative_status_ids'
        safe_attributes 'csys_value', if: ->(issue, _user) { issue.cosmosys_defines_project_data? }
        safe_attributes 'csid', if: ->(issue, _user) { issue.new_record? && issue.cosmosys_user_defined_csid? }
        validates :csys_preferred_report_diagram,
                  inclusion: { in: PREFERRED_REPORT_DIAGRAMS }
        validate :cosmosys_validate_negative_status
        validate :cosmosys_validate_report_placeholder
        after_save :cosmosys_sync_report_placeholder
      end

      searchable_columns = Array(base.searchable_options[:columns]).dup
      base.searchable_options = base.searchable_options.merge(columns: searchable_columns | ["#{base.table_name}.csid"])
    end

    def csid
      self[:csid]
    end

    def cosmosys_register_project_copy
      context = Cosmosys::ProjectCopyContext.current
      source_id = instance_variable_get(:@cosmosys_copy_source_id)
      context.register_issue(source_id, self) if context && source_id
    end

    def project_root
      project&.root
    end

    def cosmosys_display_ref
      csid || id.to_s
    end

    def cosmosys_item_kind
      tracker&.cosmosys_item_kind_profile || Cosmosys::ItemKindRegistry.fetch('normal')
    end

    def cosmosys_negative_item?
      cosmosys_item_kind_key == 'negative'
    end

    def cosmosys_validate_negative_status
      return unless cosmosys_negative_item? && csys_negative_status_id.present?

      status = IssueStatus.find_by(id: csys_negative_status_id)
      return if status&.is_closed? && status.csys_closed_outcome == 'unsuccessful'

      errors.add(:csys_negative_status_id, :invalid)
    end

    # Multi-status selector for a csNegative. An empty selection means "surface
    # all unsuccessful items"; a non-empty selection restricts to those closed
    # unsuccessful statuses whose ids are listed. The stale single column from
    # the previous release (003) is kept only as a bounded fallback for data
    # captured before the join table existed; the join table is the source of
    # truth for the multi-selector.
    def csys_negative_status_ids
      return @csys_negative_status_ids.to_a if !persisted? && defined?(@csys_negative_status_ids)

      ids = negative_status_selections.map(&:issue_status_id)
      ids = [csys_negative_status_id] if ids.blank? && csys_negative_status_id.present?
      ids.compact.uniq
    end

    def csys_negative_status_ids=(ids)
      values = Array(ids).reject(&:blank?).map(&:to_i).uniq
      if persisted?
        current = negative_status_selections.map(&:issue_status_id)
        to_remove = current - values
        to_add = values - current
        negative_status_selections.where(issue_status_id: to_remove).delete_all if to_remove.any?
        to_add.each do |status_id|
          next unless valid_negative_status_selection?(status_id)

          negative_status_selections.create!(issue_status_id: status_id)
        end
      else
        @csys_negative_status_ids = values
      end
    end

    def cosmosys_selected_negative_status_ids
      ids = csys_negative_status_ids
      return [] if ids.blank?

      IssueStatus.where(id: ids, is_closed: true, csys_closed_outcome: 'unsuccessful').pluck(:id)
    end

    def valid_negative_status_selection?(status_id)
      IssueStatus.exists?(id: status_id, is_closed: true, csys_closed_outcome: 'unsuccessful')
    end
    private :valid_negative_status_selection?

    def cosmosys_item_kind_key
      cosmosys_item_kind.key
    end

    def cosmosys_closure_outcome
      return :unsuccessful if status&.respond_to?(:cosmosys_unsuccessfully_closed?) && status.cosmosys_unsuccessfully_closed?
      return :successful if status&.respond_to?(:cosmosys_successfully_closed?) && status.cosmosys_successfully_closed?

      :unspecified
    end

    def cosmosys_positive?
      !status&.is_closed? || cosmosys_closure_outcome == :successful
    end

    def csys_report_placeholder_kind
      return @csys_report_placeholder_kind if instance_variable_defined?(:@csys_report_placeholder_kind)

      cosmosys_report_placeholder&.kind.to_s
    end

    def csys_report_placeholder_kind=(value)
      @csys_report_placeholder_kind = value.to_s.presence
    end

    def cosmosys_report_placeholder_kinds
      cosmosys_item_kind.report_placeholder_kinds.to_a
    end

    def cosmosys_preferred_reference_mode
      cosmosys_item_kind.value(:reference_mode, self).to_s.presence || 'csid'
    end

    def cosmosys_report_diagrams?
      cosmosys_item_kind.value(:report_diagrams, self) != false
    end

    def cosmosys_preferred_report_diagram
      csys_preferred_report_diagram.presence || 'combined'
    end

    def cosmosys_preferred_report_diagram=(value)
      self.csys_preferred_report_diagram = value
    end

    def cosmosys_report_diagram_kinds(options)
      return [] unless cosmosys_report_diagrams?

      kinds = []
      preferred = cosmosys_preferred_report_diagram
      kinds << preferred if options['preferred_diagram'] && preferred != 'no_diagram'
      %w[combined hierarchy dependency].each do |kind|
        kinds << kind if options["#{kind}_diagram"]
      end
      kinds.uniq
    end

    # An item is visible in a diagram by default only when its profile allows
    # diagram visibility and it has not closed unsuccessfully (Rejected/Erased).
    # Retired content stays in its persisted location and can be shown through
    # the "show negatives in place" option via cosmosys_diagram_content_positive?
    def cosmosys_diagram_visible?
      cosmosys_item_kind.value(:diagram_visible, self) != false && cosmosys_positive?
    end

    # Full control for callers that support the "include negative" view option.
    def cosmosys_diagram_content_positive?(include_negative: false)
      return cosmosys_item_kind.value(:diagram_visible, self) != false if include_negative

      cosmosys_diagram_visible?
    end

    def cosmosys_tree_visible?
      cosmosys_item_kind.value(:tree_visible, self) != false
    end

    def cosmosys_report_visible?
      cosmosys_item_kind.value(:report_visible, self) != false
    end

    def cosmosys_chapter_numbered?
      cosmosys_item_kind.value(:chapter_numbered, self) != false
    end

    def cosmosys_defines_project_data?
      cosmosys_item_kind.value(:defines_project_data, self) == true
    end

    def cosmosys_user_defined_csid?
      cosmosys_item_kind.value(:user_defined_csid, self) == true
    end

    def cosmosys_report_metadata?
      cosmosys_item_kind.value(:report_metadata, self) != false
    end

    def cosmosys_diagram_identifier_text(_kind = 'hierarchy')
      mode = cosmosys_item_kind.value(:reference_mode, self, kind: _kind).to_s
      mode == 'chapter' ? cosmosys_chapter.presence || cosmosys_display_ref : cosmosys_display_ref
    end

    def cosmosys_dependency_container_node?
      children.visible(User.current).exists?
    end

    def cosmosys_diagram_subject_text(_kind = 'hierarchy', boundary: false)
      text = cosmosys_wrapped_diagram_text(subject, max_width: 12)
      boundary ? "+ #{text}" : text
    end

    def cosmosys_diagram_node_label(kind = 'hierarchy', boundary: false, dependency_container: nil)
      dependency_container = cosmosys_dependency_container_node? if kind.to_s == 'dependency' && dependency_container.nil?
      return cosmosys_dependency_container_label(boundary: boundary) if kind.to_s == 'dependency' && dependency_container

      identifier = cosmosys_diagram_identifier_text(kind)
      title = cosmosys_diagram_subject_text(kind, boundary: boundary)

      if %w[record Mrecord].include?(cosmosys_diagram_shape(kind).to_s)
        "{#{identifier}|#{title}}"
      else
        [identifier, title].compact_blank.join("\n")
      end
    end

    def cosmosys_diagram_label(_kind = 'hierarchy', boundary: false)
      [
        cosmosys_diagram_identifier_text(_kind),
        cosmosys_diagram_subject_text(_kind, boundary: boundary)
      ].join("\n")
    end

    def cosmosys_diagram_shape(kind = 'hierarchy')
      profile_value = cosmosys_item_kind.value(:diagram_shape, self, kind: kind)
      return profile_value if profile_value.present?

      return 'note' if kind.to_s == 'dependency' && cosmosys_dependency_container_node?

      'record'
    end

    def cosmosys_diagram_fill_color(_kind = 'hierarchy')
      profile_value = cosmosys_item_kind.value(:diagram_fill_color, self, kind: _kind)
      return profile_value if profile_value.present?

      if status&.is_closed
        'lightgrey'
      else
        expired = due_date.present? && due_date < Date.current
        if expired
          done_ratio.to_i.positive? ? 'orange' : 'lightcoral'
        else
          done_ratio.to_i.positive? ? 'lightblue' : 'white'
        end
      end
    end

    def cosmosys_diagram_border_color(_kind = 'hierarchy')
      return 'red' unless cosmosys_diagram_valid?

      profile_value = cosmosys_item_kind.value(:diagram_border_color, self, kind: _kind)
      return profile_value if profile_value.present?

      assigned_to_id.present? && assigned_to_id == User.current&.id ? 'blue' : 'black'
    end

    def cosmosys_diagram_font_color(_kind = 'hierarchy')
      profile_value = cosmosys_item_kind.value(:diagram_font_color, self, kind: _kind)
      return profile_value if profile_value.present?

      'black'
    end

    def cosmosys_diagram_font_name(kind = 'hierarchy', boundary: false)
      profile_value = cosmosys_item_kind.value(:diagram_font_name, self, kind: kind, boundary: boundary)
      return profile_value if profile_value.present?

      return 'times italic' if kind.to_s == 'dependency' && cosmosys_dependency_container_node?

      boundary ? 'times italic' : 'times'
    end

    def cosmosys_diagram_penwidth(_kind = 'hierarchy', selected: false)
      selected ? 1.5 : 0.5
    end

    def cosmosys_hierarchy_cluster_label(boundary: false)
      cosmosys_hierarchy_container_label(boundary: boundary)
    end

    def cosmosys_hierarchy_cluster_color
      cosmosys_diagram_valid? ? 'black' : 'red'
    end

    def cosmosys_hierarchy_cluster_font_name(boundary: false)
      boundary ? 'times italic' : 'times italic'
    end

    def cosmosys_hierarchy_cluster_penwidth(selected: false)
      selected ? 1.5 : 1.0
    end

    def cosmosys_dependency_rankdir
      cosmosys_item_kind.value(:dependency_rankdir, self) || 'LR'
    end

    def cosmosys_dependency_relation_visible?(relation_type)
      %w[blocks precedes relates].include?(relation_type.to_s)
    end

    def cosmosys_dependency_relation_color(relation_type)
      case relation_type.to_s
      when 'blocks'
        '#2F6FDE'
      when 'precedes'
        '#2E8B57'
      when 'relates'
        '#7B8794'
      else
        '#7B8794'
      end
    end

    def cosmosys_dependency_container_label(boundary: false)
      cosmosys_container_diagram_label('dependency', boundary: boundary)
    end

    def cosmosys_hierarchy_container_label(boundary: false)
      cosmosys_container_diagram_label('hierarchy', boundary: boundary)
    end

    def cosmosys_container_diagram_label(kind, boundary: false)
      reference = cosmosys_diagram_identifier_text(kind).presence
      title = cosmosys_wrapped_diagram_text(subject, max_width: 16)
      prefix = boundary ? '+' : ''

      if reference.present?
        "#{prefix}#{reference}.#{title}"
      else
        "#{prefix}#{title}"
      end
    end

    def cosmosys_chapter(chapter_map = nil)
      return chapter_map[id] if chapter_map.present?

      Cosmosys::ChapterMap.for_issue(self)
    end

    def chapter_label
      cosmosys_chapter
    end

    def cosmosys_subtree_chapter_map(issues = nil)
      Cosmosys::ChapterMap.for_subtree(self, issues)
    end

    def cosmosys_descendant_of?(other_issue)
      current = parent

      while current.present?
        return true if current.id == other_issue.id

        current = current.parent
      end

      false
    end

    private

    def cosmosys_remove_catalog_refs_with_issue
      cosmosys_catalog_refs.to_a.each(&:destroy_from_issue!)
      throw :abort if cosmosys_catalog_refs.reload.exists?
    end

    def cosmosys_validate_report_placeholder
      kind = csys_report_placeholder_kind
      return if kind.blank?

      unless cosmosys_report_placeholder_kinds.include?(kind)
        errors.add(:csys_report_placeholder_kind, :inclusion)
        return
      end

      duplicate = Cosmosys::ReportPlaceholder.where(project_id: project_id, kind: kind).where.not(issue_id: id).exists?
      errors.add(:csys_report_placeholder_kind, :taken) if duplicate
    end

    def cosmosys_sync_report_placeholder
      kind = csys_report_placeholder_kind
      placeholder = cosmosys_report_placeholder
      unless cosmosys_report_placeholder_kinds.include?(kind)
        placeholder&.destroy!
        return
      end

      if placeholder
        placeholder.update!(project_id: project_id, kind: kind) unless placeholder.project_id == project_id && placeholder.kind == kind
      else
        create_cosmosys_report_placeholder!(project: project, kind: kind)
      end
    end

    public

    def cosmosys_diagram_valid?
      return true unless cosmosys_item_kind.validate_blocking_maturity

      cosmosys_blocking_maturity_consistent?
    end

    def cosmosys_blocking_maturity_consistent?(visited = Set.new)
      return true if id.blank? || visited.include?(id)

      maturity = status&.cosmosys_maturity_level
      return true if maturity.nil?

      branch = visited.dup.add(id)
      relations_to.includes(issue_from: [:status, :tracker]).where(relation_type: 'blocks').all? do |relation|
        blocker = relation.issue_from
        blocker_maturity = blocker.status&.cosmosys_maturity_level
        maturity_ok = blocker_maturity.to_i >= maturity
        maturity_ok && blocker.cosmosys_blocking_maturity_consistent?(branch)
      end
    end

    private

    def cosmosys_wrapped_diagram_text(text, max_width: 42)
      normalized = text.to_s.gsub(/\s+/, ' ').strip
      return normalized if normalized.length <= max_width

      lines = []
      current = +''
      normalized.split(' ').each do |word|
        if current.empty?
          current = word
        elsif current.length + 1 + word.length <= max_width
          current << ' ' << word
        else
          lines << current
          current = word
        end
      end
      lines << current unless current.empty?
      lines.join("\n")
    end

    def cosmosys_assign_identity
      return unless project.present?

      if cosmosys_user_defined_csid?
        self.csid = csid.to_s.strip.presence
        return if csidnum.present?

        project.root.with_lock do
          project_ids = project.root.self_and_descendants.select(:id)
          self.csidnum = Issue.where(project_id: project_ids).where('csidnum < 0').minimum(:csidnum).to_i - 1
        end
        return
      end

      return if csid.present?

      project.with_lock do
        next_id = project.cslast_id.to_i + 1
        project.update!(cslast_id: next_id)
        self.csidnum = next_id
        self.csid = format('%s-%04d', project.cscode, next_id)
      end
    end

    def cosmosys_assign_position
      return unless cosmosys_current_project.present?
      return unless new_record? || will_save_change_to_parent_id? || will_save_change_to_project_id? || csposition.blank?

      Cosmosys::SiblingOrder.append(self)
    end

    def cosmosys_validate_tree_scope
      return unless will_save_change_to_project_id?
      current_project = cosmosys_current_project
      return if current_project.blank?

      previous_project_id = attribute_in_database('project_id')
      return if previous_project_id.blank?

      old_root_id = Project.find(previous_project_id).root.id
      new_root_id = current_project.root.id
      return if old_root_id == new_root_id

      errors.add(:project_id, I18n.t(:text_cosmosys_move_across_trees_forbidden))
    end

    def cosmosys_validate_parent_scope
      return if parent_issue_id.blank?

      parent_issue = cosmosys_parent_issue
      current_project = cosmosys_current_project
      parent_project = cosmosys_project_for(parent_issue&.project_id)
      return if parent_issue.blank? || current_project.blank? || parent_project.blank?

      current = parent_issue
      while current.present?
        if persisted? && current.id == id
          errors.add(:parent_issue_id, :invalid)
          return
        end
        current = current.parent
      end

      allowed_projects = current_project.self_and_ancestors
      return if allowed_projects.include?(parent_project)

      errors.add(:parent_issue_id, I18n.t(:text_cosmosys_invalid_parent_scope))
    end

    def cosmosys_validate_profile_hierarchy
      profile = cosmosys_item_kind
      if persisted? && !profile.can_have_children && children.exists?
        errors.add(:tracker_id, I18n.t(:text_cosmosys_profile_cannot_have_children))
      end
      return if parent_issue_id.blank?

      parent_issue = cosmosys_parent_issue
      return unless parent_issue

      unless parent_issue.cosmosys_item_kind.can_have_children
        errors.add(:parent_issue_id, I18n.t(:text_cosmosys_parent_profile_cannot_have_children))
      end
      allowed_children = parent_issue.cosmosys_item_kind.allowed_child_profiles
      if allowed_children && !allowed_children.include?(profile.key)
        errors.add(:parent_issue_id, I18n.t(:text_cosmosys_parent_profile_rejects_child))
      end
      allowed = profile.allowed_parent_profiles
      return if allowed.nil? || allowed.include?(parent_issue.cosmosys_item_kind.key)

      errors.add(:parent_issue_id, I18n.t(:text_cosmosys_parent_profile_not_allowed))
    end

    def cosmosys_validate_issue_csid_uniqueness
      current_project = cosmosys_current_project
      return if csid.blank? || current_project.blank?

      sibling_ids = current_project.root.self_and_descendants.pluck(:id)
      duplicates = Issue.where(project_id: sibling_ids).where('LOWER(issues.csid) = ?', csid.downcase)
      duplicates = duplicates.where.not(id: id) if persisted?
      return unless duplicates.exists?

      errors.add(:csid, :taken)
    end

    def cosmosys_validate_user_defined_csid
      return unless cosmosys_user_defined_csid?

      errors.add(:csid, :invalid) unless csid.to_s.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
    end

    def cosmosys_validate_issue_identity_immutable
      errors.add(:csid, :readonly) if will_save_change_to_csid?
      errors.add(:csidnum, :readonly) if will_save_change_to_csidnum?
    end

    def cosmosys_validate_used_project_data_retirement
      return unless cosmosys_defines_project_data? && will_save_change_to_status_id?
      return unless status&.respond_to?(:cosmosys_unsuccessfully_closed?) && status.cosmosys_unsuccessfully_closed?

      usages = Cosmosys::ProjectDataUsageScanner.new(self).call(limit: 4)
      cosmosys_add_project_data_usage_error(usages) if usages.any?
    end

    def cosmosys_prevent_used_project_data_deletion
      return unless cosmosys_defines_project_data?
      usages = Cosmosys::ProjectDataUsageScanner.new(self).call(limit: 4)
      return if usages.empty?

      cosmosys_add_project_data_usage_error(usages)
      throw :abort
    end

    # Physical deletes are reserved to administrators. No non-admin profile can
    # delete any item; retirement is modelled by the Erased state. An
    # administrator may perform Redmine's hard delete (making the item
    # disappear) on any item, including a requirement. This is a model-level
    # guard, independent of the controller's permission checks; disabling the
    # Redmine delete control for non-admins is handled separately.
    def cosmosys_prevent_unauthorized_physical_delete
      return if User.current&.admin?

      errors.add(:base, I18n.t(:error_cosmosys_issue_delete_admin_only))
      throw :abort
    end

    def cosmosys_add_project_data_usage_error(usages)
      references = usages.map { |usage| "##{usage.issue.id} (#{usage.attribute})" }.join(', ')
      errors.add(:base, I18n.t(:text_cosmosys_project_data_in_use, references: references))
    end

    def cosmosys_saved_hierarchy_change?
      saved_change_to_parent_id? || saved_change_to_project_id?
    end

    def cosmosys_tree_structure_pending_change?
      new_record? || will_save_change_to_parent_id? || will_save_change_to_project_id? || will_save_change_to_csposition?
    end

    def cosmosys_normalize_sibling_positions
      Cosmosys::SiblingOrder.normalize!(Cosmosys::SiblingOrder.sibling_scope(self))

      return unless saved_change_to_parent_id?

      previous_parent_id = saved_change_to_parent_id.first
      previous_project_id = saved_change_to_project_id&.first || project_id
      previous_scope =
        if previous_parent_id.present?
          Issue.where(parent_id: previous_parent_id)
        else
          Issue.where(project_id: previous_project_id, parent_id: nil).where.not(id: id)
      end
      Cosmosys::SiblingOrder.normalize!(previous_scope)
    end

    def cosmosys_capture_diagram_obsolete_ids
      @cosmosys_diagram_obsolete_ids = cosmosys_hierarchy_related_issue_ids
    end

    def cosmosys_mark_diagrams_obsolete_after_commit
      Cosmosys::HierarchyDiagramService.mark_obsolete(cosmosys_hierarchy_related_issue_ids)
    end

    def cosmosys_mark_diagrams_obsolete_after_destroy
      Cosmosys::HierarchyDiagramService.mark_obsolete(@cosmosys_diagram_obsolete_ids)
    end

    def cosmosys_capture_root_transition
      @cosmosys_previous_root_issue_id =
        if persisted?
          attribute_in_database('root_id').presence || root_id.presence || id
        else
          nil
        end
    end

    def cosmosys_bump_tree_revision_after_commit
      return unless cosmosys_tree_structure_changed_after_commit?

      new_root_id = root_id.presence || id
      Cosmosys::IssueTreeRevisionService.sync_root_membership(self, old_root_id: @cosmosys_previous_root_issue_id, new_root_id: new_root_id)
      Cosmosys::IssueTreeRevisionService.bump_root!(Issue.find(new_root_id))
      if @cosmosys_previous_root_issue_id.present? && @cosmosys_previous_root_issue_id != new_root_id
        previous_root = Issue.find_by(id: @cosmosys_previous_root_issue_id)
        Cosmosys::IssueTreeRevisionService.bump_root!(previous_root) if previous_root&.parent_id.nil?
      end
    end

    def cosmosys_bump_tree_revision_after_destroy
      return unless @cosmosys_previous_root_issue_id.present?

      previous_root = Issue.find_by(id: @cosmosys_previous_root_issue_id)
      Cosmosys::IssueTreeRevisionService.bump_root!(previous_root) if previous_root&.parent_id.nil?
    end

    def cosmosys_tree_structure_changed_after_commit?
      previous_changes.key?('id') ||
        previous_changes.key?('parent_id') ||
        previous_changes.key?('project_id') ||
        previous_changes.key?('csposition')
    end

    def cosmosys_hierarchy_related_issue_ids
      ids = Set.new

      ids.merge(self_and_ancestors.pluck(:id)) if persisted? || id.present?
      ids.merge(descendants.pluck(:id)) if persisted? || id.present?

      previous_parent_id = saved_change_to_parent_id&.first
      if previous_parent_id.present?
        previous_parent = Issue.find_by(id: previous_parent_id)
        ids.merge(previous_parent.self_and_ancestors.pluck(:id)) if previous_parent
      end

      ids.delete(nil)
      ids.to_a
    end

    def cosmosys_current_project
      cosmosys_project_for(self[:project_id])
    end

    def cosmosys_project_for(project_id)
      return nil if project_id.blank?

      if association(:project).loaded? && project&.id == project_id
        project
      else
        Project.find_by(id: project_id)
      end
    end

    def cosmosys_parent_issue
      current_parent_id = parent_issue_id
      return nil if current_parent_id.blank?

      if association(:parent).loaded? && parent&.id == current_parent_id
        parent
      else
        Issue.find_by(id: current_parent_id)
      end
    end
  end
end
