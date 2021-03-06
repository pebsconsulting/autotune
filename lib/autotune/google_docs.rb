require 'uri'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'
require 'json'
require 'date'

module Autotune
  class GoogleDocs
    attr_reader :client

    def self.parse_url(url)
      url.match(/^(?<base_url>https:\/\/docs.google.com\/(?:a\/(?<domain>[^\/]+)\/)?(?<type>[^\/]+)\/d\/(?<id>[-\w]{25,})).+$/)
    end

    def self.key_from_url(url)
      match = parse_url(url)
      match.nil? ? nil : match['id']
    end

    def auth
      @client.authorization
    end

    def initialize(options)
      @client = Google::APIClient.new

      @client.authorization.update!({
        :client_id => ENV['GOOGLE_CLIENT_ID'],
        :client_secret => ENV['GOOGLE_CLIENT_SECRET'],
        :scope => 'https://www.googleapis.com/auth/drive ' \
                  'https://spreadsheets.google.com/feeds/'
      }.update(options))

      begin
        @client.authorization.refresh! if @client.authorization.expired?
      rescue Signet::AuthorizationError => exc
        raise AuthorizationError, exc.message
      end

      @_files = {}
      @_spreadsheets = {}
    end

    # Get the contents of a file from Google
    # Takes the url of a Google Drive file and returns an object or string.
    #
    # @param file_id [String] URL
    # @return [Hash,String] file contents
    def get_doc_contents(url, format: nil)
      parts = self.class.parse_url(url)
      case parts['type']
      when 'spreadsheets'
        filename = export_to_file(parts['id'], :xlsx)
        ret = prepare_spreadsheet(filename)
        File.unlink(filename)
      when 'document'
        ret = export(parts['id'], format || :html)
      else
        ret = export(parts['id'], format || :txt)
      end
      return ret
    end

    # Find a Google Drive file
    # Takes the key of a Google Drive file and returns a hash of meta data. The returned hash is
    # formatted as a
    # {Google Drive resource}[https://developers.google.com/drive/v2/reference/files#resource].
    #
    # @param file_id [String] file id
    # @return [Hash] file meta data
    def find(file_id)
      return @_files[file_id] unless @_files[file_id].nil?

      drive = @client.discovered_api('drive', 'v2')

      # get the file metadata
      resp = @client.execute(
        :api_method => drive.files.get,
        :parameters => { :fileId => file_id })

      # die if there's an error
      handle_errors resp

      @_files[file_id] = resp.data
    end

    # Export a file
    # Returns the file contents
    #
    # @param file_id [String] file id
    # @param type [:excel, :text, :html] export type
    # @return [String] file contents
    def export(file_id, type)
      # watch(file_id)
      list_resp = find(file_id)

      # decide which mimetype we want
      mime = mime_for(type).content_type

      # Grab the export url.
      if list_resp['exportLinks'] && list_resp['exportLinks'][mime]
        uri = list_resp['exportLinks'][mime]
      else
        raise "Google doesn't support exporting file id #{file_id} to #{type}"
      end

      # get the export
      get_resp = @client.execute(:uri => uri)

      # die if there's an error
      handle_errors get_resp

      # contents
      get_resp.body
    end

    # Export a file and save to disk
    # Returns the local path to the file
    #
    # @param file_id [String] file id
    # @param type [:excel, :text, :html] export type
    # @param filename [String] where to save the spreadsheet
    # @return [String] path to the excel file
    def export_to_file(file_id, type, filename = nil)
      contents = export(file_id, type)

      if filename.nil?
        # get a temporary file. The export is binary, so open the tempfile in
        # write binary mode
        fp = Tempfile.create(
          ['googledoc', ".#{type}"], :binmode => mime_for(type.to_s).binary?)
        filename = fp.path
        fp.write(contents)
        fp.close
      else
        open(filename, 'wb') { |f| f.write(contents) }
      end
      filename
    end

    # Make a copy of a Google Drive file
    #
    # @param file_id [String] file id
    # @param title [String] title for the newly created file
    # @return [Hash] hash containing the id/key and url of the new file
    def copy(file_id, title = nil, visibility = :private)
      drive = @client.discovered_api('drive', 'v2')

      if title.nil?
        copied_file = drive.files.copy.request_schema.new
      else
        copied_file = drive.files.copy.request_schema.new(
          'title' => title, 'writersCanShare' => true)
      end
      cp_resp = @client.execute(
        :api_method => drive.files.copy,
        :body_object => copied_file,
        :parameters => {
          :fileId => file_id, :visibility => visibility.to_s.upcase })

      # die if there's an error
      handle_errors cp_resp

      { :id => cp_resp.data['id'], :url => cp_resp.data['alternateLink'] }
    end
    alias_method :copy_doc, :copy

    def share_with_domain(file_id, domain)
      unless check_permission(file_id, domain)
        insert_permission(file_id, domain, 'domain', 'writer')
      end
    end

    def check_permission(file_id, domain)
      drive = @client.discovered_api('drive', 'v2')
      cp_resp = @client.execute(
        :api_method => drive.permissions.list,
        :parameters => { :fileId => file_id })

      has_permission = false
      cp_resp.data.items.each do |item|
        if item['type'] == 'domain' && item['domain'] == domain
          has_permission = true
        elsif item['type'] == 'anyone'
          has_permission = true
        end
      end

      if cp_resp.error?
        raise CreateError, cp_resp.error_message
      else
        return has_permission
      end
    end

    def insert_permission(file_id, value, perm_type, role)
      drive = @client.discovered_api('drive', 'v2')
      new_permission = {
        'value' => value,
        'type' => perm_type,
        'role' => role
      }
      cp_resp = @client.execute(
        :api_method => drive.permissions.insert,
        :body_object => new_permission,
        :parameters => { :fileId => file_id })

      if cp_resp.error?
        raise CreateError, cp_resp.error_message
      else
        return cp_resp.data
      end
    end

    # Get the mime type from a file extension
    #
    # @param extension [String] file ext
    # @return [String, nil] mime type for the file
    def mime_for(extension)
      MIME::Types.of(extension.to_s).first
    end

    ## Spreadsheet utilities

    # Parse a spreadsheet
    # Reduces the spreadsheet to a no-frills hash, suitable for serializing and passing around.
    #
    # @param filename [String] path to xls file
    # @return [Hash] spreadsheet contents
    def prepare_spreadsheet(filename)
      # open the file with RubyXL
      xls = RubyXL::Parser.parse(filename)
      data = {}
      xls.worksheets.each do |sheet|
        title = sheet.sheet_name
        # if the sheet is called microcopy, copy or ends with copy, we assume
        # the first column contains keys and the second contains values.
        # Like tarbell.
        if %w(microcopy copy).include?(title.downcase) ||
           title.downcase =~ /[ -_]copy$/
          data[title] = load_microcopy(sheet.extract_data)
        else
          # otherwise parse the sheet into a hash
          data[title] = load_table(sheet.extract_data)
        end
      end
      data
    end

    # Take a two-dimensional array from a spreadsheet and create a hash. The first
    # column is used as the key, and the second column is the value. If the key
    # occurs more than once, the value becomes an array to hold all the values
    # associated with the key.
    #
    # @param table [Array<Array>] 2d array of cell values
    # @return [Hash] spreadsheet contents
    def load_microcopy(table)
      data = {}
      table.each_with_index do |row, i|
        next if i == 0 # skip the header row
        next if row.nil? || row.length < 2 || row[0].nil? # skip empty, incomplete or blank rows
        # Did we already create this key?
        if data.keys.include? row[0]
          # if the key name is reused, create an array with all the entries
          if data[row[0]].is_a? Array
            data[row[0]] << row[1]
          else
            data[row[0]] = [data[row[0]], row[1]]
          end
        else
          # add this row's key and value to the hash
          data[row[0]] = row[1]
        end
      end
      data
    end

    # Take a two-dimensional array from a spreadsheet and create an array of hashes.
    #
    # @param table [Array<Array>] 2d array of cell values
    # @return [Array<Hash>] spreadsheet contents
    def load_table(table)
      return [] if table.length < 2
      header = table.shift # Get the header row
      return [] if header.nil?
      # remove blank rows
      table.reject! do |row|
        row.nil? || row
          .map { |r| r.nil? || r.to_s.strip.empty? }
          .reduce(true) { |m, col| m && col }
      end
      table.map do |row|
        # zip headers with current row, convert it to a hash
        header.zip(row).to_h unless row.nil?
      end
    end

    class GoogleDriveError < StandardError; end
    class CreateError < GoogleDriveError; end
    class ConfigurationError < GoogleDriveError; end
    class AuthorizationError < GoogleDriveError; end
    class ClientError < GoogleDriveError; end
    class Unauthorized < ClientError; end
    class Forbidden < ClientError; end
    class DoesNotExist < ClientError; end

    private

    def handle_errors(result)
      return if result.success?
      # die if there's an error
      if result.response.status >= 500
        ex = GoogleDriveError
      elsif result.response.status == 404
        ex = DoesNotExist
      elsif result.response.status == 401
        ex = Unauthorized
      elsif result.response.status == 403
        ex = Forbidden
      elsif result.response.status >= 400
        ex = ClientError
      end
      raise ex, result.error_message
    end
  end
end
