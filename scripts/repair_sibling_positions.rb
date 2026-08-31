require 'optparse'

options = { apply: false }
OptionParser.new do |parser|
  parser.banner = 'Usage: rails runner repair_sibling_positions.rb --project IDENTIFIER --parent ISSUE_ID [--apply]'
  parser.on('--project IDENTIFIER', 'Project tree containing the parent') { |value| options[:project] = value }
  parser.on('--parent ISSUE_ID', Integer, 'Parent issue whose direct children will be renumbered') { |value| options[:parent_id] = value }
  parser.on('--apply', 'Persist the proposed csposition values') { options[:apply] = true }
end.parse!(ARGV)

abort 'Missing --project IDENTIFIER' if options[:project].blank?
abort 'Missing --parent ISSUE_ID' if options[:parent_id].blank?

project = Project.find_by!(identifier: options[:project])
parent = Issue.find(options[:parent_id])
project_ids = project.root.self_and_descendants.pluck(:id)
abort "Issue ##{parent.id} is outside project tree #{project.identifier}" unless project_ids.include?(parent.project_id)

children = parent.children.reorder(:lft, :id).to_a
changes = children.each.with_index(1).filter_map do |issue, position|
  [issue, position] unless issue.csposition == position
end

if changes.empty?
  puts "No sibling positions need repair below ##{parent.id}."
  exit
end

changes.each do |issue, position|
  puts format('#%<id>d %<csid>s: %<before>d -> %<after>d  %<subject>s',
              id: issue.id, csid: issue.csid, before: issue.csposition, after: position, subject: issue.subject)
end

unless options[:apply]
  puts 'Dry run only. Repeat with --apply to persist these changes.'
  exit
end

Issue.transaction { Cosmosys::SiblingOrder.align_with_tree!(parent.children) }
puts "Repaired #{changes.length} sibling positions below ##{parent.id}."
