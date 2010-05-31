require 'right_aws'

module BackupFu
  class S3ConfigError < StandardError; end

  class S3Provider
    def initialize(options={})
      check_config(options)
      @s3 = RightAws::S3.new(@options[:access_key_id], @options[:secret_access_key])
      @s3interface = RightAws::S3Interface.new(@options[:access_key_id], @options[:secret_access_key])
      @s3_bucket = @s3.bucket(@options[:bucket], true, 'private')
    end

    def delete(file)
      key = @s3_bucket.key(File.basename(file))
      key.delete()
    end

    def put(file)
      key = @s3_bucket.key(File.basename(file))
      key.data = open(file)
      key.put(nil, 'private')
    end

    def get(file, &block)
      @s3interface.get(@options[:bucket], file, {}, &block)
    end

    def list
      @s3.bucket(@options[:bucket]).keys.map(&:to_s)
    end

    private
    def check_config(options)
      @options = {}
      @options[:access_key_id] = ENV['AMAZON_ACCESS_KEY_ID'] || options[:aws_access_key_id]
      @options[:secret_access_key] = ENV['AMAZON_SECRET_ACCESS_KEY'] || options[:aws_secret_access_key]
      raise(S3ConfigError, "AWS Access Key ID or AWS Secret Key not set in config/backup_fu.yml. If you do not want to user AWS S3 provider, change provider in config/backup_fu.yml to ftp or local") if @options[:access_key_id].blank? || @options[:access_key_id].include?('--replace me') || @options[:secret_access_key].include?('--replace me')

      @options[:bucket] = ENV['s3_bucket'] || options[:s3_bucket] || options[:bucket]
      raise(S3ConfigError, "S3 bucket (s3_bucket) not set in config/backup_fu.yml. This bucket must be created using an external S3 tool like S3 Browser for OS X, or JetS3t (Java-based, cross-platform).") if @options[:bucket].blank? || @options[:bucket] == "some-s3-bucket"

    end
  end
end

