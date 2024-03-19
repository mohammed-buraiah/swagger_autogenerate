class ActionController::Base
  if Rails.env.test? && ENV['SWAGGER'].present?
    after_action  { SwaggerAutogenerate::SwaggerTrace.new(request, response).call }
  end
end
