module Cosmosys
  class CombinedDiagramOptions
    KIND = 'combined'.freeze

    attr_reader :issue, :project, :user, :render_variant, :layout_mode

    def self.resolve(user:, project:, issue: nil, render_variant: nil, layout_mode: nil, persist: false)
      new(
        user: user,
        project: project,
        issue: issue,
        render_variant: render_variant,
        layout_mode: layout_mode,
        persist: persist
      ).resolve
    end

    def initialize(user:, project:, issue: nil, render_variant: nil, layout_mode: nil, persist: false)
      @user = user
      @project = project
      @issue = issue
      @requested_render_variant = render_variant.to_s
      @requested_layout_mode = layout_mode.to_s
      @persist = persist
    end

    def resolve
      preference = current_preference
      @render_variant = effective_render_variant(preference)
      @layout_mode = effective_layout_mode(preference)
      persist_preference!(preference) if should_persist_preference?
      self
    end

    private

    def current_preference
      Cosmosys::DiagramPreference.find_for(
        kind: KIND,
        issue: issue,
        project: issue.present? ? nil : project
      )
    end

    def should_persist_preference?
      @persist && (@requested_render_variant.present? || @requested_layout_mode.present?)
    end

    def persist_preference!(preference)
      record = preference || Cosmosys::DiagramPreference.find_or_initialize_for(
        kind: KIND,
        issue: issue,
        project: issue.present? ? nil : project
      )
      record.render_variant = render_variant
      record.layout_mode = layout_mode
      record.updated_by = user if user&.logged?
      record.save!
    end

    def effective_render_variant(preference)
      return @requested_render_variant if Cosmosys::CombinedDiagramRenderer.valid_render_variant?(@requested_render_variant)

      preferred = preference&.render_variant.to_s
      return preferred if Cosmosys::CombinedDiagramRenderer.valid_render_variant?(preferred)

      project.cosmosys_combined_diagram_render_variant
    end

    def effective_layout_mode(preference)
      return @requested_layout_mode if Cosmosys::CombinedDiagramRenderer.valid_layout_mode?(@requested_layout_mode)

      preferred = preference&.layout_mode.to_s
      return preferred if Cosmosys::CombinedDiagramRenderer.valid_layout_mode?(preferred)

      project.cosmosys_combined_diagram_layout_mode
    end
  end
end
