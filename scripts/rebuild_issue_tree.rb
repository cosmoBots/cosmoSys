issue_id = ENV['ISSUE_ID'].presence || ARGV[0].presence

abort 'Usage: bundle exec rails runner plugins/cosmosys/scripts/rebuild_issue_tree.rb ISSUE_ID=<issue_id>' if issue_id.blank?

issue = Issue.find(issue_id)
root_issue_id = issue.root_id.presence || issue.id

puts "Rebuilding issue tree for issue ##{issue.id} (root issue ##{root_issue_id})..."
Issue.rebuild_single_tree!(root_issue_id)
puts 'Done.'
