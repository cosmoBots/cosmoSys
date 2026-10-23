# frozen_string_literal: true

module Cosmosys
  class ConsolidationState < ActiveRecord::Base
    self.table_name = 'cosmosys_consolidation_states'

    validates :consolidator_key, :scope_key, :fingerprint, presence: true
  end
end
