# Run with rails runner. Read-only; restricted to administrators.
require 'json'
admin = User.active.find_by(login: ENV.fetch('ADMIN_LOGIN'))
abort 'An active administrator is required' unless admin&.admin?
result = Cosmosys::ProjectTreeAudit.new.call
puts JSON.pretty_generate(result)
exit(result.fetch(:healthy) ? 0 : 1)
