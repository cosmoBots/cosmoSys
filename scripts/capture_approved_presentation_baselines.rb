admin = User.find_by(admin: true)
raise 'An administrator is required to capture maturity presentation baselines' unless admin

previous_user = User.current
begin
  User.current = admin
  created = 0
  skipped = 0

  Issue.includes(:tracker, :status).find_each do |issue|
    unless issue.cosmosys_item_kind.approved_presentation_baseline == true &&
           issue.status&.cosmosys_maturity_level.to_i > Cosmosys::ApprovedPresentationBaseline::CONSOLIDATED_MATURITY_FLOOR
      skipped += 1
      next
    end
    baselines = issue.cosmosys_presentation_baselines.where(
      attribute_name: Cosmosys::ApprovedPresentationBaseline::ATTRIBUTES
    ).to_a
    complete = baselines.map(&:attribute_name).sort == Cosmosys::ApprovedPresentationBaseline::ATTRIBUTES.sort &&
               baselines.all? { |baseline| baseline.captured_maturity == issue.status.cosmosys_maturity_level }
    if complete
      skipped += 1
      next
    end

    Cosmosys::ApprovedPresentationBaseline.capture!(issue, user: admin)
    created += 1
  end

  puts "Maturity presentation baselines captured: #{created}; skipped: #{skipped}"
ensure
  User.current = previous_user
end
