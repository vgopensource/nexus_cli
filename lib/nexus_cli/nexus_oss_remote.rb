require 'restclient'
require 'httpclient'
require 'nokogiri'
require 'yaml'
require 'json'
require 'jsonpath'

module NexusCli
  class OSSRemote
    def initialize(overrides)
      @configuration = Configuration::parse(overrides)
    end

    def configuration
      return @configuration if @configuration
    end

    def nexus
      RestClient::Resource.new configuration["url"], :user => configuration["username"], :password => configuration["password"], :timeout => 1000000, :open_timeout => 1000000
    end

    def status
      doc = Nokogiri::XML(nexus['service/local/status'].get).xpath("/status/data")
      data = Hash.new
      data['app_name'] = doc.xpath("appName")[0].text
      data['version'] = doc.xpath("version")[0].text
      data['edition_long'] = doc.xpath("editionLong")[0].text
      data['state'] = doc.xpath("state")[0].text
      data['started_at'] = doc.xpath("startedAt")[0].text
      data['base_url'] = doc.xpath("baseUrl")[0].text
      return data
    end

    def pull_artifact(artifact, destination)
      group_id, artifact_id, version, extension = parse_artifact_string(artifact)
      version = Nokogiri::XML(get_artifact_info(artifact)).xpath("//version").first.content() if version.casecmp("latest")
      destination = File.join(File.expand_path(destination || "."), "#{artifact_id}-#{version}.#{extension}")
      nexus_httpclient = HTTPClient.new
      url = File.join(configuration['url'], "service/local/artifact/maven/redirect")
      nexus_httpclient.set_auth(url, configuration['username'], configuration['password'])
      response = nexus_httpclient.get(url, :query => {:g => group_id, :a => artifact_id, :v => version, :e => extension, :r => configuration['repository']})
      case response.status
      when 301
        # Follow redirect and stream in chunks.
        artifact_file = File.open(destination, "wb") do |io|
          nexus_httpclient.get(response.content.gsub(/If you are not automatically redirected use this url: /, "")) do |chunk|
            io.write(chunk)
          end
        end
      when 404
        raise ArtifactNotFoundException
      else
        raise UnexpectedStatusCodeException.new(response.code)
      end
      File.expand_path(destination)
    end

    def push_artifact(artifact, file)
      group_id, artifact_id, version, extension = parse_artifact_string(artifact)
      nexus_httpclient = HTTPClient.new
      url = File.join(configuration['url'], "service/local/artifact/maven/content")
      nexus_httpclient.set_auth(url, configuration['username'], configuration['password'])
      response = nexus_httpclient.post(url, {:hasPom => false, :g => group_id, :a => artifact_id, :v => version, :e => extension, :p => extension, :r => configuration['repository'], :file => File.open(file)})
      case response.code
      when 201
        return true
      when 400
        raise BadUploadRequestException
      when 401
        raise PermissionsException
      when 403
        raise PermissionsException
      when 404
        raise CouldNotConnectToNexusException
      else
        raise UnexpectedStatusCodeException.new(response.code)
      end
    end

    def delete_artifact(artifact)
      group_id, artifact_id, version = parse_artifact_string(artifact)
      nexus["content/repositories/#{configuration['repository']}/#{group_id.gsub(".", "/")}/#{artifact_id.gsub(".", "/")}/#{version}"].delete
    end

    def get_artifact_info(artifact)
      group_id, artifact_id, version, extension = parse_artifact_string(artifact)
      nexus_httpclient = HTTPClient.new
      url = File.join(configuration['url'], "service/local/artifact/maven/resolve")
      nexus_httpclient.set_auth(url, configuration['username'], configuration['password'])
      response = nexus_httpclient.get(url, :query => {:g => group_id, :a => artifact_id, :v => version, :e => extension, :r => configuration['repository']})
      case response.code
      when 200
        return response.content
      when 404
        raise ArtifactNotFoundException
      when 503
        raise CouldNotConnectToNexusException
      else
        raise UnexpectedStatusCodeException.new(response.code)
      end
    end

    def search_for_artifacts(artifact)
      group_id, artifact_id = artifact.split(":")
      nexus['service/local/data_index'].get(:params => {:g => group_id, :a => artifact_id}) do |response|
        doc = Nokogiri::XML(response.body)
        return format_search_results(doc, group_id, artifact_id)
      end
    end

    def get_global_settings
      json = get_global_settings_json
      pretty_json = JSON.pretty_generate(JSON.parse(json))
      Dir.mkdir(File.expand_path("~/.nexus")) unless Dir.exists?(File.expand_path("~/.nexus"))
      destination = File.join(File.expand_path("~/.nexus"), "global_settings.json")
      artifact_file = File.open(destination, 'wb') do |file|
        file.write(pretty_json)
      end
    end

    def upload_global_settings(json=nil)
      global_settings = nil
      if json == nil
        global_settings = File.read(File.join(File.expand_path("~/.nexus"), "global_settings.json"))
      else
        global_settings = json
      end
      nexus['service/local/global_settings/current'].put(global_settings, {:content_type => "application/json"}) do |response|
        case response.code
        when 400
          raise BadSettingsException.new(response.body)
        end
      end
    end

    def get_global_settings_json
      nexus['service/local/global_settings/current'].get(:accept => "application/json")
    end

    def reset_global_settings
      default_json = nexus['service/local/global_settings/default'].get(:accept => "application/json")
      nexus['service/local/global_settings/current'].put(default_json, :content_type => "application/json")
    end

    def create_repository(name, proxy, url)
      json = if proxy
        create_proxy_repository_json(name, url)
      else
        create_hosted_repository_json(name)
      end
      nexus['service/local/repositories'].post(json, :content_type => "application/json") do |response|
        case response.code
        when 400
          raise CreateRepsitoryException.new(response.body)
        when 201
          return true
        else
          raise UnexpectedStatusCodeException.new(response.code)
        end
      end
    end

    def delete_repository(name)
      nexus["service/local/repositories/#{name.downcase}"].delete do |response|
        case response.code
        when 404
          raise RepositoryDoesNotExistException
        when 204
          return true
        else
          raise UnexpectedStatusCodeException.new(response.code)
        end
      end
    end

    def get_repository_info(name)
      begin
        nexus["service/local/repositories/#{name.gsub(" ", "_").downcase}"].get
      rescue Errno::ECONNREFUSED => e
        raise CouldNotConnectToNexusException
      rescue RestClient::ResourceNotFound => e
        raise RepositoryNotFoundException
      end
    end

    def get_users
      nexus["service/local/users"].get
    end

    def create_user(params)
      nexus["service/local/users"].post(create_user_json(params), :content_type => "application/json") do |response|
        case response.code
        when 201
          return true
        when 400
          raise CreateUserException.new(response.body)
        else
          raise UnexpectedStatusCodeException.new(reponse.code)
        end
      end
    end

    def update_user(params)
      params[:roles] = [] if params[:roles] == [""]
      user_json = get_user(params[:userId])

      modified_json = JsonPath.for(user_json)
      params.each do |key, value|
        modified_json.gsub!("$..#{key}"){|v| value} unless key == "userId" || value.blank?
      end

      nexus["service/local/users/#{params[:userId]}"].put(JSON.dump(modified_json.to_hash), :content_type => "application/json") do |response|
        case response.code
        when 200
          return true
        when 400
          raise UpdateUserException.new(response.body)
        else
          raise UnexpectedStatusCodeException.new(response.code)
        end
      end
    end

    def get_user(user)
      nexus["service/local/users/#{user}"].get(:accept => "application/json") do |response|
        case response.code
        when 200
          return JSON.parse(response.body)
        when 404
          raise UserNotFoundException.new(user)
        else
          raise UnexpectedStatusCodeException.new(response.code)
        end
      end
    end

    def change_password(params)
      nexus["service/local/users_changepw"].post(create_change_password_json(params), :content_type => "application/json") do |response|
        case response.code
        when 202
          return true
        when 400
          raise InvalidCredentialsException
        end
      end
    end

    def delete_user(user_id)
      nexus["service/local/users/#{user_id}"].delete do |response|
        case response.code
        when 204
          return true
        when 404
          raise UserNotFoundException.new(user_id)
        else
          raise UnexpectedStatusCodeException.new(response.code)
        end
      end
    end

    def running_nexus_pro?
      status['edition_long'] == "Professional"
    end

    def get_logging_info
      nexus["service/local/log/config"].get(:accept => "application/json")
    end

    def set_logger_level(level)
      raise InvalidLoggingLevelException unless ["INFO", "DEBUG", "ERROR"].include?(level.upcase)
      nexus["service/local/log/config"].put(create_logger_level_json(level), :content_type => "application/json") do |response|
        case response.code
        when 200
          return true
        else
          raise UnexpectedStatusCodeException.new(response.code)
        end
      end
    end

    private

    def format_search_results(doc, group_id, artifact_id)
      versions = doc.xpath("//version").inject([]) {|array,node| array << "#{node.content()}"}
      indent_size = versions.max{|a,b| a.length <=> b.length}.size+4
      formated_results = ['Found Versions:']
      versions.inject(formated_results) do |array,version|
        temp_version = version + ":"
        array << "#{temp_version.ljust(indent_size)} `nexus-cli pull #{group_id}:#{artifact_id}:#{version}:tgz`"
      end
    end

    def parse_artifact_string(artifact)
      split_artifact = artifact.split(":")
      if(split_artifact.size < 4)
        raise ArtifactMalformedException
      end
      group_id, artifact_id, version, extension = split_artifact
      version.upcase! if version.casecmp("latest")
      return group_id, artifact_id, version, extension
    end

    def create_hosted_repository_json(name)
      params = {:provider => "maven2"}
      params[:providerRole] = "org.sonatype.nexus.proxy.repository.Repository"
      params[:exposed] = true
      params[:repoType] = "hosted"
      params[:repoPolicy] = "RELEASE"
      params[:name] = name
      params[:id] = name.gsub(" ", "_").downcase
      params[:format] = "maven2"
      JSON.dump(:data => params)
    end

    def create_proxy_repository_json(name, url)
      params = {:provider => "maven2"}
      params[:providerRole] = "org.sonatype.nexus.proxy.repository.Repository"
      params[:exposed] = true
      params[:repoType] = "proxy"
      params[:repoPolicy] = "RELEASE"
      params[:checksumPolicy] = "WARN"
      params[:writePolicy] = "READ_ONLY"
      params[:downloadRemoteIndexes] = true
      params[:autoBlockActive] = true
      params[:name] = name
      params[:id] = name.gsub(" ", "_").downcase
      params[:remoteStorage] = {:remoteStorageUrl => url.nil? ? "http://change-me.com/" : url}
      JSON.dump(:data => params)
    end

    def create_user_json(params)
      JSON.dump(:data => params)
    end

    def create_change_password_json(params)
      JSON.dump(:data => params)
    end

    def create_logger_level_json(level)
      params = {:rootLoggerLevel => level.upcase}
      JSON.dump(:data => params)
    end
  end
end
