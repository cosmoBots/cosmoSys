module Cosmosys
  class DiagramPreference < ActiveRecord::Base
    self.table_name = 'cosmosys_diagram_preferences'

    belongs_to :updated_by, class_name: 'User', optional: true
    belongs_to :issue, optional: true
    belongs_to :project, optional: true

    validates :kind, presence: true
    validate :single_diagram_scope

    def visible_layer_names
      JSON.parse(visible_layers.presence || '[]')
    rescue JSON::ParserError
      []
    end

    def visible_layer_names=(names)
      self.visible_layers = Array(names).map(&:to_s).uniq.to_json
    end

    def self.find_for(kind:, issue: nil, project: nil)
      if issue.present?
        find_by(issue_id: issue.id, kind: kind.to_s)
      elsif project.present?
        find_by(project_id: project.id, kind: kind.to_s)
      end
    end

    def self.find_or_initialize_for(kind:, issue: nil, project: nil)
      find_for(kind: kind, issue: issue, project: project) || new(
        kind: kind.to_s,
        issue: issue,
        project: project
      )
    end

    private

    def single_diagram_scope
      if issue_id.blank? && project_id.blank?
        errors.add(:base, 'diagram preference must belong to an issue or a project')
      elsif issue_id.present? && project_id.present?
        errors.add(:base, 'diagram preference cannot belong to an issue and a project at the same time')
      end
    end
  end
end
