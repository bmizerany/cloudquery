require "rubygems"
require "uri"
require "digest/sha1"
require "base64"
require "rack/utils"
require "curl"
require "json"

module Cloudquery
  SCHEME = "https".freeze
  HOST = "api.xoopit.com".freeze
  PATH = "/v0".freeze

  API_PATHS = {
    :account => "account".freeze,
    :schema => "schema".freeze,
    :indexes => "i".freeze,
    :documents => "i".freeze,
  }.freeze
  
  # standard Content-Types for requests
  CONTENT_TYPES = {
    :json => 'application/json;charset=utf-8'.freeze,
    :form => 'application/x-www-form-urlencoded'.freeze,
    :xml  => 'application/xml;charset=utf-8'.freeze,
  }.freeze
  

  SIGNING_METHOD = "SHA1".freeze
  COOKIE_JAR = ".cookies.lwp".freeze

  class Request
    attr_accessor :method, :headers, :scheme, :host, :port, :path, :params, :body

    def initialize(options={})
      @method = options[:method] || 'POST'
      @headers = options[:headers] || {}
      @scheme = options[:scheme] || SCHEME
      @host = options[:host] || HOST
      @port = options[:port] || (@scheme == 'https' ? URI::HTTPS::DEFAULT_PORT : URI::HTTP::DEFAULT_PORT)
      @path = options[:path] || PATH
      @params = options[:params] || {}
      if ['PUT', 'DELETE'].include?(@method)
        @params['_method'] = @method
        @method = 'POST'
      end
      @body = options[:body]
      
      @account = options[:account]
      @secret = options[:secret]
    end

    def request_uri(account=@account, secret=@secret)
      query = query_str(signature_params(account))
      uri = if query.empty?
        @path.dup
      else
        "#{@path}?#{query}"
      end
      uri = append_signature(uri, secret) if secret
      uri
    end

    def url(account=@account, secret=@secret)
      base_uri.merge(request_uri(account, secret)).to_s
    end

    private
    def append_signature(uri, secret)
      sig = Crypto::URLSafeSHA1.sign(secret, uri)
      x_sig = Rack::Utils.build_query("x_sig" => sig)
      "#{uri}&#{x_sig}"
    end

    def signature_params(account=@account)
      return {} unless account
      {
        'x_name' => account,
        'x_time' => Time.now.to_i_with_milliseconds,
        'x_nonce' => Cloudquery::Crypto::Random.nonce,
        'x_method' => SIGNING_METHOD,
      }
    end

    def query_str(additional_params={})
      Rack::Utils.build_query(@params.dup.merge(additional_params))
    end

    def base_uri
      uri_class = (@scheme == 'https' ? URI::HTTPS : URI::HTTP)
      uri_class.build(:scheme => @scheme, :host => @host, :port => @port)
    end

  end

  module Crypto
    module Random
      extend self

      SecureRandom = (defined?(::SecureRandom) && ::SecureRandom) || (defined?(::ActiveSupport::SecureRandom) && ::ActiveSupport::SecureRandom)
      if SecureRandom
        def nonce
          "#{SecureRandom.random_number}.#{Time.now.to_i}"[2..-1]
        end
      else
        def nonce
          "#{rand.to_s}.#{Time.now.to_i}"[2..-1]
        end
      end

    end

    module URLSafeSHA1
      extend self

      def sign(*tokens)
        tokens = tokens.flatten
        digest = Digest::SHA1.digest(tokens.join)
        Base64.encode64(digest).chomp.tr('+/', '-_')
      end

    end
  end

  class Client
    attr_reader :account
    attr_writer :secret

    def initialize(options={})
      # unless options[:account] && options[:secret]
      #   raise "Client requires :account => <account name> and :secret => <secret>"
      # end
      
      @account = options[:account]
      @secret = options[:secret]
      
      @secure = options[:secure] != false # must pass false for insecure
      
      @document_id_method = nil
    end

    # Account management
    
    def self.get_secret(account, password)
      auth = Request.new(:path => "#{PATH}/auth")
      curl = Curl::Easy.new(auth.url) do |c|
        c.enable_cookies = true
        c.cookiejar = COOKIE_JAR
      end
      params = Rack::Utils.build_query({"name" => account, "password" => password})
      curl.http_post(params)
      
      if curl.response_code == 200
        curl.url = Request.new(:path => "#{PATH}/#{API_PATHS[:account]}/#{account}").url
        curl.http_get
        response = JSON.parse(curl.body_str)
        response['result']['secret']
      else
        STDERR.puts "Error: #{curl.response_code} #{Rack::Utils::HTTP_STATUS_CODES[curl.response_code]}"
      end
    end

    def get_account
      send_request get(account_path)
    end
    
    def update_account(account_doc={})
      body = JSON.generate(account_doc)
      send_request put(account_path, body)
    end
    
    def delete_account
      send_request delete(account_path)
    end
    
    def account_path
      build_path(API_PATHS[:account], @account)
    end
    
    # Schema management
    
    def add_schema(xml)
      body = xml.instance_of?(File) ? xml.read : xml
      request = post(build_path(API_PATHS[:schema]), body)
      send_request(request, CONTENT_TYPES[:xml])
    end
    
    def delete_schema(schema_name)
      send_request delete(build_path(
        API_PATHS[:schema],
        Rack::Utils.escape("xfs.schema.name:\"#{schema_name}\"")
      ))
    end
    
    def get_schemas
      send_request get(build_path(API_PATHS[:schema]))
    end
    
    # Index management
    
    def add_indexes(*indexes)
      body = JSON.generate(indexes.flatten)
      send_request post(build_path(API_PATHS[:indexes]), body)
    end
    
    def delete_indexes(*indexes)
      indexes = url_pipe_join(indexes)
      send_request delete(build_path(API_PATHS[:indexes], indexes))
    end
    
    def get_indexes
      send_request get(build_path(API_PATHS[:indexes]))
    end
    
    # Document management
    
    def add_documents(index, docs, *schemas)
      request = post(
        build_path(API_PATHS[:documents], index, url_pipe_join(schemas)),
        JSON.generate(identify_documents(docs))
      )
      send_request request
    end
    
    def update_documents(index, docs, *schemas)
      request = put(
        build_path(API_PATHS[:documents], index, url_pipe_join(schemas)),
        JSON.generate(identify_documents(docs))
      )
      send_request request
    end
    
    def modify_documents(index, query, modifications, *schemas)
      request = put(
        build_path(API_PATHS[:documents], index, url_pipe_join(schemas), Rack::Utils.escape(query)),
        JSON.generate(modifications)
      )
      send_request request
    end
    
    def delete_documents(index, query, *schemas)
      request = delete(
        build_path(API_PATHS[:documents], index, url_pipe_join(schemas), Rack::Utils.escape(query))
      )
      send_request request
    end
    
    def get_documents(index, query, options={}, *schemas)
      if fields = options.delete(:fields)
        fields = url_pipe_join(fields)
      end
      
      if options[:sort]
        options[:sort] = Array(options[:sort]).flatten.join(',')
      end
      
      request = get(
        build_path(API_PATHS[:documents], 
          index, 
          url_pipe_join(schemas),
          url_pipe_join(query),
          fields
        ),
        options
      )
      send_request request
    end
    
    def count_documents(index, query, *schemas)
      query = url_pipe_join(query)
      request = get(
        build_path(API_PATHS[:documents], 
          index, 
          url_pipe_join(schemas),
          url_pipe_join(query),
          '@count'
        )
      )
      send_request request
    end
    
    private
    def build_path(*path_elements)
      path_elements.flatten.compact.unshift(PATH).join('/')
    end
    
    def build_request(options={})
      Request.new default_request_params.merge(options)
    end
    
    def get(path, params={})
      build_request(:method => 'GET', :path => path, :params => params)
    end
    
    def delete(path, params={})
      build_request(:method => 'DELETE', :path => path, :params => params)
    end
    
    def post(path, doc, params={})
      build_request(:method => 'POST', :path => path, :body => doc, :params => params)
    end
    
    def put(path, doc, params={})
      build_request(:method => 'PUT', :path => path, :body => doc, :params => params)
    end
    
    def default_request_params
      {
        :account => @account,
        :secret => @secret,
        :scheme => @secure ? 'https' : 'http',
      }
    end
    
    def send_request(request, content_type=nil)
      response = execute_request(request.method, request.url, request.headers, request.body, content_type)
      status_code = response.first
      if (200..299).include?(status_code)
        begin
          result = JSON.parse(response.last)
        rescue JSON::ParserError => e
          result = {"REASON" => e.message}
        end
      else
        result = {"REASON" => "Error: #{status_code} #{Rack::Utils::HTTP_STATUS_CODES[status_code]}"}
      end
      result.merge!({'STATUS' => status_code})
    end

    def execute_request(method, url, headers, body, content_type=nil)
      content_type ||= CONTENT_TYPES[:json]
      curl = Curl::Easy.new(url) do |c|
        c.headers = headers
        c.headers['Content-Type'] = content_type
        c.encoding = 'gzip'
      end
      case method
      when 'GET'
        curl.http_get
      when 'DELETE'
        curl.http_delete
      when 'POST'
        curl.http_post(body)
      when 'PUT'
        curl.http_put(body)
      end
      
      [curl.response_code, curl.header_str, curl.body_str]
    end

    def url_pipe_join(arr, default_value='*')
      arr = Array(arr).flatten
      if arr.empty?
        default_value
      else
        Rack::Utils.escape(arr.join('|'))
      end
    end
    
    def identify_documents(docs)
      [docs] if docs.is_a?(Hash)
      if @document_id_method
        docs.each { |d| d.send(@document_id_method) }
      end
      docs
    end
  end
end


class Time
  def to_i_with_milliseconds
    (to_f * 1000).to_i
  end
end
