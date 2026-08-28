module Cosmosys
  class ItemResolver
    CSID_PATTERN = /\A[A-Za-z0-9]+-[0-9]+\z/

    def initialize(project:, user: User.current)
      @project = project
      @user = user
    end

    def resolve(csid)
      normalized = normalize(csid)
      return nil unless normalized

      matches = visible_tree_scope.where('LOWER(issues.csid) = ?', normalized.downcase).limit(2).to_a
      matches.one? ? matches.first : nil
    end

    def search(query, limit: 10, exclude_id: nil)
      normalized = query.to_s.strip
      return [] if normalized.blank?

      scope = visible_tree_scope
      scope = scope.where.not(id: exclude_id) if exclude_id.present?
      scope.where('LOWER(issues.csid) LIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(normalized.downcase.delete_prefix('#'))}%")
        .order(:csid)
        .limit(limit)
        .to_a
    end

    private

    def normalize(value)
      normalized = value.to_s.strip.delete_prefix('#')
      normalized if CSID_PATTERN.match?(normalized)
    end

    def visible_tree_scope
      Issue.where(project_id: @project.root.self_and_descendants.select(:id)).visible(@user)
    end
  end
end
