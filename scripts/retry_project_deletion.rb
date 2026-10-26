# Explicit administrative recovery, never an automatic retry or a tree rebuild.
admin = User.active.find_by(login: ENV.fetch('ADMIN_LOGIN'))
abort 'An active administrator is required' unless admin&.admin?
project = Project.find(Integer(ENV.fetch('PROJECT_ID'), 10))
abort 'Only projects scheduled for deletion can be retried' unless project.scheduled_for_deletion?
previous_user = User.current
begin
  User.current = admin
  context = Cosmosys::ProjectDeletionContext.new(project).validate!
  puts "Project #{project.id} (#{project.identifier}); subtree IDs: #{context.project_ids.join(', ')}"
  unless ENV['APPLY'] == '1'
    puts 'Read-only. Back up the database and files, ensure the previous job has stopped, then set APPLY=1, BACKUP_CONFIRMED=1 and CONFIRM_IDENTIFIER.'
    exit
  end
  abort 'Backup confirmation required' unless ENV['BACKUP_CONFIRMED'] == '1'
  abort 'Exact project identifier confirmation required' unless ENV['CONFIRM_IDENTIFIER'] == project.identifier
  # Revalidates under Redmine's forest locks. No status reset or SQL deletes.
  project.destroy!
  puts 'Project subtree deleted through ActiveRecord callbacks.'
ensure
  User.current = previous_user
end
