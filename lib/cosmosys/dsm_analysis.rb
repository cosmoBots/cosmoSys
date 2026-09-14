require 'set'

module Cosmosys
  class DsmAnalysis
    SUPPORTED_RELATIONS = %w[blocks precedes].freeze

    attr_reader :project, :user

    def initialize(project, user: User.current, include_negative: false)
      @project = project
      @user = user
      @include_negative = include_negative
    end

    def as_json(*)
      {
        project: { id: project.id, identifier: project.identifier, name: project.name },
        items: participating_items.map { |issue| item_payload(issue) },
        cells: cells.values.sort_by { |cell| [item_index.fetch(cell[:dependent_id]), item_index.fetch(cell[:prerequisite_id])] },
        compact_item_ids: compact_item_ids,
        scope: 'project',
        persisted_order: false
      }
    end

    def participating_items
      @participating_items ||= visible_items.select do |issue|
        mode = issue.cosmosys_item_kind.dsm_mode.to_s
        mode == 'all' || (mode == 'leaves' && !actual_parent_ids.include?(issue.id))
      end
    end

    def cells
      @cells ||= build_cells
    end

    def compact_item_ids
      @compact_item_ids ||= cells.values.flat_map { |cell| [cell[:dependent_id], cell[:prerequisite_id]] }.uniq
    end

    private

    def visible_items
      @visible_items ||= begin
        issues = Issue.visible(user).where(project_id: project.id).includes(:tracker, :project).order(:parent_id, :csposition, :id).to_a
        issues = issues.select(&:cosmosys_positive?) unless @include_negative
        @chapter_map = project.cosmosys_chapter_map(issues)
        issues.sort_by { |issue| chapter_sort_key(@chapter_map[issue.id]) }
      end
    end

    def visible_items_by_id
      @visible_items_by_id ||= visible_items.index_by(&:id)
    end

    def child_ids_by_parent
      @child_ids_by_parent ||= visible_items.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |issue, result|
        result[issue.parent_id] << issue.id if issue.parent_id && visible_items_by_id.key?(issue.parent_id)
      end
    end

    def participating_ids
      @participating_ids ||= participating_items.map(&:id).to_set
    end

    def actual_parent_ids
      @actual_parent_ids ||= Issue.where(parent_id: visible_items_by_id.keys).distinct.pluck(:parent_id).to_set
    end

    def item_index
      @item_index ||= participating_items.each_with_index.to_h { |issue, index| [issue.id, index] }
    end

    def projected_items(issue_id)
      return [visible_items_by_id.fetch(issue_id)] if participating_ids.include?(issue_id)

      child_ids_by_parent[issue_id].flat_map { |child_id| projected_items(child_id) }.uniq(&:id)
    end

    def build_cells
      result = {}
      visible_relations.each do |relation|
        prerequisites = projected_items(relation.issue_from_id)
        dependents = projected_items(relation.issue_to_id)
        next if (prerequisites.map(&:id) & dependents.map(&:id)).any?

        prerequisites.product(dependents).each do |prerequisite, dependent|
          next if prerequisite.id == dependent.id

          key = [dependent.id, prerequisite.id]
          cell = result[key] ||= {
            dependent_id: dependent.id, prerequisite_id: prerequisite.id,
            relation_types: [], restricted: false, planning: false, ghost: false, sources: []
          }
          restricted = relation.relation_type == 'blocks' || relation.csys_restricted?
          ghost = prerequisite.id != relation.issue_from_id || dependent.id != relation.issue_to_id
          cell[:relation_types] |= [relation.relation_type]
          cell[:restricted] ||= restricted
          cell[:planning] ||= !restricted
          cell[:ghost] ||= ghost
          cell[:sources] << {
            relation_id: relation.id, type: relation.relation_type, restricted: restricted, ghost: ghost,
            from: relation.issue_from.cosmosys_display_ref, to: relation.issue_to.cosmosys_display_ref
          }
        end
      end
      result
    end

    def visible_relations
      ids = visible_items_by_id.keys
      IssueRelation.includes(:issue_from, :issue_to).where(relation_type: SUPPORTED_RELATIONS, issue_from_id: ids, issue_to_id: ids).order(:id)
    end

    def item_payload(issue)
      ancestors = hierarchy_ancestors(issue)
      {
        id: issue.id, csid: issue.csid, chapter: @chapter_map[issue.id], tracker: issue.tracker.name,
        subject: issue.subject, url: Rails.application.routes.url_helpers.issue_path(issue), parent_id: issue.parent_id,
        hierarchy_path: ancestors.map(&:subject),
        group_ids: ancestors.last ? [ancestors.last.id] : [],
        group_label: ancestors.last&.subject
      }
    end

    def chapter_sort_key(chapter)
      chapter.to_s.split('.').map(&:to_i)
    end

    def hierarchy_ancestors(issue)
      result = []
      current = visible_items_by_id[issue.parent_id]
      while current
        result.unshift(current)
        current = visible_items_by_id[current.parent_id]
      end
      result
    end
  end
end
