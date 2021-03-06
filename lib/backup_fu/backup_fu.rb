require 'yaml'
require 'active_support'
require 'mime/types'
require 'erb'
require 'pp'
require 'tempfile'

module BackupFu
  class BackupFuConfigError < StandardError; end

  class Backup
    def initialize
      db_conf = YAML.load_file(File.join(RAILS_ROOT, 'config', 'database.yml'))
      @db_conf = db_conf[RAILS_ENV].symbolize_keys

      raw_config = File.read(File.join(RAILS_ROOT, 'config', 'backup_fu.yml'))
      erb_config = ERB.new(raw_config).result
      fu_conf    = YAML.load(erb_config)
      @fu_conf   = fu_conf[RAILS_ENV].symbolize_keys

      @fu_conf[:mysqldump_options] ||= '--complete-insert --skip-extended-insert'
      @fu_conf[:backup_dir] ||= 'backups'
      @fu_conf[:remote_backup_dir] ||= 'backups'

      @verbose = !@fu_conf[:verbose].nil?
      @timestamp = datetime_formatted
      @fu_conf[:keep_backups] ||= 5

      @fu_conf[:provider] ||= "local"

      case @fu_conf[:provider]
      when "ftp"
        require "backup_fu/ftp"
        @provider = FTPProvider.new(@fu_conf)
      when "s3"
        require "backup_fu/s3"
        @provider = S3Provider.new(@fu_conf)
      else
        require "backup_fu/local"
        @provider = LocalProvider.new(@fu_conf)
      end

      check_conf
      create_dirs
    end

    def sqlcmd_options
      host, port, password = '', '', ''

      if @db_conf.has_key?(:host) && @db_conf[:host] != 'localhost'
        host = "--host=#{@db_conf[:host]}"
      end

      if @db_conf.has_key?(:port)
        port = "--port=#{@db_conf[:port]}"
      end

      unless @db_conf[:username].blank?
        user = "--user=#{@db_conf[:username]}"
      end

      if !@db_conf[:password].blank? && @db_conf[:adapter] != 'postgresql'
        password = "--password=#{@db_conf[:password]}"
      end

      "#{host} #{port} #{user} #{password}"
    end

    def pgpassword_prefix
      if !@db_conf[:password].blank?
        "PGPASSWORD=#{@db_conf[:password]}"
      end
    end

    def dump
      full_dump_path = File.join(dump_base_path, db_filename)
      case @db_conf[:adapter]
      when 'postgresql'
        cmd = niceify "#{pgpassword_prefix} #{dump_path} -i -F c -b #{sqlcmd_options} #{@db_conf[:database]} > #{full_dump_path}"
      when 'mysql'
        cmd = niceify "#{dump_path} #{@fu_conf[:mysqldump_options]} #{sqlcmd_options} #{@db_conf[:database]} > #{full_dump_path}"
      end
      puts cmd if @verbose
      `#{cmd}`

      if !@fu_conf[:disable_compression]
        compress_db(dump_base_path, db_filename)
        File.unlink full_dump_path
      end
    end

    def backup
      dump

      unless @fu_conf[:provider] == "local"
        file = final_db_dump_path()
        puts "\nBacking up file to external provider: #{file}\n" if @verbose
        @provider.put(file)
      end
    end

    def list_backups
      @provider.list
    end

    # Don't count on being able to drop the database, but do expect to drop all tables
    def prepare_db_for_restore
      #raise "restore unimplemented for #{adapter}" unless (adapter = @db_conf[:adapter]) == 'postgresql'
      if (adapter = @db_conf[:adapter]) == 'postgresql'
        query = "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'"
        cmd = "psql #{@db_conf[:database]} -t -c \"#{query}\""
        puts "Executing: '#{cmd}'"
        tables = `#{cmd}`
  
        query = "DROP TABLE #{tables.map(&:chomp).map(&:strip).reject(&:empty?).join(", ")} CASCADE"
        cmd = "psql #{@db_conf[:database]} -t -c \"#{query}\""
        puts "Executing: '#{cmd}'"
        `#{cmd}`
      end
    end

    def restore_backup(key)
      
      tmp_path = File.join(RAILS_ROOT, 'tmp')

      restore_file_name = nil
      restore_file_name_unpacked = nil
      unpack_cmd = nil
      
      if key =~ /(.*)\.tar\.gz/i
        restore_file_name_unpacked = $1 + ".sql"
        unpack_cmd = "tar xfz "
      elsif key =~ /(.*)\.zip/i
        restore_file_name_unpacked = $1 + ".sql"
        unpack_cmd = "unzip "
      else
        if @fu_conf[:disable_compression]
          restore_file_name_unpacked = key
        else
          raise 'Restore not implemented for unknown file type'
        end
      end

      
      # Change restore unpacked path to absolute path 
      restore_file_name_unpacked = File.join(tmp_path, restore_file_name_unpacked) 
      
      restore_file_name = key
      restore_file = File.new(File.join(tmp_path, restore_file_name),  "w+")

      #restore_file = Tempfile.new(restore_file_name)

      open(restore_file.path, 'w') do |fh|
        puts "Fetching #{key} to #{restore_file.path}"
        @provider.get(key) do |chunk|
          fh.write chunk
        end
      end
      restore_file.close

      if unpack_cmd
        if key =~ /(.*)\.tar\.gz/i
          # Tar
          cmd = niceify "#{unpack_cmd} #{restore_file.path} -C #{tmp_path}/"
        elsif key =~ /(.*)\.zip/i
          # Zip
          cmd = niceify "#{unpack_cmd} #{restore_file.path} -d #{tmp_path}/"
        else
          raise 'Restore not implemented for unknown file type'
        end
        
        puts "\nUnpack: #{cmd}\n" if @verbose
        `#{cmd}`
      end

      restore_file_unpacked = File.open(restore_file_name_unpacked, 'r')
      puts "Restore file unpacked: #{restore_file_unpacked.path}"
      
      prepare_db_for_restore

      # Do the actual restore
      case @db_conf[:adapter]
      when 'postgresql'
        cmd = niceify "export #{pgpassword_prefix} && #{restore_command_path} --clean #{sqlcmd_options} --dbname=#{@db_conf[:database]} #{restore_file_unpacked.path}"
      when 'mysql'
        cmd = niceify "mysql #{sqlcmd_options} #{@db_conf[:database]} < #{restore_file_unpacked.path}"
      end
      puts "\nRestore: #{cmd}\n" if @verbose
      `#{cmd}`
    end

    ## Static-file Dump/Backup methods

    def dump_static
      if !@fu_conf[:static_paths]
        raise BackupFuConfigError, 'No static paths are defined in config/backup_fu.yml.  See README.'
      end
      paths = @fu_conf[:static_paths].split(' ')
      compress_static(paths)
    end

    def backup_static
      dump_static

      unless @fu_conf[:provider] == "local"
        file = final_static_dump_path()
        puts "\nBacking up Static files to external provider: #{file}\n" if @verbose
        @provider.put(file)
      end
    end

    def cleanup
      count = @fu_conf[:keep_backups].to_i
      backups = @provider.list
      locals  = Dir.glob("#{dump_base_path}/*")

      if count >= locals.length
        puts "No old local backups to cleanup"
      else
        puts "Keeping #{count} of #{locals.length} local backups"

        files_to_remove = locals - locals.sort.last(count)
        files_to_remove.each do |f|
          puts "Removing old backup file: #{f}" if @verbose
          File.delete(f)
        end
      end

      if count >= backups.length
        puts "no old backups to cleanup"
      else
        puts "keeping #{count} of #{backups.length} remote backups"

        files_to_remove = backups - backups.last(count)
        files_to_remove.each do |f|
          @provider.delete(f)
        end
      end
    end

    private
    def check_conf
      if @fu_conf[:app_name] == 'replace_me'
        raise BackupFuConfigError, 'Application name (app_name) key not set in config/backup_fu.yml.'
      end
    end

    #! dump_path is totally the wrong name here
    def dump_path
      dump = {:postgresql => 'pg_dump',:mysql => 'mysqldump'}
      # Note: the 'mysqldump_path' config option is DEPRECATED but keeping this in for legacy config file support
      @fu_conf[:mysqldump_path] || @fu_conf[:dump_path] || dump[@db_conf[:adapter].intern]
    end

    def restore_command_path
      command = @fu_conf[:restore_command_path] || ((adapter = @db_conf[:adapter]) == 'postgresql' && 'pg_restore')
      raise "Restore unimplemented for adapter #{adapter}" if command.blank?
      command
    end

    def dump_base_path
      @fu_conf[:dump_base_path] || File.join(RAILS_ROOT, 'tmp', 'backup')
    end

    def db_filename
      "#{@fu_conf[:app_name]}_#{ @timestamp }_db.sql"
    end

    def db_filename_compressed
      if(@fu_conf[:compressor] == 'zip')
        db_filename.gsub('.sql', '.zip')
      else
        db_filename.gsub('.sql', '.tar')
      end
    end

    def final_db_dump_path
      if(@fu_conf[:disable_compression])
        filename = db_filename
      else
        if(@fu_conf[:compressor] == 'zip')
          filename = db_filename.gsub('.sql', '.zip')
        else
          filename = db_filename.gsub('.sql', '.tar.gz')
        end
      end
      File.join(dump_base_path, filename)
    end

    def static_compressed_path
      if(@fu_conf[:compressor] == 'zip')
        f = "#{@fu_conf[:app_name]}_#{ @timestamp }_static.zip"
      else
        f = "#{@fu_conf[:app_name]}_#{ @timestamp }_static.tar"
      end
      File.join(dump_base_path, f)
    end

    def final_static_dump_path
      if(@fu_conf[:compressor] == 'zip')
        f = "#{@fu_conf[:app_name]}_#{ @timestamp }_static.zip"
      else
        f = "#{@fu_conf[:app_name]}_#{ @timestamp }_static.tar.gz"
      end
      File.join(dump_base_path, f)
    end

    def create_dirs
      ensure_directory_exists(dump_base_path)
    end

    def ensure_directory_exists(dir)
      FileUtils.mkdir_p(dir) unless File.exist?(dir)
    end

    def niceify(cmd)
      if @fu_conf[:enable_nice]
        "nice -n -#{@fu_conf[:nice_level]} #{cmd}"
      else
        cmd
      end
    end

    def datetime_formatted
      Time.now.strftime("%Y-%m-%d") + "_#{ Time.now.tv_sec }"
    end

    def compress_db(dump_base_path, db_filename)
      compressed_path = File.join(dump_base_path, db_filename_compressed)

      if(@fu_conf[:compressor] == 'zip')
        cmd = niceify "zip #{zip_switches} #{final_db_dump_path} #{dump_base_path}/#{db_filename}"
        puts "\nZip: #{cmd}\n" if @verbose
        `#{cmd}`
      else
        # TAR.GZ it up
        cmd = niceify "tar -czf #{final_db_dump_path} -C #{dump_base_path} #{db_filename}"
        puts "\nTar/Gzip: #{cmd}\n" if @verbose
        `#{cmd}`
      end
    end

    def compress_static(paths)
      paths = paths.map do |p|
        if p.first != '/'
          # Make into an Absolute path:
          p = File.join(RAILS_ROOT, p)
        end
        %{"#{p}"}
      end.join " "

      puts "Static Path: #{p}" if @verbose
      
      if @fu_conf[:compressor] == 'zip'
        cmd = niceify "zip -r #{zip_switches} #{static_compressed_path} #{paths}"
        puts "\nZip: #{cmd}\n" if @verbose
       `#{cmd}`
      else
        # TAR.GZ
        cmd = niceify "tar -czf #{final_static_dump_path} #{paths}"
        puts "\nTar/Gzip: #{cmd}\n" if @verbose
        `#{cmd}`
      end
      
    end


    def zip_switches
      if(@fu_conf[:zip_password] && !@fu_conf[:zip_password].blank?)
        password_option = "-P #{@fu_conf[:zip_password]}"
      else
        password_option = ''
      end

      "#{password_option}"
    end

    def skips
      return '' unless @fu_conf[:skips]

      raise BackupFuConfigError, 'skip option is not array or string' unless @fu_conf[:skips].kind_of?(Array) || @fu_conf[:skips].kind_of?(String)

      if @fu_conf[:skips].kind_of?(Array)
        @fu_conf[:skips].collect{|skip| " --exclude=#{skip} " }.join
      else
        @fu_conf[:skips]
      end
    end
  end
end

