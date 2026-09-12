require 'json'
require 'optparse'

options = { repair: false, notify_admins: false }
OptionParser.new do |parser|
  parser.banner = 'Usage: rails runner audit_issue_trees.rb [--notify-admins] [--repair --admin LOGIN]'
  parser.on('--repair', 'Repair every inconsistent project tree') { options[:repair] = true }
  parser.on('--admin LOGIN', 'Administrator recorded as repair actor') { |value| options[:admin] = value }
  parser.on('--notify-admins', 'Email active administrators when anomalies are found') { options[:notify_admins] = true }
end.parse!(ARGV)

admin = User.find_by(login: options[:admin]) if options[:admin].present?
abort '--repair requires --admin LOGIN naming an administrator' if options[:repair] && !admin&.admin?

summary = Cosmosys::IssueTreeAudit.new.call(repair: options[:repair], user: admin)
if options[:notify_admins] && summary[:inconsistent_roots].positive?
  notification = { attempted: 0, delivered: 0, errors: [] }
  User.active.where(admin: true).where.not(mail: [nil, '']).find_each do |recipient|
    notification[:attempted] += 1
    begin
      Cosmosys::IssueTreeAuditMailer.anomalies(recipient, summary).deliver_now
      notification[:delivered] += 1
    rescue StandardError => e
      notification[:errors] << { user_id: recipient.id, error: "#{e.class}: #{e.message}" }
    end
  end
  summary[:notification] = notification
end
puts JSON.pretty_generate(summary)
exit 1 if !options[:repair] && summary[:inconsistent_roots].positive?
exit 2 if options[:repair] && summary[:results].any? { |row| row[:healthy_after_repair] == false }
