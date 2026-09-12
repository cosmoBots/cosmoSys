module Cosmosys
  class ProjectMaterializationIdentity
    MODES = %w[new preserve].freeze

    def initialize(mode:, source_cscode:, destination:, entries:)
      @mode = MODES.include?(mode.to_s) ? mode.to_s : 'new'
      @source_cscode = source_cscode.to_s
      @destination = destination
      @entries = entries
    end

    def apply!
      return destination if mode == 'new'

      validate_project_code!
      validate_collisions!
      entries.each do |entry|
        issue = entry.fetch(:issue)
        Issue.unscoped.where(id: issue.id).update_all(
          csid: entry.fetch(:csid),
          csidnum: entry.fetch(:csidnum),
          csposition: entry.fetch(:position)
        )
        issue.reload
      end
      destination.update_columns(cslast_id: local_maximum)
      destination
    end

    private

    attr_reader :mode, :source_cscode, :destination, :entries

    def validate_project_code!
      return if destination.cscode.to_s.casecmp(source_cscode).zero?

      raise ProjectCopyError, I18n.t(:error_cosmosys_preserve_csid_project_code)
    end

    def validate_collisions!
      csids = entries.map { |entry| entry.fetch(:csid) }
      destination_ids = entries.map { |entry| entry.fetch(:issue).id }
      project_ids = destination.root.self_and_descendants.pluck(:id)
      collisions = Issue.where(project_id: project_ids)
                        .where('LOWER(csid) IN (?)', csids.map(&:downcase))
                        .where.not(id: destination_ids).pluck(:csid)
      return if collisions.empty?

      raise ProjectCopyError,
            I18n.t(:error_cosmosys_preserve_csid_collision, csids: collisions.sort.join(', '))
    end

    def local_maximum
      prefix = "#{destination.cscode}-"
      entries.filter_map do |entry|
        entry.fetch(:csidnum).to_i if entry.fetch(:csid).to_s.first(prefix.length).casecmp(prefix).zero?
      end.max.to_i
    end
  end
end
