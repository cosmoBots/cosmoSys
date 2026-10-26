module Cosmosys
  class RenderRequestsController < ApplicationController
    # Standard Redmine CSRF/session checks apply, including anonymous public
    # diagrams. Knowing another user's token cannot cancel that user's request.
    def cancel
      tokens = params[:render_tokens]
      unless tokens.is_a?(Array) && tokens.size.between?(1, 32) &&
             tokens.all? { |token| token.is_a?(String) && token.match?(RenderCancellation::TOKEN_PATTERN) }
        return head :bad_request
      end
      RenderCancellation.cleanup!
      accepted = tokens.all? { |token| RenderCancellation.cancel(token, user: User.current) }
      head(accepted ? :accepted : :too_many_requests)
    end
  end
end
