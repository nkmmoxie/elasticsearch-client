require "elasticsearch/version"
require 'faraday'
require 'faraday_middleware'
require 'yajl'
require 'time'

module ElasticSearch
  class JSONResponse < Faraday::Response::Middleware
    def parse(body)
      Yajl.load body
    end
  end

  class Error < StandardError
  end

  def self.get_connection(server)
    return unless server

    Faraday.new(:url => server) do |builder|
      # TODO: add timeout middleware
      builder.request  :json
      # builder.response :logger
      builder.response :json, :content_type => /\bjson$/

      builder.adapter :excon
    end
  end

  def self.available?
    conn = get_connection
    resp = conn.get '/'
    resp.status == 200
  end

  # Object to represent an index in elasticsearch
  class Index
    @@conn = nil
    def initialize(name, server)
      @name = name
      if @@conn.blank?
        @@conn = ElasticSearch.get_connection(server)
      end
      @conn = @@conn
    end

    # Some helpers for making REST calls to elasticsearch
    %w[ get post put delete ].each do |method|
      class_eval <<-EOC, __FILE__, __LINE__
        def #{method}(*args, &blk)
          raise Error, "no connection" unless @conn
          resp = @conn.#{method}(*args, &blk)
          raise Error, "elasticsearch server is offline or not accepting requests" if resp.status == 0
          raise Error, resp.body['error'] if resp.body['error']
          @last_resp = resp
          resp.body
        end
      EOC
    end

    # Force a refresh of this index
    #
    # This basically tells elasticsearch to flush it's buffers
    # but not clear caches (unlike a commit in Solr)
    # "Commits" happen automatically and are managed by elasticsearch
    #
    # Returns a hash, the parsed response body from elasticsearch
    def refresh
      post "/#{@name}/_refresh"
    end

    def bulk(data)
      return if data.empty?
      body = post "/#{@name}/_bulk", data
      raise Error, "bulk import got HTTP #{@last_resp.status} response" if @last_resp.status != 200
    end

    # Grab a bunch of items from this index
    #
    #   type - the type to pull from
    #   ids  - an Array of ids to fetch
    #
    # Returns a hash, the parsed response body from elasticsearch
    def mget(type, ids)
      get do |req|
        req.url "#{@name}/#{type}/_mget"
        req.body = {'ids' => ids}
      end
    end

    # Search this index using a post body
    #
    #   types   - the type or types (comma seperated) to search
    #   options - options hash for this search request
    #
    # Returns a hash, the parsed response body from elasticsearch
    def search(types, options)
      get do |req|
        req.url "#{@name}/#{types}/_search"
        req.body = options
      end
    end

    # Search this index using a query string
    #
    #   types   - the type or types (comma seperated) to search
    #   query   - the search query string
    #   options - options hash for this search request (optional)
    #
    # Returns a hash, the parsed response body from elasticsearch
    def query(types, query, options=nil)
      query = {'q' => query} if query.is_a?(String)
      get do |req|
        req.url "#{@name}/#{types}/_search", query
        req.body = options if options
      end
    end

    # Count results using a query string
    #
    #   types   - the type or types (comma seperated) to search
    #   query   - the search query string
    #   options - options hash for this search request (optional)
    #
    # Returns a hash, the parsed response body from elasticsearch
    def count(types, query, options=nil)
      query = {'q' => query} if query.is_a?(String)
      get do |req|
        req.url "#{@name}/#{types}/_count", query
        req.body = options if options
      end
    end

    # Add a document to this index
    #
    #   type - the type of this document
    #   id   - the unique identifier for this document
    #   doc  - the document to be indexed
    #
    # Returns a hash, the parsed response body from elasticsearch
    def add(type, id, doc, params={})
      doc.each do |key, val|
        # make sure dates are in a consistent format for indexing
        doc[key] = val.iso8601 if val.respond_to?(:iso8601)
      end

      put do |req|
        req.url "/#{@name}/#{type}/#{id}", params
        req.body = doc
      end
    end

    # Remove a document from this index
    #
    #   type - the type of document to be removed
    #   id   - the unique identifier of the document to be removed
    #
    # Returns a hash, the parsed response body from elasticsearch
    def remove(type, id)
      delete do |req|
        req.url "#{@name}/#{type}/#{id}"
      end
    end

    # Remove all of a type from this index
    #
    #   type - the type of document to be removed
    #
    # Returns a hash, the parsed response body from elasticsearch
    def remove_all(type)
      delete do |req|
        req.url "#{@name}/#{type}/_query", :q => '*'
      end
    end

    # Remove a collection of documents matched by a query
    #
    #   types   - the type or types to query
    #   options - the search options hash
    #
    # Returns a hash, the parsed response body from elasticsearch
    def remove_by_query(types, options)
      delete do |req|
        req.url "#{@name}/#{types}/_query"
        req.body = options
      end
    end

    # Fetch the mappings defined for this index
    #
    #   types - the type or types to query
    #
    # Returns a hash, the parsed response body from elasticsearch
    def get_mapping(types)
      get do |req|
        req.url "#{@name}/#{types}/_mapping"
      end
    end

    # Adds mappings to the index
    #
    #   type    - the type we're modifying
    #   mapping - the new mapping to merge into the index
    #
    # Returns a hash, the parsed response body from elasticsearch
    def put_mapping(type, mapping)
      put do |req|
        req.url "#{@name}/#{type}/_mapping"
        req.body = mapping
      end
    end

    # Create a new index in elasticsearch
    #
    #   name           - the name of the index to be created
    #   server         - URL of the server to create the index on
    #   create_options - a hash of index creation options
    #
    # Returns a new ElasticSearch::Index instance
    def self.create(name, server, create_options={})
      conn = ElasticSearch.get_connection(server)
      conn.put do |req|
        req.url "/#{name}"
        req.body = create_options
      end

      new(name, server)
    end
  end
end
