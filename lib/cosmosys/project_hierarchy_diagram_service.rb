require 'digest'
require_relative 'project_combined_diagram_service'
require_relative 'hierarchy_diagram_view'

module Cosmosys
  class ProjectHierarchyDiagramService
    include Cosmosys::DiagramCacheSupport

    KIND = 'project_hierarchy'.freeze
    FULL_KIND = 'project_hierarchy_full'.freeze

    def self.fetch(project, mode: :project_boundary, relation_types: ProjectCombinedDiagramService::SUPPORTED_RELATION_TYPES, render_variant: nil, layout_mode: nil)
      new(project, mode: mode, relation_types: relation_types, render_variant: render_variant, layout_mode: layout_mode).fetch
    end

    def initialize(project, mode: :project_boundary, relation_types: ProjectCombinedDiagramService::SUPPORTED_RELATION_TYPES, render_variant: nil, layout_mode: nil)
      @project = project
      @mode = mode
      @relation_types = relation_types
      @render_variant = render_variant
      @layout_mode = layout_mode
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', project_id: @project.id, kind: diagram_kind) do
        { signature: project_signature, empty: combined_diagram.dot_body.blank? }
      end
      fetch_cached_diagram(
        scope_attrs: { project_id: @project.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        signature: discovery[:signature]
      ) { Cosmosys::HierarchyDiagramView.from_combined(combined_diagram.dot_body) }
    end

    private

    def diagram_kind
      @mode == :full ? FULL_KIND : KIND
    end

    def combined_diagram
      @combined_diagram ||= Cosmosys::ProjectCombinedDiagramService.fetch(
        @project,
        mode: @mode,
        render_variant: @render_variant,
        layout_mode: @layout_mode,
        include_document_references: false,
        relation_types: @relation_types
      )
    end

    def project_signature
      payload = ['combined_hierarchy_view:v1', "mode:#{@mode}", combined_diagram.signature]
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def renderer
      @renderer ||= Cosmosys::HierarchyDiagramRenderer.new
    end
  end
end
