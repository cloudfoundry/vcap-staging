# This module contains methods for performing tasks and
# setting file permissions/ownership using a secure user
# Classes including this module should set the instance variable
# @uid to the ID of a secure user, if one should be used.
module SecureOperations

  # Run a process as a secure user, if @uid is set.
  # Otherwise, process is run as current user
  # Use the "where" variable to set the process working dir,
  def run_secure(cmd, where, group=false)
    exitstatus = nil
    output = nil

    secure_file(where)
    begin
      if @uid
        if group
          cmd ="sudo -u '##{@uid}' sg #{secure_group} -c \"cd #{where} && #{cmd}\" 2>&1"
        else
          cmd = "cd #{where} && sudo -u '##{@uid}' #{cmd}"
        end
      else
        cmd = "cd #{where} && #{cmd}"
      end

      IO.popen(cmd) do |io|
        output = io.read
      end

      exitstatus = $?.exitstatus

      # Kill any stray processes that the cmd may have created
      `sudo -u '##{@uid}' pkill -9 -U #{@uid} 2>&1` if @uid
    ensure
      begin
        unsecure_file(where)
      rescue => e
        @logger.error "Failed to unsecure dir: #{e}"
      end
    end

    [ exitstatus, output ]
  end

  def run_secure_succeeded?(cmd, chdir)
    exitstatus, _ = run_secure(cmd, chdir)
    exitstatus == 0
  end

  # Run command under secure user and group
  def run_secure_group(cmd, where)
    # Some commands like npm require directory to belong to secure group
    run_secure(cmd, where, true)
  end

  # Change permissions and ownership of specified file
  # to secure user, if @uid is set
  def secure_file(file)
    if @uid
      chmod_output = `/bin/chmod -R 0755 #{file} 2>&1`
      if $?.exitstatus != 0
        raise "Failed chmodding dir: #{chmod_output}"
      end
      chown_user = @gid ? "#{@uid}:#{@gid}" : @uid
      chown_output = `sudo /bin/chown -R #{chown_user} #{file} 2>&1`
      if $?.exitstatus != 0
        raise "Failed chowning dir: #{chown_output}"
      end
    end
  end

  # Change ownership of specified file
  # to current user
  def unsecure_file(file)
    if @uid
      user = `whoami`.chomp
      chown_output = `sudo /bin/chown -R #{user} #{file} 2>&1`
      if $?.exitstatus != 0
        raise "Failed chowning dir: #{chown_output}"
      end
    end
  end

  # Change ownership of file back to current user
  # and delete file
  def secure_delete(file)
    user = `whoami`.chomp
    `sudo /bin/chown -R #{user} #{file}` if @uid
    FileUtils.rm_rf(file)
  end

  def secure_group
    group_name = `awk -F: '{ if ( $3 == #{@gid} ) { print $1 } }' /etc/group`
    group_name.chomp
  end
end