require 'digest'
require_relative 'combined_diagram_service'
require_relative 'hierarchy_diagram_view'

module Cosmosys
  class HierarchyDiagramService
    include Cosmosys::DiagramCacheSupport

    KIND = 'hierarchy'.freeze
    FULL_KIND = 'hierarchy_full'.freeze

    def self.fetch(issue, mode: :project_boundary, relation_types: CombinedDiagramService::SUPPORTED_RELATION_TYPES, render_variant: nil, layout_mode: nil)
      new(issue, mode: mode, relation_types: relation_types, render_variant: render_variant, layout_mode: layout_mode).fetch
    end

    def self.mark_obsolete(issue_ids)
      ids = Array(issue_ids).compact.uniq
      return if ids.empty?

      Cosmosys::Diagram.where(issue_id: ids, kind: [KIND, FULL_KIND]).update_all(state: 'obsolete', updated_at: Time.current)
    end

    def initialize(issue, mode: :project_boundary, relation_types: CombinedDiagramService::SUPPORTED_RELATION_TYPES, render_variant: nil, layout_mode: nil)
      @issue = issue
      @mode = mode
      @relation_types = relation_types
      @render_variant = render_variant
      @layout_mode = layout_mode
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', issue_id: @issue.id, kind: diagram_kind) do
        {
          revision_state: Cosmosys::IssueTreeRevisionService.state_for(@issue),
          signature: hierarchy_signature,
          empty: combined_diagram.dot_body.blank?
        }
      end
      fetch_cached_diagram(
        scope_attrs: { issue_id: @issue.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        revision_state: discovery[:revision_state],
        signature: discovery[:signature]
      ) { Cosmosys::HierarchyDiagramView.from_combined(combined_diagram.dot_body) }
    end

    private

    def diagram_kind
      @mode == :full ? FULL_KIND : KIND
    end

    def hierarchy_signature
      payload = ['combined_hierarchy_view:v3', "mode:#{@mode}", combined_diagram.signature]
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def combined_diagram
      @combined_diagram ||= Cosmosys::CombinedDiagramService.fetch(
        @issue,
        mode: @mode,
        render_variant: @render_variant,
        layout_mode: @layout_mode,
        include_document_references: false,
        relation_types: @relation_types
      )
    end

    def renderer
      @renderer ||= Cosmosys::HierarchyDiagramRenderer.new(current_issue: @issue)
    end
  end
end
