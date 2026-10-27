require 'set'

module Cosmosys
  module ChapterSort
    module_function

    def columns(scope:)
      # Derive chapter paths in Ruby from only the structural columns of the
      # trees touched by this query. Ancestors outside the filter still belong
      # in the path, but do not become additional query results.
      ids = scope.reorder(nil).distinct.pluck(Issue.arel_table[:id]).to_set
      return [Arel::Nodes::Grouping.new(Issue.arel_table[:id]).to_sql] if ids.empty?

      roots = scope.reorder(nil).select(Issue.arel_table[:root_id])
      rows = Issue.where(root_id: roots).order(:root_id, :lft, :id)
                  .pluck(:id, :project_id, :root_id, :lft, :rgt, :csposition)
      paths = {}
      stack = []
      current_root = nil
      rows.each do |id, _project_id, root_id, left, right, position|
        stack.clear if current_root != root_id
        current_root = root_id
        stack.pop while stack.any? && stack.last.fetch(:right) < left
        path = (stack.last&.fetch(:path) || []) + [position.to_i]
        paths[id] = path
        stack << { right: right, path: path }
      end
      ordered = rows.select { |row| ids.include?(row.first) }
                    .sort_by { |id, project_id, root_id, left, _right, _position| [paths.fetch(id), project_id, root_id, left, id] }
      rank = Arel::Nodes::Case.new(Issue.arel_table[:id])
      ordered.each_with_index { |row, index| rank.when(row.first).then(index) }
      # QueryColumn's host API takes strings. Arel, not this plugin, compiles
      # the expression; ordering remains in the DB before LIMIT/OFFSET.
      [rank.else(ordered.length).to_sql]
    end
  end
end
