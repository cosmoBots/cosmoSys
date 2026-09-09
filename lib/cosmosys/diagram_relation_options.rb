module Cosmosys
  class DiagramRelationOptions
    FULL_TRAVERSAL = 'cross_project_boundaries'.freeze
    LAYERS = %W[blocks precedes relates document_references #{FULL_TRAVERSAL}].freeze
    DEFAULT_LAYERS = %w[blocks precedes].freeze

    attr_reader :issue, :project, :user, :kind, :visible_layers

    def self.resolve(user:, project:, kind:, issue: nil, visible_layers: nil, persist: false)
      new(
        user: user,
        project: project,
        kind: kind,
        issue: issue,
        visible_layers: visible_layers,
        persist: persist
      ).resolve
    end

    def initialize(user:, project:, kind:, issue: nil, visible_layers: nil, persist: false)
      @user = user
      @project = project
      @issue = issue
      @kind = kind.to_s
      @requested_layers = visible_layers
      @persist = persist
    end

    def resolve
      preference = current_preference
      @visible_layers = requested? ? normalize(@requested_layers) : stored_layers(preference)
      persist_preference!(preference) if @persist && requested?
      self
    end

    def relation_types
      visible_layers & %w[blocks precedes relates]
    end

    def include_document_references?
      visible_layers.include?('document_references')
    end

    def full_traversal?
      visible_layers.include?(FULL_TRAVERSAL)
    end

    def mode
      full_traversal? ? :full : :project_boundary
    end

    private

    def requested?
      !@requested_layers.nil?
    end

    def normalize(layers)
      Array(layers).map(&:to_s) & LAYERS
    end

    def stored_layers(preference)
      return DEFAULT_LAYERS.dup unless preference&.visible_layers.present?

      normalize(preference.visible_layer_names)
    end

    def current_preference
      Cosmosys::DiagramPreference.find_for(
        kind: kind,
        issue: issue,
        project: issue.present? ? nil : project
      )
    end

    def persist_preference!(preference)
      record = preference || Cosmosys::DiagramPreference.find_or_initialize_for(
        kind: kind,
        issue: issue,
        project: issue.present? ? nil : project
      )
      record.visible_layer_names = visible_layers
      record.updated_by = user if user&.logged?
      record.save!
    end
  end
end
