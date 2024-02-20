# frozen_string_literal: true

require_relative "swagger_autogenerate/version"

module SwaggerAutogenerate
  extend ::ActiveSupport::Concern

  REQUESTBODYJSON = false
  REQUESTBODYFORMDATA = true

  included do
    if Rails.env.test? && ENV['SWAGGER'].present?
      before_action :read_swaggger_trace
      after_action :write_swaggger_trace
    end
  end

  private

  # main methods

  def read_swaggger_trace
    path = request.path

    request.path_parameters.except(:controller, :format, :action).each do |k, v|
      path = path.gsub!(v, "{#{k}}")
    end

    full_path = URI.parse(request.path).path
    method = request.method.to_s.downcase
    tag = ENV['tag'] || controller_name
    hash =
      {
        method => {
          'tags' => [tag],
          'summary' => full_path,
          'requestBody' => request_body,
          'parameters' => parameters,
          'responses' => {},
          'security' => security
        }
      }

    hash[method].except!('requestBody') if hash[method]['requestBody'].blank?
    paths[path.to_s] ||= {}
    paths[path.to_s].merge!(hash)
  end

  def write_swaggger_trace
    if paths[paths.keys.last][request.method.downcase].present?
      paths[paths.keys.last][request.method.downcase]['responses'] = swagger_response
    end

    if File.exist?(swagger_location)
      edit_file
    else
      create_file
    end
  end

  def create_file
    File.open(swagger_location, 'w') do |file|
      data = {}
      data['paths'] = paths
      data = data.to_hash
      result = add_quotes_to_dates(YAML.dump(data))
      file.write(result)
    end
  end

  def edit_file
    yaml_file = YAML.load(
      File.read(swagger_location),
      aliases: true,
      permitted_classes: [Symbol, Date, ActiveSupport::HashWithIndifferentAccess]
    )

    apply_yaml_file_changes(yaml_file)
    yaml_file = convert_to_hash(yaml_file)
    File.open(swagger_location, 'w') do |file|
      result = add_quotes_to_dates(YAML.dump(yaml_file))
      file.write(result)
    end
  end

  # Helpers

  def add_quotes_to_dates(string)
    string.gsub(/\b\d{4}-\d{2}-\d{2}\b/, "'\\0'")
  end

  def convert_to_hash(obj)
    case obj
    when ActiveSupport::HashWithIndifferentAccess
      obj.to_hash
    when Hash
      obj.transform_values { |value| convert_to_hash(value) }
    when Array
      obj.map { |item| convert_to_hash(item) }
    else
      obj
    end
  end

  def properties_data(value)
    hash = {}

    value.map do |k, v|
      type = schema_type(v)
      hash.merge!({ k => { 'type' => type, 'example' => convert_to_hash(v) } })
    end

    hash
  end

  def schema_data(value)
    type = schema_type(value)
    hash = { 'type' => type }

    hash['properties'] = properties_data(value) if type == 'object'

    hash
  end

  def set_parameters(parameters, parameter)
    return if parameter.blank?

    parameter.values.first.each do |key, value|
      hash =
        {
          'name' => key.to_s,
          'in' => parameter.keys.first.to_s,
          'schema' => schema_data(value),
          'example' => example(value)
        }
      hash.except!('example') if hash['example'].blank?

      parameters.push(hash)
    end
  end

  def request_body
    content_body(request.request_parameters) if request.request_parameters.present?
  end

  def response_description
    return 'Successful response' if (response.status == 200) || (response.status == 201)

    I18n.t("errors.e_#{response.status}")
  end

  def swagger_response
    hash = {}
    begin
      swagger_response = JSON.parse(response.body)
    rescue JSON::ParserError
      swagger_response = { 'file' => 'file' }
    end

    hash['description'] = response_description
    hash['headers'] = {}
    hash['content'] = content_json_example(swagger_response)

    {
      response.status.to_s => hash
    }
  end

  def convert_to_multipart(payload)
    payload.each do |key, value|
      if value.is_a?(Hash)
        payload_keys.push(key)
        convert_to_multipart(value)
      else
        keys = payload_keys.clone
        first_key = keys.shift
        keys.each { |inner_key| first_key = "#{first_key}[#{inner_key}]" }
        first_key = "#{first_key}[#{key}]"

        payload_hash.merge!({ first_key => { 'type' => schema_type(value), 'example' => value } })
      end
    end
  end

  def content_form_data(data)
    convert_to_multipart(data)
    converted_payload = @payload_hash.clone
    @payload_hash = nil
    @payload_keys = nil

    {
      'multipart/form-data' => {
        'schema' => {
          'type' => 'object',
          'properties' => converted_payload
        }
      }
    }
  end

  def content_body(data)
    hash = {}
    hash.merge!(content_json(data)) if REQUESTBODYJSON
    hash.merge!(content_form_data(data)) if REQUESTBODYFORMDATA

    { 'content' => hash }
  end

  def number?(value)
    true if Float(value)
  rescue StandardError
    false
  end

  def schema_type(value)
    return 'integer' if number?(value)
    return 'boolean' if (value.try(:downcase) == 'true') || (value.try(:downcase) == 'false')
    return 'string' if value.instance_of?(String) || value.instance_of?(Symbol)
    return 'array' if value.instance_of?(Array)

    'object'
  end

  def example(value)
    return value.to_i if number?(value)
    return value if value.instance_of?(String) || value.instance_of?(Symbol)

    nil
  end

  # parameters

  def parameters
    parameters = []

    set_parameters(parameters, path_parameters)
    set_parameters(parameters, request_parameters) if request.request_parameters.blank?
    set_parameters(parameters, query_parameters)

    parameters
  end

  def request_parameters
    { body: request.request_parameters }
  end

  def query_parameters
    { query: request.query_parameters }
  end

  def path_parameters
    { path: request.path_parameters.except(:controller, :format, :action) }
  end

  # Static

  def paths
    $swagger_paths ||= {}
  end

  def security
    [
      'Access-Token' => [],
      'org_slug' => [],
      'locale' => []
    ]
  end

  def controller_name
    request.params['controller'].split('/').last.to_s
  end

  def swagger_location
    "#{Rails.root}/#{ENV.fetch('SWAGGER', nil)}.yaml"
  end

  def content_json(data)
    {
      'application/json' => {
        'schema' => { 'type' => 'object' },
        'example' => data
      }
    }
  end

  def content_json_example(data)
    {
      'application/json' => {
        'schema' => { 'type' => 'object' },
        'examples' => {
          'example-0' => {
            'summary' => '',
            'value' => data
          }
        }
      }
    }
  end

  def json_example_plus_one(string)
    if string =~ /-(\d+)$/
      numeric_part = $1.to_i
      modified_numeric_part = numeric_part + 1
      string.sub(/-(\d+)$/, "-#{modified_numeric_part}")
    else
      string
    end
  end

  def payload_keys
    @payload_keys ||= []
  end

  def payload_hash
    @payload_hash ||= {}
  end

  def apply_yaml_file_changes(yaml_file)
    check_path(yaml_file) || check_method(yaml_file) || check_status(yaml_file) || check_examples(yaml_file)
  end

  # checks

  def check_path(yaml_file)
    old_paths = yaml_file['paths']
    unless old_paths.key?(paths.keys.last)
      yaml_file['paths'].merge!(paths)
    end
  end

  def check_method(yaml_file)
    old_paths = yaml_file['paths']
    unless old_paths[paths.keys.last].key?(request.method.downcase)
      yaml_file['paths'][paths.keys.last][request.method.downcase] = { 'responses' => {response.status.to_s => swagger_response[response.status.to_s]} }
    end
  end

  def check_status(yaml_file)
    old_paths = yaml_file['paths']
    debugger if response.status.to_s != '200'
    if old_paths[paths.keys.last][request.method.downcase]['responses'].present?
      unless old_paths[paths.keys.last]['responses']&.key?(response.status.to_s)
        yaml_file['paths'][paths.keys.last][request.method.downcase]['responses'][response.status.to_s] = swagger_response[response.status.to_s]
      end
    else
      yaml_file['paths'][paths.keys.last][request.method.downcase]['responses'] = { response.status.to_s => swagger_response }
    end
  end

  def check_examples(yaml_file)
    old_paths = yaml_file['paths']

    examples = old_paths[paths.keys.last][request.method.downcase]['responses'][response.status.to_s]['content']['application/json']['examples']
    last_example = json_example_plus_one(examples.keys.last)
    if last_example
      yaml_file['paths'][paths.keys.last][request.method.downcase]['responses'][response.status.to_s]['content']['application/json']['examples'][last_example] = swagger_response[response.status.to_s]['content']['application/json']['examples']['example-0']
    else
      yaml_file['paths'].merge!(paths)
    end
  end
end
