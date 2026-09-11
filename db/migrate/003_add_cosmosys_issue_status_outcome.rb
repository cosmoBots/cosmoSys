class AddCosmosysIssueStatusOutcome < ActiveRecord::Migration[6.1]
  OUTCOMES_BY_NAME = {
    'approved' => 'successful',
    'closed' => 'successful',
    'rejected' => 'unsuccessful',
    'erased' => 'unsuccessful'
  }.freeze

  def up
    add_column :issue_statuses, :csys_closed_outcome, :string unless column_exists?(:issue_statuses, :csys_closed_outcome)
    add_index :issue_statuses, :csys_closed_outcome unless index_exists?(:issue_statuses, :csys_closed_outcome)

    OUTCOMES_BY_NAME.each do |name, outcome|
      execute <<~SQL.squish
        UPDATE issue_statuses
        SET csys_closed_outcome = #{connection.quote(outcome)}
        WHERE LOWER(name) = #{connection.quote(name)} AND is_closed = #{connection.quoted_true}
      SQL
    end
  end

  def down
    remove_index :issue_statuses, :csys_closed_outcome if index_exists?(:issue_statuses, :csys_closed_outcome)
    remove_column :issue_statuses, :csys_closed_outcome if column_exists?(:issue_statuses, :csys_closed_outcome)
  end
end
