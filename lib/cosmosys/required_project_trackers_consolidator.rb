# frozen_string_literal: true

require 'digest'

module Cosmosys
  class RequiredProjectTrackersConsolidator
    CONSOLIDATOR_KEY = 'required_project_trackers'.freeze
    ALGORITHM_VERSION = 1
    BATCH_SIZE = 500

    class << self
      def call
        ProjectProfileRegistry.all.to_h do |profile|
          [profile.key, consolidate_profile(profile)]
        end
      end

      private

      def consolidate_profile(profile)
        definitions = profile.required_trackers.sort_by { |entry| entry.fetch(:key).to_s }
        tracker_ids = Tracker.where(csys_key: definitions.map { |entry| entry.fetch(:key) })
                             .pluck(:csys_key, :id).to_h
        missing_keys = definitions.map { |entry| entry.fetch(:key).to_s } - tracker_ids.keys.map(&:to_s)
        if missing_keys.any?
          Rails.logger.warn(
            "[cosmosys] consolidation #{CONSOLIDATOR_KEY} pending for profile=#{profile.key}; " \
            "required trackers not installed: #{missing_keys.join(', ')}"
          )
          return { status: :pending_trackers, missing: missing_keys }
        end

        fingerprint = fingerprint_for(profile, definitions, tracker_ids)
        projects_scanned = 0
        state = ConsolidationState.create_or_find_by!(
          consolidator_key: CONSOLIDATOR_KEY,
          scope_key: profile.key
        ) do |record|
          # The unique index makes concurrent first boots converge on one row;
          # the row lock below serializes the actual reconciliation.
          record.fingerprint = 'pending'
        end

        state.with_lock do
          if state.fingerprint == fingerprint
            return { status: :unchanged, projects_scanned: 0 }
          end

          Project.where(csys_project_profile: profile.key).in_batches(of: BATCH_SIZE) do |batch|
            project_ids = batch.pluck(:id)
            next if project_ids.empty?

            projects_scanned += project_ids.length
            add_missing_associations(project_ids, tracker_ids.values)
          end

          state.fingerprint = fingerprint
          state.save!
        end

        Rails.logger.info(
          "[cosmosys] consolidation #{CONSOLIDATOR_KEY} reconciled profile=#{profile.key}; " \
          "projects_scanned=#{projects_scanned}"
        )
        { status: :consolidated, projects_scanned: projects_scanned }
      end

      def fingerprint_for(profile, definitions, tracker_ids)
        payload = {
          algorithm_version: ALGORITHM_VERSION,
          profile: profile.key,
          required_trackers: definitions.map do |entry|
            {
              key: entry.fetch(:key).to_s,
              tracker_id: tracker_ids.fetch(entry.fetch(:key).to_s)
            }
          end
        }
        Digest::SHA256.hexdigest(Cosmosys::CanonicalJson.generate(payload))
      end

      def add_missing_associations(project_ids, tracker_ids)
        connection = ActiveRecord::Base.connection
        quoted_projects = project_ids.map { |id| connection.quote(id) }.join(', ')
        quoted_trackers = tracker_ids.map { |id| connection.quote(id) }.join(', ')

        connection.execute(<<~SQL.squish)
          INSERT INTO projects_trackers (project_id, tracker_id)
          SELECT projects.id, trackers.id
          FROM projects
          CROSS JOIN trackers
          WHERE projects.id IN (#{quoted_projects})
            AND trackers.id IN (#{quoted_trackers})
            AND NOT EXISTS (
              SELECT 1 FROM projects_trackers
              WHERE projects_trackers.project_id = projects.id
                AND projects_trackers.tracker_id = trackers.id
            )
        SQL
      end
    end
  end
end
