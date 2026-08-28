require 'digest'

module Cosmosys
  class ProjectHierarchyDiagramService
    include Cosmosys::DiagramCacheSupport

    KIND = 'project_hierarchy'.freeze

    def self.fetch(project)
      new(project).fetch
    end

    def initialize(project)
      @project = project
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', project_id: @project.id, kind: KIND) do
        { signature: project_signature, empty: visible_issues.empty? }
      end
      fetch_cached_diagram(
        scope_attrs: { project_id: @project.id },
        kind: KIND,
        empty: discovery[:empty],
        signature: discovery[:signature]
      ) { build_dot }
    end

    private

    def build_dot
      renderer.build_graph(title: 'cosmosys_project_hierarchy') do |lines|
        project_roots.each do |issue|
          lines.concat(renderer.build_tree(build_project_subtree_entry(issue)))
        end
      end
    end

    def visible_issues
      @visible_issues ||= Issue.visible(User.current)
        .where(project_id: @project.id)
        .includes(:project, :tracker, :parent)
        .order(:csposition, :lft, :id)
        .to_a
        .select(&:cosmosys_diagram_visible?)
    end

    def visible_issue_ids
      @visible_issue_ids ||= visible_issues.map(&:id).to_set
    end

    def project_roots
      @project_roots ||= visible_issues.filter_map do |issue|
        if issue.parent_id.blank?
          issue
        elsif !visible_issue_ids.include?(issue.parent_id)
          issue.parent&.cosmosys_diagram_visible? ? issue.parent : issue
        end
      end.uniq(&:id)
    end

    def build_project_subtree_entry(issue)
      children = project_visible_children(issue).map do |child|
        if child.project_id == @project.id
          build_project_subtree_entry(child)
        else
          { issue: child, boundary: true, children: [] }
        end
      end

      { issue: issue, boundary: issue.project_id != @project.id, children: children }
    end

    def project_visible_children(issue)
      issue.children.visible(User.current).includes(:project, :tracker).order(:csposition, :lft, :id).to_a.select do |child|
        next false unless child.cosmosys_diagram_visible?

        if issue.project_id == @project.id
          true
        else
          child.project_id == @project.id
        end
      end
    end

    def project_signature
      payload = []
      payload.concat(project_root_dependencies)
      payload.concat(project_rendered_visual_dependencies)
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def project_root_dependencies
      project_roots.map do |issue|
        state = Cosmosys::IssueTreeRevisionService.state_for(issue)
        [
          'root',
          issue.id,
          state[:root_issue].id,
          state[:root_generation],
          state[:revision]
        ].join(':')
      end
    end

    def project_rendered_issues
      @project_rendered_issues ||= begin
        rendered = []
        project_roots.each do |issue|
          collect_rendered_issues(issue, rendered)
        end
        rendered.uniq(&:id)
      end
    end

    def collect_rendered_issues(issue, rendered)
      return if rendered.any? { |candidate| candidate.id == issue.id }

      rendered << issue
      project_visible_children(issue).each do |child|
        collect_rendered_issues(child, rendered) if child.project_id == @project.id
        rendered << child unless rendered.any? { |candidate| candidate.id == child.id }
      end
    end

    def project_rendered_visual_dependencies
      project_rendered_issues.map do |issue|
        [
          'item',
          issue.id,
          issue.project_id,
          issue.parent_id || 0,
          issue.csposition || 0,
          issue.updated_on&.utc&.to_i || 0
        ].join(':')
      end
    end

    def renderer
      @renderer ||= Cosmosys::HierarchyDiagramRenderer.new
    end
  end
end
