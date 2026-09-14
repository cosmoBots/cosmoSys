module Cosmosys
  # Join between a negative profile item (a `csNegative`) and the closed
  # unsuccessful item statuses whose items it should surface. A csNegative
  # selects zero, one or many negative statuses; an empty selection means
  # "surface all unsuccessful items".
  class NegativeStatusSelection < ActiveRecord::Base
    self.table_name = 'cosmosys_negative_statuses'

    belongs_to :issue, inverse_of: :negative_status_selections
    belongs_to :issue_status

    validates :issue_id, :issue_status_id, presence: true
    validates :issue_status_id, uniqueness: { scope: :issue_id }
  end
end
