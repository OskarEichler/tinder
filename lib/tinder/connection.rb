# encoding: UTF-8
require 'faraday'
require 'faraday/request/multipart'
require 'faraday/response/raise_on_authentication_failure'
require 'faraday/response/remove_whitespace'
require 'faraday_middleware'
require 'json'
require 'uri'

class Faraday::RequestOptions
  attr_accessor :preserve_raw
end

module Tinder
  class Connection
    HOST = 'campfirenow.com'

    attr_reader :subdomain, :uri, :options

    def self.connection
      @connection ||= Faraday.new do |builder|
        builder.use     FaradayMiddleware::EncodeJson
        builder.use     FaradayMiddleware::Mashify
        builder.use     FaradayMiddleware::ParseJson
        builder.use     Faraday::Response::RemoveWhitespace
        builder.use     Faraday::Response::RaiseOnAuthenticationFailure
        builder.adapter Faraday.default_adapter
      end
    end

    def self.raw_connection
      @raw_connection ||= Faraday.new do |builder|
        builder.use     Faraday::Request::Multipart
        builder.use     FaradayMiddleware::Mashify
        builder.use     FaradayMiddleware::ParseJson
        builder.use     Faraday::Response::RemoveWhitespace
        builder.use     Faraday::Response::RaiseOnAuthenticationFailure
        builder.adapter Faraday.default_adapter
      end
    end

    def initialize(subdomain, options = {})
      @subdomain = subdomain
      @options = {:ssl => true, :ssl_options => {:verify => true}, :proxy => ENV['HTTP_PROXY']}
      @options[:ssl_options][:verify] = options.delete(:ssl_verify) unless options[:ssl_verify].nil?
      @options.merge!(options)
      @uri = URI.parse("#{@options[:ssl] ? 'https' : 'http' }://#{subdomain}.#{HOST}")
      @token = options[:token]
      @oauth_token = options[:oauth_token]

      if @oauth_token
        connection.headers["Authorization"] = "Bearer #{@oauth_token}"
        raw_connection.headers["Authorization"] = "Bearer #{@oauth_token}"
      else
        connection.basic_auth token, 'X'
        raw_connection.basic_auth token, 'X'
      end
    end

    def basic_auth_settings
      {:username => token, :password => 'X'}
    end

    def connection
      @connection ||= begin
        conn = self.class.connection.dup
        set_connection_options(conn)
        conn
      end
    end

    def raw_connection
      @raw_connection ||= begin
        conn = self.class.raw_connection.dup
        set_connection_options(conn)
        conn
      end
    end

    def token
      @token ||= begin
        connection.basic_auth(options[:username], options[:password])
        get('/users/me.json')['user']['api_auth_token']
      end
    end

    def get(url, *args)
      response = connection.get(url, *args)
      response.body
    end

    def post(url, body = nil, *args)
      response = connection.post(url, body, *args)
      response.body
    end

    def raw_post(url, body = nil, *args)
      raw_connection.post(url, body, *args)
    end

    def put(url, body = nil, *args)
      response = connection.put(url, body, *args)
      response.body
    end

    # Is the connection to campfire using ssl?
    def ssl?
      uri.scheme == 'https'
    end

  private
    def set_connection_options(conn)
      conn.url_prefix = @uri.to_s
      # conn.proxy [:options][:proxy]
      # if options[:ssl_options]
      #   conn.ssl.merge!(options[:ssl_options])
      # end
    end
  end
end
