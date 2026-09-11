require 'json'
require 'optparse'

options = { repair: false }
OptionParser.new do |parser|
  parser.banner = 'Usage: rails runner audit_issue_trees.rb [--repair --admin LOGIN]'
  parser.on('--repair', 'Repair every inconsistent project tree') { options[:repair] = true }
  parser.on('--admin LOGIN', 'Administrator recorded as repair actor') { |value| options[:admin] = value }
end.parse!(ARGV)

admin = User.find_by(login: options[:admin]) if options[:admin].present?
abort '--repair requires --admin LOGIN naming an administrator' if options[:repair] && !admin&.admin?

results = Project.where(parent_id: nil).order(:id).map do |root|
  issues = Issue.where(project_id: root.self_and_descendants.select(:id)).order(:root_id, :lft, :id).to_a
  problem = Cosmosys::IssueTreeHealth.first_problem(issues)
  row = { root_project_id: root.id, root_project: root.identifier, items: issues.length,
          healthy: problem.nil? }
  if problem
    row[:problem] = { issue_id: problem.issue.id, csid: problem.issue.csid, reason: problem.reason }
    row[:repair] = Cosmosys::IssueTreeOrderRepair.new(root, user: admin).call if options[:repair]
    row[:healthy_after_repair] = Cosmosys::IssueTreeHealth.first_problem(
      Issue.where(project_id: root.self_and_descendants.select(:id)).to_a
    ).nil? if options[:repair]
  end
  row
end

summary = { checked_roots: results.length, checked_items: results.sum { |row| row[:items] },
            inconsistent_roots: results.count { |row| !row[:healthy] }, repair: options[:repair],
            results: results.reject { |row| row[:healthy] } }
puts JSON.pretty_generate(summary)
exit 1 if !options[:repair] && summary[:inconsistent_roots].positive?
exit 2 if options[:repair] && results.any? { |row| row[:healthy_after_repair] == false }
