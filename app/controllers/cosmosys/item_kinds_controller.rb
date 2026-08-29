module Cosmosys
  class ItemKindsController < ApplicationController
    layout 'admin'
    self.main_menu = false

    before_action :require_admin

    def index
      @trackers = Tracker.sorted.to_a
      @profiles = Cosmosys::ItemKindRegistry.all
    end

    def update
      requested = params[:tracker_item_kinds]
      requested = requested.to_unsafe_h if requested.respond_to?(:to_unsafe_h)

      Tracker.transaction do
        Hash(requested).each do |tracker_id, item_kind|
          tracker = Tracker.find(tracker_id)
          tracker.update!(csys_item_kind: Cosmosys::ItemKindRegistry.normalize_key(item_kind))
        end
      end

      flash[:notice] = l(:notice_successful_update)
      redirect_to cosmosys_item_kinds_path
    end
  end
end
