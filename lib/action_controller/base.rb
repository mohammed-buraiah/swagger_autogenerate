class ActionController::Base
  after_action :swagger_autogenerate if Rails.env.test? && ENV['SWAGGER'].present?

  def swagger_autogenerate
    SwaggerAutogenerate::SwaggerTrace.new(request, response).call
  end
end
