definitions = {
  'cs_info' => 'csInfo',
  'cs_ref_doc' => 'csRefDoc',
  'requirement' => 'csRq'
}.freeze

connection = ActiveRecord::Base.connection

def copy_tracker_rows(connection, table, source_id:, target_id:)
  return unless connection.data_source_exists?(table)

  columns = connection.columns(table).map(&:name) - ['id']
  return unless columns.include?('tracker_id')

  quoted_columns = columns.map { |column| connection.quote_column_name(column) }.join(', ')
  selected_columns = columns.map do |column|
    column == 'tracker_id' ? connection.quote(target_id) : connection.quote_column_name(column)
  end.join(', ')

  connection.execute(<<~SQL.squish)
    INSERT INTO #{connection.quote_table_name(table)} (#{quoted_columns})
    SELECT #{selected_columns}
    FROM #{connection.quote_table_name(table)}
    WHERE tracker_id = #{connection.quote(source_id)}
    ON CONFLICT DO NOTHING
  SQL
  connection.execute(
    "DELETE FROM #{connection.quote_table_name(table)} WHERE tracker_id = #{connection.quote(source_id)}"
  )
end

def replace_tracker_rows(connection, table, source_id:, target_id:)
  return 0 unless connection.data_source_exists?(table)

  columns = connection.columns(table).map(&:name) - %w[id tracker_id]
  quoted_columns = columns.map { |column| connection.quote_column_name(column) }
  connection.execute(
    "DELETE FROM #{connection.quote_table_name(table)} WHERE tracker_id = #{connection.quote(target_id)}"
  )
  result = connection.execute(<<~SQL.squish)
    INSERT INTO #{connection.quote_table_name(table)} (tracker_id, #{quoted_columns.join(', ')})
    SELECT #{connection.quote(target_id)}, #{quoted_columns.join(', ')}
    FROM #{connection.quote_table_name(table)}
    WHERE tracker_id = #{connection.quote(source_id)}
  SQL
  result.cmd_tuples
end

summary = []

Tracker.transaction do
  definitions.each do |key, name|
    canonical = Tracker.find_by(cosmosys_key: key)
    raise "Missing canonical structural tracker #{key}" unless canonical

    duplicates = Tracker.where('LOWER(name) = ?', name.downcase).where.not(id: canonical.id).order(:id).to_a
    duplicates.each do |duplicate|
      Issue.where(tracker_id: duplicate.id).update_all(tracker_id: canonical.id)
      %w[projects_trackers custom_fields_trackers workflows].each do |table|
        copy_tracker_rows(connection, table, source_id: duplicate.id, target_id: canonical.id)
      end
      Tracker.where(id: duplicate.id).delete_all
      summary << "#{name} ##{duplicate.id} -> ##{canonical.id}"
    end
  end


  feature = Tracker.where('LOWER(name) = ?', 'feature').order(:id).first
  if feature
    definitions.each_key do |key|
      tracker = Tracker.find_by!(cosmosys_key: key)
      copied = replace_tracker_rows(connection, 'workflows', source_id: feature.id, target_id: tracker.id)
      summary << "Feature workflow -> #{tracker.name} (#{copied} rows)"
    end
  end
end

if summary.empty?
  puts 'Structural trackers already consolidated.'
else
  puts 'Structural tracker consolidation:'
  summary.each { |line| puts "- #{line}" }
end
