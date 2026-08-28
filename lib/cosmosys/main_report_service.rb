module Cosmosys
  class MainReportService
    Report = Struct.new(:project, :sections, :toc_entries, :local_issues, :options, keyword_init: true)
    Section = Struct.new(:issue, :depth, :heading_level, :chapter, :anchor, :metadata_fields, :body_fields, :children, :report_placeholder, :document_catalog_entries, :document_references, keyword_init: true)
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

      Report.new(
        project: @project,
        sections: root_sections,
        toc_entries: flatten_sections(root_sections),
        local_issues: local_issues,
        options: Cosmosys::MainReportSettings.normalize_options(@options)
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
      @tree_scope ||= Cosmosys::ProjectTreeScope.new(@project, user: @user)
    end

    def field_registry
      @field_registry ||= Cosmosys::MainReportFieldRegistry.new(
        user: @user,
        column_names: @column_names,
        field_presentations: @field_presentations
      )
    end

    def local_issues
      @local_issues ||= tree_scope.local_issues
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

    def report_chapter_map
      @report_chapter_map ||= begin
        map = {}
        assign_chapters(report_roots, nil, map)
        map
      end
    end

    def assign_chapters(issues, prefix, map)
      issues.each_with_index do |issue, index|
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
        document_references: document_references_for(issue)
      )
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
      return [] unless placeholder

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
