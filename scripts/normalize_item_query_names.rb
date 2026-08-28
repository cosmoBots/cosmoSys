locale = ENV.fetch('REDMINE_LANG', 'en').to_sym

query_names = {
  label_assigned_to_me_issues: ['Issues assigned to me', 'Peticiones que me están asignadas'],
  label_reported_issues: ['Reported issues', 'Peticiones registradas por mí'],
  label_updated_issues: ['Updated issues', 'Peticiones actualizadas'],
  label_watched_issues: ['Watched issues', 'Peticiones monitorizadas']
}.freeze

updated = 0
query_names.each do |translation_key, legacy_names|
  updated += IssueQuery.where(user_id: 0, project_id: nil, name: legacy_names)
                       .update_all(name: I18n.t(translation_key, locale: locale))
end

puts "Normalized #{updated} built-in item query name(s)."
