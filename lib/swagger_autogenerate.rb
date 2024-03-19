# frozen_string_literal: true

module SwaggerAutogenerate
  extend ::ActiveSupport::Concern

  REQUESTBODYJSON = false
  REQUESTBODYFORMDATA = true
  KEY_ORDER = [:tags, :summary, :requestBody, :parameters, :responses, :security]
  WITH_CONFIG = false

  included do
    if Rails.env.test? && ENV['SWAGGER'].present?
      after_action  { SwaggerTrace.new(request, response).call }
    end
  end

  class SwaggerTrace

    def initialize(request, response)
      @request = request
      @response = response
      @@paths = {}
    end

    def call
      read_swaggger_trace
      write_swaggger_trace
    end

    private

    attr_reader :request, :response, :current_path, :yaml_file

    # main methods

    def read_swaggger_trace
      path = request.path

      request.path_parameters.except(:controller, :format, :action).each do |k, v|
        path = path.gsub!(v, "{#{k}}")
      end

      @current_path = path
      full_path = URI.parse(request.path).path
      method = request.method.to_s.downcase
      hash =
        {
          method => {
            'tags' => tags,
            'summary' => summary,
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
      if paths[current_path][request.method.downcase].present?
        paths[current_path][request.method.downcase]['responses'] = swagger_response
      end

      if File.exist?(swagger_location)
        edit_file
      else
        create_file
      end
    end

    def create_file
      File.open(swagger_location, 'w') do |file|
        data = WITH_CONFIG ? swagger_config : {}
        data['paths'] = paths
        organize_result(data['paths'])
        data = data.to_hash
        result = add_quotes_to_dates(YAML.dump(data))
        file.write(result)
      end
    end

    def edit_file
      @yaml_file = YAML.load(
        File.read(swagger_location),
        aliases: true,
        permitted_classes: [Symbol, Date, ActiveSupport::HashWithIndifferentAccess]
      )

      return create_file if yaml_file.nil? || yaml_file['paths'].nil?

      yaml_file.merge!(swagger_config) if WITH_CONFIG

      apply_yaml_file_changes
      organize_result(yaml_file['paths'])
      @yaml_file = convert_to_hash(yaml_file)
      File.open(swagger_location, 'w') do |file|
        result = add_quotes_to_dates(YAML.dump(yaml_file))
        file.write(result)
      end
    end

    # Helpers

    def add_quotes_to_dates(string)
      string = remove_quotes_in_dates(string)
      string.gsub(/\b\d{4}-\d{2}-\d{2}\b/, "'\\0'")
    end

    def remove_quotes_in_dates(string)
      string.gsub(/'(\d{4}-\d{2}-\d{2})'/, '\1')
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

    def tags
      [ENV['tag'] || controller_name]
    end

    def summary
      URI.parse(request.path).path
    end

    def response_status
      {
        100 => 'The initial part of the request has been received, and the client should proceed with sending the remainder of the request',
        101 => 'The server agrees to switch protocols and is acknowledging the client\'s request to change the protocol being used',
        200 => 'The request has succeeded',
        201 => 'The request has been fulfilled, and a new resource has been created as a result. The newly created resource is returned in the response body',
        202 => 'The request has been accepted for processing, but the processing has not been completed. The response may contain an estimated completion time or other status information',
        204 => 'The server has successfully processed the request but does not need to return any content. It is often used for requests that don\'t require a response body, such as DELETE requests',
        300 => 'The requested resource has multiple choices available, each with its own URI and representation. The client can select one of the available choices',
        301 => 'The requested resource has been permanently moved to a new location, and any future references to this resource should use the new URI provided in the response',
        302 => 'The requested resource has been temporarily moved to a different location. The client should use the URI specified in the response for future requests',
        304 => 'The client\'s cached copy of a resource is still valid, and there is no need to transfer a new copy. The client can use its cached version',
        400 => 'The server cannot understand the request due to a client error, such as malformed syntax or invalid parameters',
        401 => 'The request requires user authentication. The client must provide valid credentials (e.g., username and password) to access the requested resource',
        403 => 'The server understood the request, but the client does not have permission to access the requested resource',
        404 => 'The requested resource could not be found on the server',
        405 => 'The requested resource does not support the HTTP method used in the request (e.g., GET, POST, PUT, DELETE)',
        409 => 'The request could not be completed due to a conflict with the current state of the target resource. The client may need to resolve the conflict before resubmitting the request',
        422 => 'The server understands the content type of the request entity but was unable to process the contained instructions',
        500 => 'The server encountered an unexpected condition that prevented it from fulfilling the request',
        502 => 'The server acting as a gateway or proxy received an invalid response from an upstream server',
        503 => 'The server is currently unable to handle the request due to temporary overload or maintenance. The server may provide a Retry-After header to indicate when the client can try the request again',
        504 => 'The server acting as a gateway or proxy did not receive a timely response from an upstream server'
      }
    end

    def response_description
      response_status[response.status]
    end

    def swagger_response
      hash = {}
      begin
        swagger_response = JSON.parse(response.body)
      rescue JSON::ParserError
        swagger_response = { 'file' => 'file/data' }
      end

      hash['description'] = response_description
      hash['headers'] = {} # response.headers
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
      @@paths ||= {}
    end

    def security
      [
        'org_slug' => [],
        'locale' => []
      ]
    end

    def controller_name
      request.params['controller'].split('/').last.to_s
    end

    def swagger_location
      return @swagger_location if instance_variable_defined?(:@swagger_location)

      if ENV['SWAGGER'].include?('.yaml') || ENV['SWAGGER'].include?('.yml')
        @swagger_location = "#{Rails.root}/#{ENV.fetch('SWAGGER', nil)}"
      else
        directory_path = "#{Rails.root}/#{ENV.fetch('SWAGGER', nil)}"
        FileUtils.mkdir_p(directory_path) unless File.directory?(directory_path)
        @swagger_location = "#{directory_path}/#{tags.first}.yaml"
      end
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

    def new_example
      current_example = swagger_response[response.status.to_s]['content']['application/json']['examples']['example-0']
      old_examples = old_paths[current_path][request.method.downcase]['responses'][response.status.to_s]['content']['application/json']['examples']

      unless old_examples.value?(current_example)
        last_example = json_example_plus_one(old_examples.keys.last)
        last_example = 'example-0' unless last_example
        yaml_file['paths'][current_path][request.method.downcase]['responses'][response.status.to_s]['content']['application/json']['examples'][last_example] = current_example
      end

      true
    end

    def apply_yaml_file_changes
      (check_path || check_method || check_status) &&
      (check_parameters || check_parameter) &&
      (check_request_bodys || check_request_body)
    end

    def old_paths
      yaml_file['paths']
    end

    # checks

    def organize_result(current_paths)
      new_hash = {
        'tags' => tags,
        'summary' => summary
      }
      new_hash['parameters'] = current_paths[current_path][request.method.downcase]['parameters'] if current_paths[current_path][request.method.downcase]['parameters']
      new_hash['requestBody'] = current_paths[current_path][request.method.downcase]['requestBody'] if current_paths[current_path][request.method.downcase]['requestBody']
      new_hash['responses'] = current_paths[current_path][request.method.downcase]['responses']
      new_hash['security'] = security

      current_paths[current_path][request.method.downcase] = new_hash
    end

    def check_path
      unless old_paths.key?(current_path)
        yaml_file['paths'].merge!({ current_path => paths[current_path] })
      end
    end

    def check_method
      unless old_paths[current_path].key?(request.method.downcase)
        yaml_file['paths'][current_path][request.method.downcase] = { 'responses' => swagger_response }
      end
    end

    def check_status
      if old_paths[current_path][request.method.downcase]['responses'].present?
        if old_paths[current_path][request.method.downcase]['responses']&.key?(response.status.to_s)
          new_example
        else
          yaml_file['paths'][current_path][request.method.downcase]['responses'].merge!(swagger_response)
        end
      else
        yaml_file['paths'][current_path][request.method.downcase]['responses'] = swagger_response
      end
    end

    def check_parameters
      unless old_paths[current_path][request.method.downcase]['parameters'].present?
        yaml_file['paths'][current_path][request.method.downcase]['parameters'] = paths[current_path][request.method.downcase]['parameters']
      end
    end

    def check_parameter
      param_names = paths[current_path][request.method.downcase]['parameters'].pluck('name') - yaml_file['paths'][current_path][request.method.downcase]['parameters'].pluck('name')
      param_names.each do |param_name|
        param = paths[current_path][request.method.downcase]['parameters'].find{ |parameter| parameter['name'] == param_name }
        yaml_file['paths'][current_path][request.method.downcase]['parameters'].push(param)
      end
    end

    def check_request_bodys
      if paths[current_path][request.method.downcase]['requestBody'].present? && old_paths[current_path][request.method.downcase]['requestBody'].nil?
        yaml_file['paths'][current_path][request.method.downcase]['requestBody'] = paths[current_path][request.method.downcase]['requestBody']
      end
    end

    def check_request_body
      if paths[current_path][request.method.downcase]['requestBody'].present?
        param_names = paths[current_path][request.method.downcase]['requestBody']['content']['multipart/form-data']['schema']['properties'].keys - yaml_file['paths'][current_path][request.method.downcase]['requestBody']['content']['multipart/form-data']['schema']['properties'].keys
        param_names.each do |param_name|
          param = paths[current_path][request.method.downcase]['requestBody']['content']['multipart/form-data']['schema']['properties'].select { |parameter| parameter == param_name }
          yaml_file['paths'][current_path][request.method.downcase]['requestBody']['content']['multipart/form-data']['schema']['properties'].merge!(param)
        end
      end
    end

    def swagger_config
      {
        'openapi' => '3.0.0',
        'info' => {
          'title' => 'title',
          'description' => 'description',
          'version' => '1.0.0'
        },
        'servers' => [],
        'components' => {
          'securitySchemes' => {
            'locale' => {
              'type' => 'apiKey',
              'in' => 'query',
              'name' => 'locale'
            }
          }
        }
      }
    end
  end
end
