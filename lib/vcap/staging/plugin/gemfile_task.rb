require "logger"
require "fileutils"
require "bundler"
require "rubygems/installer"
require "vcap/staging/plugin/gem_cache"

class GemfileTask
  def initialize(app_dir, library_version, ruby_cmd, base_dir, uid=nil, gid=nil)
    @app_dir         = File.expand_path(app_dir)
    @library_version = library_version
    @cache_base_dir  = File.join(base_dir, @library_version)

    @ruby_cmd = ruby_cmd
    @uid = uid
    @gid = gid

    log_file = File.expand_path(File.join(@app_dir, '..', 'logs', 'staging.log'))
    FileUtils.mkdir_p(File.dirname(log_file))

    @logger = Logger.new(log_file)
    @logger.level = ENV["DEBUG"] ? Logger::DEBUG : Logger::INFO
    @logger.formatter = lambda { |sev, time, pname, msg| "#{msg}\n" }

    @cache  = GemCache.new(File.join(@cache_base_dir, "gem_cache"))
  end

  attr_writer :git_path
  def git_path
    @git_path ||= "/var/vcap/packages/git/bin/git"
  end

  def lockfile_path
    File.join(@app_dir, 'Gemfile.lock')
  end

  def lockfile
    File.read(lockfile_path)
  end

  # Returns an array of [gemname, version] pairs.
  def dependencies
    return @dependencies unless @dependencies.nil?
    @dependencies = [ ]
    lockfile.each_line do |line|
      if line =~ /^\s{4}([-\w_.0-9]+)\s*\((.*)\)/
        @dependencies << [$1, $2]
      end
    end
    @dependencies
  end

  def git_gem_specs
    return @git_gem_specs unless @git_gem_specs.nil?

    parser = Bundler::LockfileParser.new(lockfile)

    @git_gem_specs = parser.specs.select { |s|
      s.source.is_a? Bundler::Source::Git
    }.map { |s|
      {
        "name" => s.name,
        "version" => s.version.version,
        "uri" => s.source.uri,
        "revision" => s.source.send(:revision),
      }
    }
  end

  def git_gems
    git_gem_specs.map { |d| [ d["name"], d["version"] ] }
  end

  # TODO - Inject EM.system-compatible control here.
  def install
    install_gems(dependencies - git_gems)
    install_git_gems
  end

  def remove_gems_cached_in_app
    FileUtils.rm_rf(File.join(installation_directory, "cache"))
  end

  def install_bundler
    install_gems([ ['bundler', '1.0.10'] ])
  end

  def install_local_gem(gem_dir,gem_filename,gem_name,gem_version)
    blessed_gems_dir = File.join(@cache_base_dir, "blessed_gems")

    if File.exists?(File.join(blessed_gems_dir, gem_filename))
       install_gems([ [gem_name, gem_version] ])
    else
       install_from_local_dir(gem_dir, gem_filename)
    end
  end

  # The application includes some version of Thin in its bundle.
  def bundles_thin?
    dependencies.assoc('thin')
  end

 #The application includes some version of the specified gem in its bundle
 def bundles_gem?(gem_name)
    dependencies.assoc(gem_name)
 end

  # The application includes some version of Rack in its bundle.
  def bundles_rack?
    dependencies.assoc('rack')
  end

  # Each dependency is a gem [name, version] pair;
  # e.g. ['thin', '1.2.10']
  def install_gems(gems)
    missing = [ ]

    blessed_gems_dir = File.join(@cache_base_dir, "blessed_gems")
    FileUtils.mkdir_p(blessed_gems_dir)

    gems.each do |(name, version)|
      gem_filename = "%s-%s.gem" % [ name, version ]

      user_gem_path    = File.join(@app_dir, "vendor", "cache", gem_filename)
      blessed_gem_path = File.join(blessed_gems_dir, gem_filename)

      if File.exists?(user_gem_path)
        installed_gem_path = @cache.get(user_gem_path)
        unless installed_gem_path
          @logger.debug "Installing user gem: #{user_gem_path}"

          tmp_gem_dir = install_gem(user_gem_path)
          raise "Failed installing #{gem_filename}" unless tmp_gem_dir

          installed_gem_path = @cache.put(user_gem_path, tmp_gem_dir)
        end
        @logger.info "Adding #{gem_filename} to app..."
        copy_gem_to_app(installed_gem_path)

      elsif File.exists?(blessed_gem_path)
        installed_gem_path = @cache.get(blessed_gem_path)
        unless installed_gem_path
          @logger.debug "Installing blessed gem: #{blessed_gem_path}"

          tmp_gem_dir = install_gem(blessed_gem_path)
          raise "Failed installing #{gem_filename}" unless tmp_gem_dir

          installed_gem_path = @cache.put(blessed_gem_path, tmp_gem_dir)
        end
        @logger.info "Adding #{gem_filename} to app..."
        copy_gem_to_app(installed_gem_path)

      else
        @logger.info("Need to fetch #{gem_filename} from RubyGems")
        missing << [ name, version ]
      end
    end

    return if missing.empty?

    Dir.mktmpdir do |tmp_dir|
      @logger.info("Fetching missing gems from RubyGems")
      unless fetch_gems(missing, tmp_dir)
        raise "Failed fetching missing gems from RubyGems"
      end

      missing.each do |(name, version)|
        gem_filename = "%s-%s.gem" % [ name, version ]
        gem_path     = File.join(tmp_dir, gem_filename)

        @logger.debug "Installing downloaded gem: #{gem_path}"
        tmp_gem_dir = install_gem(gem_path)
        raise "Failed installing #{gem_filename}" unless tmp_gem_dir

        installed_gem_path = @cache.put(gem_path, tmp_gem_dir)
        output = `cp -n #{gem_path} #{blessed_gems_dir} 2>&1`
        if $?.exitstatus != 0
          @logger.debug "Failed adding #{gem_path} to #{blessed_gems_dir}: #{output}"
        end
        @logger.info "Adding #{gem_filename} to app..."

        copy_gem_to_app(installed_gem_path)
      end
    end
  end

  # returns a tuple of (dir, gemspec) where dir is the tree hosting the gem
  # we also assume that the file for gemspec lives directly below dir
  def git_checkout(tmpdir, uri, revision, gem_name)
    `#{git_path} clone --quiet --no-checkout #{uri} #{tmpdir} && cd #{tmpdir} && #{git_path} checkout --quiet #{revision}`
    if $?.exitstatus != 0
      raise "Git clone failed"
    end
    # FIXME: logger.debug
    @logger.info("git revision: %s" % `cd #{tmpdir} && #{git_path} rev-parse HEAD`.strip)
    @logger.info("git status: %s" % `cd #{tmpdir} && #{git_path} status`)
    Dir.glob(File.join(tmpdir, Bundler::Source::Path::DEFAULT_GLOB)).each do |file|
      # duh, people are shelling out in their gemspec
      old_env = ENV.to_hash
      ENV["PATH"] = "%s:%s" % [ File.dirname(git_path), old_env["PATH"] ]
      # gemspec = Bundler.load_gemspec(file)
      # FIXME: ideally we should spawn a new Ruby VM in a clean env
      # but assuming gemspecs only require files from themselves
      # clearing $LOAD_PATH seems sufficient
      pid = fork do
        $:.clear
        gemspec = Bundler.load_gemspec(file)
        File.open(file, "w") { |f| f.write(gemspec.to_ruby_for_cache) }
        exit!
      end
      Process.waitpid(pid)
      gemspec = Bundler.load_gemspec(file)
      ENV.replace(old_env)
      if gemspec && gemspec.name == gem_name
        return [File.dirname(file), gemspec]
      end
    end
    nil
  end

  def build_extensions(dir, gemspec)
    klass = Class.new(Gem::Installer) do
      def initialize(dir, gemspec)
        @spec = gemspec
        @gem_dir = dir
      end
    end
    installer = klass.new(dir, gemspec)
    installer.build_extensions
  end

  def git_installation_dir
    File.join(installation_directory, 'bundler', 'gems')
  end

  def git_gem_dir(uri, revision)
    git_scope = "%s-%s" % [ File.basename(uri, '.git'), revision[0, 12] ]
    File.join(git_installation_dir, git_scope)
  end

  def copy_git_gem_to_app(dir, uri, revision)
    raise ArgumentError, [dir,uri,revision].inspect unless dir && uri && revision
    FileUtils.mkdir_p(git_installation_dir)
    FileUtils.cp_r(dir, git_gem_dir(uri, revision), :preserve => true)
  end

  # remove all the dynamism in gemspecs
  # no more shelling out yo
  def sanitize_gemspec(dir, gemspec)
    # we only care about one gemspec, o/w it's undefined
    Dir.glob(File.join(dir, "*.gemspec")) do |file|
      @logger.info("sanitizing gemspec for #{gemspec.name}-#{gemspec.version}")
      File.open(file, "w") {|f| f.write(gemspec.to_ruby_for_cache)}
      break
    end
  end

  # each git gem spec is a 4-key hash: name, version, uri, revision
  # TODO: cache compilation results
  def install_git_gems
    git_gem_specs.each do |s|
      Dir.mktmpdir do |tmpdir|
        @logger.info("checking out git repo for #{s.inspect}")
        checkout_dir, gemspec = git_checkout(
          tmpdir, s["uri"], s["revision"], s["name"]
        )
        @logger.info("loaded gemspec: #{gemspec.name}-#{gemspec.version}")
        @logger.info("building extensions for #{gemspec.name}-#{gemspec.version}")
        build_extensions(checkout_dir, gemspec)
        # sanitize_gemspec(checkout_dir, gemspec)
        @logger.info("copying git gem #{gemspec.name}-#{gemspec.version} to app")
        copy_git_gem_to_app(checkout_dir, s["uri"], s["revision"])
      end
    end
  end

  private

  def install_from_local_dir(local_dir,gem_filename)
    blessed_gems_dir = File.join(@cache_base_dir, "blessed_gems")
    gem_path     = File.join(local_dir, gem_filename)
    @logger.debug "Installing downloaded gem: #{gem_path}"
    tmp_gem_dir = install_gem(gem_path)
    raise "Failed installing #{gem_filename}" unless tmp_gem_dir

    installed_gem_path = @cache.put(gem_path, tmp_gem_dir)
    output = `cp -n #{gem_path} #{blessed_gems_dir} 2>&1`
    if $?.exitstatus != 0
      @logger.debug "Failed adding #{gem_path} to #{blessed_gems_dir}: #{output}"
    end
    @logger.info "Adding #{gem_filename} to app..."
    copy_gem_to_app(installed_gem_path)
  end


  def copy_gem_to_app(src)
    return unless src && File.exists?(src)
    FileUtils.mkdir_p(installation_directory)
    `cp -a #{src}/* #{installation_directory}`
  end

  def installation_directory
    File.join(@app_dir, 'rubygems', 'ruby', @library_version)
  end

  def fetch_gems(gems, directory)
    return if gems.empty?
    urls = gems.map { |(name, version)| rubygems_url_for(name, version) }.join(" ")
    cmd  = "wget --quiet --retry-connrefused --connect-timeout=5 --no-check-certificate #{urls}"

    Dir.chdir(directory) do
      system(cmd)
    end
  end

  def rubygems_url_for(name, version)
    "http://production.s3.rubygems.org/gems/#{name}-#{version}.gem"
  end

  # Stage the gemfile in a temporary directory that is readable by a secure user
  # We may be able to get away with mv here instead of a cp
  def stage_gemfile_for_install(src, tmp_dir)
    output = `cp #{src} #{tmp_dir} 2>&1`
    if $?.exitstatus != 0
      @logger.debug "Failed copying #{src} to #{tmp_dir}: #{output}"
      return nil
    end

    staged_gemfile = File.join(tmp_dir, File.basename(src))

    output = `chmod -R 0744 #{staged_gemfile} 2>&1`
    if $?.exitstatus != 0
      @logger.debug "Failed chmodding #{tmp_dir}: #{output}"
      nil
    else
      staged_gemfile
    end
  end

  # Perform a gem install from src_dir into a temporary directory
  def install_gem(gemfile_path)
    # Create tempdir that will house everything
    tmp_dir = Dir.mktmpdir
    at_exit do
      user = `whoami`.chomp
      `sudo /bin/chown -R #{user} #{tmp_dir}` if @uid
      FileUtils.rm_rf(tmp_dir)
    end

    # Copy gemfile into tempdir, make sure secure user can read it
    staged_gemfile = stage_gemfile_for_install(gemfile_path, tmp_dir)
    unless staged_gemfile
      @logger.debug "Failed copying gemfile to staging dir for install"
      return nil
    end

    # Create a temp dir that the user can write into (gem install into)
    gem_install_dir = File.join(tmp_dir, 'gem_install_dir')
    begin
      Dir.mkdir(gem_install_dir)
    rescue => e
      @logger.error "Failed creating gem install dir: #{e}"
      return nil
    end

    if @uid
      chmod_output = `/bin/chmod 0755 #{gem_install_dir} 2>&1`
      if $?.exitstatus != 0
        @logger.error "Failed chmodding install dir: #{chmod_output}"
        return nil
      end

      chown_output = `sudo /bin/chown -R #{@uid} #{tmp_dir} 2>&1`
      if $?.exitstatus != 0
        @logger.debug "Failed chowning install dir: #{chown_output}"
        return nil
      end
    end

    @logger.debug("Doing a gem install from #{staged_gemfile} into #{gem_install_dir} as user #{@uid || 'cc'}")
    staging_cmd = "#{@ruby_cmd} -S gem install #{staged_gemfile} --local --no-rdoc --no-ri -E -w -f --ignore-dependencies --install-dir #{gem_install_dir}"
    staging_cmd = "cd / && sudo -u '##{@uid}' #{staging_cmd}" if @uid

    # Finally, do the install
    pid = fork
    if pid
      # Parent, wait for staging to complete
      Process.waitpid(pid)
      child_status = $?

      # Kill any stray processes that the gem compilation may have created
      if @uid
        `sudo -u '##{@uid}' pkill -9 -U #{@uid} 2>&1`
        me = `whoami`.chomp
        `sudo chown -R #{me} #{tmp_dir}`
        @logger.debug "Failed chowning #{tmp_dir} to #{me}" if $?.exitstatus != 0
      end

      if child_status.exitstatus != 0
        @logger.debug("Failed executing #{staging_cmd}")
        nil
      else
        @logger.debug("Success!")
        gem_install_dir
      end
    else
      close_fds
      exec(staging_cmd)
    end
  end

  def close_fds
    3.upto(get_max_open_fd) do |fd|
      begin
        IO.for_fd(fd, "r").close
      rescue
      end
    end
  end

  def get_max_open_fd
    max = 0

    dir = nil
    if File.directory?("/proc/self/fd/") # Linux
      dir = "/proc/self/fd/"
    elsif File.directory?("/dev/fd/") # Mac
      dir = "/dev/fd/"
    end

    if dir
      Dir.foreach(dir) do |entry|
        begin
          pid = Integer(entry)
          max = pid if pid > max
        rescue
        end
      end
    else
      max = 65535
    end

    max
  end

end
