require 'net/ftp'

module BackupFu
  class FTPConfigError < StandardError; end

  class FTPProvider
    def initialize(options={})
      check_config(options)
      create_remote_backup_dir
    end

    def delete(file)
      run_ftp_command do |ftp|
        ftp.delete(file)
      end
    end

    def put(file)
      run_ftp_command do |ftp|
        ftp.put(file)
      end
    end

    def get(file, &block)
      run_ftp_command do |ftp|
        ftp.get(file, &block)
      end
    end

    def list
      run_ftp_command do |ftp|
        ftp.list("*").map{|f| f.split(" ").last}
      end
    end

    private

    def run_ftp_command
      Net::FTP.open(@options[:host], @options[:user], @options[:password]) do |ftp|
        ftp.chdir @options[:backup_dir]
        yield ftp if block_given?
      end
    end

    def create_remote_backup_dir
      @ftp = Net::FTP.new(@options[:host], @options[:user], @options[:password])
      begin
        @ftp.chdir @options[:backup_dir]
      rescue Net::FTPPermError
        @ftp.mkdir @options[:backup_dir]
        @ftp.chdir @options[:backup_dir]
      end
      @ftp.close
    end

    def check_config(options)
      @options = {}
      @options[:host] = options[:ftp_host]
      raise(FTPConfigError, "FTP hostname (ftp_host) is not set in config/backup_fu.yml. If you do not want to use FTP provider, change provider in config/backup_fu.yml to s3 or local") if @options[:host].blank?

      @options[:user] = options[:ftp_user] || "anonymous"
      @options[:password] = options[:ftp_password]
      @options[:backup_dir] = options[:remote_backup_dir] || "backups"
    end
  end
end

