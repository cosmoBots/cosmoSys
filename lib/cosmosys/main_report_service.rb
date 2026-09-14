module Cosmosys
  class MainReportService
    Report = Struct.new(:project, :sections, :toc_entries, :local_issues, :options, :orphaned_sections, keyword_init: true)
    Section = Struct.new(:issue, :depth, :heading_level, :chapter, :anchor, :metadata_fields, :body_fields, :children, :report_placeholder, :document_catalog_entries, :document_references, :negative_items, :numbered, keyword_init: true)
    OutlineEntry = Struct.new(:issue, :chapter, keyword_init: true)

    def initialize(project, user:, column_names: nil, field_presentations: nil, options: nil)
      @project = project
      @user = user
      @column_names = column_names
      @field_presentations = field_presentations
      @options = options || project.cosmosys_report_options
    end

    def build
      chapter_map = report_chapter_map
      root_sections = report_roots.map { |issue| build_section(issue, 0, chapter_map) }
      orphaned = orphaned_sections

      Report.new(
        project: @project,
        sections: root_sections,
        toc_entries: flatten_sections(root_sections),
        local_issues: local_issues,
        options: Cosmosys::MainReportSettings.normalize_options(@options),
        orphaned_sections: orphaned
      )
    end

    # Lightweight report order for consumers that need the same hierarchy and
    # chapter labels but not rendered fields, placeholders or document tables.
    def outline
      chapter_map = report_chapter_map
      append_outline(report_roots, chapter_map, [])
    end

    private

    def append_outline(issues, chapter_map, result)
      issues.each do |issue|
        result << OutlineEntry.new(issue: issue, chapter: chapter_map.fetch(issue.id))
        append_outline(ordered_children(issue.id), chapter_map, result)
      end
      result
    end

    def tree_scope
      @tree_scope ||= Cosmosys::ProjectTreeScope.new(
        @project,
        user: @user,
        include_negative: Cosmosys::MainReportSettings.normalize_options(@options)['include_negative_items']
      )
    end

    def field_registry
      @field_registry ||= Cosmosys::MainReportFieldRegistry.new(
        user: @user,
        column_names: @column_names,
        field_presentations: @field_presentations
      )
    end

    def local_issues
      @local_issues ||= tree_scope.local_issues.select(&:cosmosys_report_visible?)
    end

    def issues_by_parent_id
      @issues_by_parent_id ||= local_issues.group_by(&:parent_id)
    end

    def local_issue_ids
      @local_issue_ids ||= local_issues.map(&:id).to_set
    end

    def report_roots
      @report_roots ||= local_issues.select do |issue|
        issue.parent_id.blank? || !local_issue_ids.include?(issue.parent_id)
      end.sort_by do |issue|
        [issue.csposition || 0, issue.lft || 0, issue.id]
      end
    end

    # Positive items whose nearest ancestor is negative. They are rescuable
    # content surfaced under the virtual "orphaned items" section instead of
    # being silently dropped with their retired parent. The whole positive
    # subtree that remains below each orphan head is included.
    def orphaned_sections
      tree_scope.orphaned_issues.map { |entry| build_section_from_entry(entry, 0) }
    end

    def build_section_from_entry(entry, depth)
      issue = entry.issue
      return build_section(issue, depth, {}) if entry.children.empty?

      fields = field_registry.fields_for(issue)
      placeholder = issue.cosmosys_report_placeholder
      Section.new(
        issue: issue,
        depth: depth,
        heading_level: [depth + 1, 6].min,
        chapter: nil,
        anchor: "cosmosys-report-issue-#{issue.id}",
        metadata_fields: fields.select { |field| field.representation == 'metadata' },
        body_fields: fields.select { |field| field.representation == 'section' },
        children: entry.children.map { |child| build_section_from_entry(child, depth + 1) },
        report_placeholder: placeholder,
        document_catalog_entries: document_catalog_entries_for(placeholder),
        document_references: document_references_for(issue),
        negative_items: [],
        numbered: issue.cosmosys_positive?
      )
    end

    def report_chapter_map
      @report_chapter_map ||= begin
        map = {}
        assign_chapters(report_roots, nil, map)
        map
      end
    end

    def assign_chapters(issues, prefix, map)
      issues.select { |issue| issue.cosmosys_positive? && issue.cosmosys_chapter_numbered? }.each_with_index do |issue, index|
        chapter = [prefix, index + 1].compact.join('.')
        map[issue.id] = chapter
        assign_chapters(ordered_children(issue.id), chapter, map)
      end
    end

    def build_section(issue, depth, chapter_map)
      children = ordered_children(issue.id).map { |child| build_section(child, depth + 1, chapter_map) }
      fields = field_registry.fields_for(issue)
      placeholder = issue.cosmosys_report_placeholder

      Section.new(
        issue: issue,
        depth: depth,
        heading_level: [depth + 1, 6].min,
        chapter: chapter_map[issue.id],
        anchor: "cosmosys-report-issue-#{issue.id}",
        metadata_fields: fields.select { |field| field.representation == 'metadata' },
        body_fields: fields.select { |field| field.representation == 'section' },
        children: children,
        report_placeholder: placeholder,
        document_catalog_entries: document_catalog_entries_for(placeholder),
        document_references: document_references_for(issue),
        negative_items: negative_items_for(issue),
        numbered: issue.cosmosys_positive?
      )
    end

    def negative_items_for(issue)
      return [] unless issue.cosmosys_item_kind_key == 'negative'

      scope = Issue.visible(@user)
                     .where(project_id: @project.id)
                     .where(issue_statuses: { csys_closed_outcome: 'unsuccessful' })
                     .joins(:status)
                     .includes(:status)
      selected = issue.cosmosys_selected_negative_status_ids
      scope = scope.where(status_id: selected) if selected.any?
      scope.order(:root_id, :lft, :csposition, :id).to_a
    end

    def document_references_for(issue)
      issue.cosmosys_catalog_refs.includes(document_catalog_entry: :document)
           .select { |catalog_ref| catalog_ref.visible?(@user) }
           .sort_by do |catalog_ref|
        entry = catalog_ref.document_catalog_entry
        [entry.family, entry.position, entry.id, catalog_ref.id]
      end
    end

    def document_catalog_entries_for(placeholder)
      return [] unless placeholder&.family

      Cosmosys::DocumentCatalogEntry.where(project_id: placeholder.project_id, family: placeholder.family)
                                    .includes(:document)
                                    .ordered
                                    .select { |entry| entry.document.visible?(@user) }
    end

    def flatten_sections(sections)
      sections.each_with_object([]) do |section, result|
        result << section
        result.concat(flatten_sections(section.children))
      end
    end

    def ordered_children(parent_id)
      Array(issues_by_parent_id[parent_id]).sort_by do |issue|
        [issue.csposition || 0, issue.lft || 0, issue.id]
      end
    end
  end
end
