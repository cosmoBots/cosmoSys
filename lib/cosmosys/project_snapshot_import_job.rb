module Cosmosys
  class ProjectSnapshotImportJob < ActiveJob::Base
    queue_as :default

    def perform(token)
      operation = ProjectSnapshotImportOperation.find(token)
      return unless operation

      operation.with_execution_lock do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          user = User.find(operation.data.fetch('user_id'))
          project_id = operation.data.fetch('project_id')
          project = Project.find(project_id) if project_id
          User.current = user
          raise Unauthorized unless user.admin? && user.active? && (!project || project.visible?(user))

          progress = ProgressReporter.new(operation, state: 'running')
          progress.call(1, 'validating')
          ProjectSnapshotPackageReader.open(operation.package_path, progress: progress) do |source|
            progress.call(3, 'preflight', processed: nil, total: nil)
            attributes = operation.data.fetch('attributes')
            plan = ProjectSnapshotMaterializationPlan.new(source: source, attributes: attributes, user: user)
            confirmed = ProjectSnapshotMaterializationPlan.verified_digest(operation.data.fetch('confirmed_plan'))
            unless confirmed && ActiveSupport::SecurityUtils.secure_compare(confirmed, plan.digest)
              raise ProjectCopyError, I18n.t(:error_cosmosys_snapshot_changed_plan)
            end
            raise ProjectCopyError, plan.blocking_messages.join(' ') if plan.blocking_messages.any?

            destination = ProjectSnapshotMaterializer.new(
              source, user: user, attributes: attributes, purpose: :snapshot, progress: progress
            ).call
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            operation.update!(state: 'completed', summary: operation.summary.merge(
              'progress' => 100, 'progress_phase' => 'completed', 'duration_seconds' => elapsed.round(1),
              'destination_identifier' => destination.identifier,
              'result_message' => ProjectSnapshotMaterializationSummary.new(project: destination, plan: plan).message
            ))
            Rails.logger.info({ cosmosys_snapshot_import: 'progress', operation: token, phase: 'completed', progress: 100, elapsed_seconds: elapsed.round(1) }.to_json)
          end
        rescue StandardError => error
          operation.update!(state: 'failed', summary: operation.summary.merge(
            'progress_phase' => 'failed', 'error' => error.message,
            'duration_seconds' => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(1)
          ))
          Rails.logger.error("cosmoSys snapshot import failed (#{token}): #{error.class}: #{error.message}")
        ensure
          # Failed attempts retain their bounded temporary package for an
          # explicit fresh preflight; never replay a materialization blindly.
          operation.release_package! if operation.state == 'completed'
        end
      end
    ensure
      User.current = nil
    end
  end
end
