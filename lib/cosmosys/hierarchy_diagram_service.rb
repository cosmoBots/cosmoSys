require 'digest'

module Cosmosys
  class HierarchyDiagramService
    include Cosmosys::DiagramCacheSupport

    KIND = 'hierarchy'.freeze
    FULL_KIND = 'hierarchy_full'.freeze

    def self.fetch(issue, mode: :project_boundary)
      new(issue, mode: mode).fetch
    end

    def self.mark_obsolete(issue_ids)
      ids = Array(issue_ids).compact.uniq
      return if ids.empty?

      Cosmosys::Diagram.where(issue_id: ids, kind: [KIND, FULL_KIND]).update_all(state: 'obsolete', updated_at: Time.current)
    end

    def initialize(issue, mode: :project_boundary)
      @issue = issue
      @mode = mode
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', issue_id: @issue.id, kind: diagram_kind) do
        {
          revision_state: Cosmosys::IssueTreeRevisionService.state_for(@issue),
          empty: !@issue.cosmosys_diagram_visible?,
          signature: hierarchy_signature
        }
      end
      fetch_cached_diagram(
        scope_attrs: { issue_id: @issue.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        revision_state: discovery[:revision_state],
        signature: discovery[:signature]
      ) { build_dot }
    end

    private

    def diagram_kind
      @mode == :full ? FULL_KIND : KIND
    end

    def build_dot
      renderer.build_graph(title: 'cosmosys_hierarchy') do |lines|
        lines.concat(renderer.build_tree(root_entry))
      end
    end

    def hierarchy_signature
      payload = ["mode:#{@mode}"]
      append_entry_signature(root_entry, payload)
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def append_entry_signature(entry, payload)
      issue = entry.fetch(:issue)
      children = Array(entry[:children])
      boundary = entry[:boundary] == true
      if children.any?
        payload << renderer.cluster_signature(issue, boundary: boundary)
      else
        payload << renderer.node_signature(issue, boundary: boundary)
      end
      children.each { |child| append_entry_signature(child, payload) }
    end

    def root_entry
      @root_entry ||= @mode == :full ? full_root_entry : scoped_root_entry
    end

    def full_root_entry
      chain = @issue.self_and_ancestors.to_a.select(&:cosmosys_diagram_visible?)
      entry = build_full_subtree_entry(@issue)
      chain[0..-2].reverse_each do |ancestor|
        entry = { issue: ancestor, boundary: false, children: [entry] }
      end
      entry
    end

    def build_full_subtree_entry(issue)
      { issue: issue, boundary: false, children: full_visible_children(issue).map { |child| build_full_subtree_entry(child) } }
    end

    def full_visible_children(issue)
      issue.children.visible(User.current).includes(:project, :tracker).order(:csposition, :lft, :id).to_a.select(&:cosmosys_diagram_visible?)
    end

    def scoped_root_entry
      current = @issue
      chain = [current]

      while current.parent.present? && current.parent.project_id == @issue.project_id
        current = current.parent
        chain.unshift(current) if current.cosmosys_diagram_visible?
      end

      if current.parent.present? && current.parent.project_id != @issue.project_id && current.parent.cosmosys_diagram_visible?
        chain.unshift(current.parent)
      end

      entry = build_scoped_subtree_entry(@issue)
      chain[0..-2].reverse_each do |ancestor|
        entry = {
          issue: ancestor,
          boundary: ancestor.project_id != @issue.project_id,
          children: [entry]
        }
      end
      entry
    end

    def build_scoped_subtree_entry(issue)
      children = scoped_visible_children(issue).map do |child|
        if child.project_id == @issue.project_id
          build_scoped_subtree_entry(child)
        else
          { issue: child, boundary: true, children: [] }
        end
      end
      { issue: issue, boundary: issue.project_id != @issue.project_id, children: children }
    end

    def scoped_visible_children(issue)
      issue.children.visible(User.current).includes(:project, :tracker).order(:csposition, :lft, :id).to_a.select(&:cosmosys_diagram_visible?)
    end

    def renderer
      @renderer ||= Cosmosys::HierarchyDiagramRenderer.new(current_issue: @issue)
    end
  end
end
