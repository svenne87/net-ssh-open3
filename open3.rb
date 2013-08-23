require 'shellwords' # String#shellescape
require 'thread' # ConditionVariable
require 'net/ssh' # Monkeypatching

class Class
  unless method_defined?(:alias_method_once)
    # Create an alias +new_method+ to +old_method+ unless +new_method+ is already defined.
    def alias_method_once(new_method, old_method)
      alias_method new_method, old_method unless method_defined?(new_method)
    end
  end
end

module Net::SSH # :nodoc:
  module Process # :nodoc:
    # Encapsulates the information on the status of terminated remote process, similar to Process::Status.
    #
    # Note that it's impossible to retrieve PID (process ID) via an SSH channel (thus impossible to properly signal it).
    #
    # Although RFC4254 allows sending signals to the process (see http://tools.ietf.org/html/rfc4254#section-6.9),
    # current OpenSSH server implementation does not support this feature, though there are some patches:
    # https://bugzilla.mindrot.org/show_bug.cgi?id=1424 and http://marc.info/?l=openssh-unix-dev&m=104300802407848&w=2
    #
    # As a workaround you can request a PTY and send SIGINT or SIGQUIT via ^C, ^\ or other sequences,
    # see 'pty' option in Net::SSH::Open3 for more information.
    class Status
      # Integer exit code in range 0..255, 0 usually meaning success.
      # Assigned only if the process has exited normally (i.e. not by a signal).
      # More information about standard exit codes: http://tldp.org/LDP/abs/html/exitcodes.html
      attr_reader :exitstatus

      # true when process has been killed by a signal and a core dump has been generated for it.
      def coredump?
        @coredump
      end 

      # Integer representation of a signal that killed a process, if available.
      #
      # Translated to local system (so you can use Signal.list to map it to String).
      # Explanation: when local system is Linux (USR1=10) and remote is FreeBSD (USR1=30),
      # 10 will be returned in case remote process receives USR1 (30).
      #
      # Not all signal names are delivered by ssh: for example, SIGTRAP is delivered as "SIG@openssh.com"
      # and therefore may not be translated. Returns String in this case.
      def termsig
        Signal.list[@termsig] || @termsig
      end

      # true if the process has returned an exit code rather than being killed by a signal.
      def exited?
        !!@exitstatus
      end

      # true if the process has been killed by a signal, as opposed to returning an exit code.
      def signaled?
        !!@termsig
      end

      # Returns true if the process has exited with code 0, false for other codes and nil if killed by a signal.
      def success?
        exited? ? exitstatus == 0 : nil
      end

      # String representation of exit status.
      def to_s
        if exited?
          "exit #@exitstatus"
        elsif signaled?
          "#@termsig (signal #{termsig}) core #@coredump"
        else
          'uninitialized'
        end
      end

      def inspect # :nodoc:
        "#<#{self.class}: #{to_s}>"
      end
    end
  end

  # Net::SSH Open3 extensions.
  # All methods have the same argument list.
  #
  # *optional* +env+: custom environment variables +Hash+. Note that SSH server typically restricts changeable variables to a very small set,
  # e.g. for OpenSSH see +AcceptEnv+ in +/etc/ssh/sshd_config+ (+AcceptEnv+ +LANG+ +LC_*+)
  #
  # +command+: a single shell command (like in +sh+ +-c+), or an executable program.
  #
  # *optional* +arg1+, +arg2+, +...+: arguments to an executable mentioned above.
  #
  # *optional* +options+: options hash, keys:
  # * +redirects+: Hash of redirections which will be appended to a command line (you can't transfer a pipe to a remote system).
  #   Key: one of +:in+, +:out+, +:err+ or a +String+, value: +Integer+ to redirect to fd, +String+ to redirect to a file.
  #   Example:
  #     { '>>' => '/tmp/log', err: 1 }
  #   translates to
  #     '>>/tmp/log 2>&1'
  # * +channel_retries+: +Integer+ number of retries in case of channel open failure (ssh server usually limits a session to 10 channels),
  #   or an array of [+retries+, +delay+]
  # * +stdin_data+: for +capture*+ only, specifies data to be immediately sent to +stdin+ of a remote process.
  #   stdin is immediately closed then.
  # * +logger+: an object which responds to +debug/info/warn/error+ and optionally +init/stdin/stdout/stderr+ to log debug information
  #   and data exchange stream
  # * +pty+: true or a +Hash+ of PTY settings to request a pseudo-TTY, see Net::SSH documentation for more information.
  #   A note about sending TERM/QUIT: use modes, e.g.:
  #     Net::SSH.start('localhost', ENV['USER']).capture2e('cat', pty: {
  #         modes: {
  #           Net::SSH::Connection::Term::VINTR => 0x01020304, # INT on this 4-byte-sequence
  #           Net::SSH::Connection::Term::VQUIT => 0xdeadbeef, # QUIT on this 4-byte sequence
  #           Net::SSH::Connection::Term::VEOF => 0xfacefeed, # EOF sequence
  #           Net::SSH::Connection::Term::ECHO => 0, # disable echoing
  #           Net::SSH::Connection::Term::ISIG => 1 # enable sending signals
  #         }
  #       },
  #       stdin_data: [0xDEADBEEF].pack('L'),
  #       logger: Class.new { alias method_missing puts; def respond_to?(_); true end }.new)
  #     # log skipped ...
  #     # => ["", #<Net::SSH::Process::Status: QUIT (signal 3) core true>]
  #   Note that just closing stdin is not enough for PTY. You should explicitly send VEOF as a first char of a line, see termios(3).
  module Open3
    SSH_EXTENDED_DATA_STDERR = 1 # :nodoc:
    REMOTE_PACKET_THRESHOLD = 512 # headers etc # :nodoc:

    # Captures stdout only. Returns [String, Process::Status]
    def capture2(*args)
      stdin_inner, stdin_outer = IO.pipe
      stdout_outer, stdout_inner = IO.pipe

      stdin_data = args.last[:stdin_data] if Hash === args.last

      run_popen(*args,
                stdin: stdin_inner,
                stdout: stdout_inner,
                block_pipes: [stdin_outer, stdout_outer]) do |stdin, stdout, waiter_thread|
        stdin.write(stdin_data) if stdin_data
        stdin.close
        [stdout.read, waiter_thread.value]
      end
    end

    # Captures stdout and stderr into one string. Returns [String, Process::Status]
    def capture2e(*args)
      stdin_inner, stdin_outer = IO.pipe
      stdout_outer, stdout_inner = IO.pipe

      stdin_data = args.last[:stdin_data] if Hash === args.last

      run_popen(*args,
                stdin: stdin_inner,
                stdout: stdout_inner,
                stderr: stdout_inner,
                block_pipes: [stdin_outer, stdout_outer]) do |stdin, stdout, waiter_thread|
        stdin.write(stdin_data) if stdin_data
        stdin.close
        [stdout.read, waiter_thread.value]
      end
    end

    # Captures stdout and stderr into separate strings. Returns [String, String, Process::Status]
    def capture3(*args)
      stdin_inner, stdin_outer = IO.pipe
      stdout_outer, stdout_inner = IO.pipe
      stderr_outer, stderr_inner = IO.pipe

      stdin_data = args.last[:stdin_data] if Hash === args.last

      run_popen(*args,
                stdin: stdin_inner,
                stdout: stdout_inner,
                stderr: stderr_inner,
                block_pipes: [stdin_outer, stdout_outer, stderr_outer]) do |stdin, stdout, stderr, waiter_thread|
        stdin.write(stdin_data) if stdin_data
        stdin.close
        [stdout.read, stderr.read, waiter_thread.value]
      end
    end

    # Opens pipes to a remote process.
    # Yields +stdin+, +stdout+, +stderr+, +waiter_thread+ into a block. Will wait for a process to finish.
    # Joining (or getting a value of) +waither_thread+ inside a block will wait for a process right there.
    def popen3(*args, &block)
      stdin_inner, stdin_outer = IO.pipe
      stdout_outer, stdout_inner = IO.pipe
      stderr_outer, stderr_inner = IO.pipe

      run_popen(*args,
                stdin: stdin_inner,
                stdout: stdout_inner,
                stderr: stderr_inner,
                block_pipes: [stdin_outer, stdout_outer, stderr_outer],
                &block)
    end

    # Yields +stdin+, +stdout-stderr+, +waiter_thread+ into a block.
    def popen2e(*args, &block)
      stdin_inner, stdin_outer = IO.pipe
      stdout_outer, stdout_inner = IO.pipe

      run_popen(*args,
                stdin: stdin_inner,
                stdout: stdout_inner,
                stderr: stdout_inner,
                block_pipes: [stdin_outer, stdout_outer],
                &block)
    end

    # Yields +stdin+, +stdout+, +waiter_thread+ into a block.
    def popen2(*args, &block)
      stdin_inner, stdin_outer = IO.pipe
      stdout_outer, stdout_inner = IO.pipe

      run_popen(*args,
                stdin: stdin_inner,
                stdout: stdout_inner,
                block_pipes: [stdin_outer, stdout_outer],
                &block)
    end

    module NetSSHThreadSafeExtensions # :nodoc: all
      module Session
        def pinger_pipes
          @pinger_pipes ||= IO.pipe
        end

        def self.apply_to(session)
          unless session.respond_to?(:pinger_pipes)
          end
        end
      end

      module Channel
        def close_semaphore
          @close_semaphore ||= ConditionVariable.new
        end
      end
    end

    private
    def install_channel_callbacks(channel, options)
      logger, stdin, stdout, stderr =
        options[:logger], options[:stdin], options[:stdout], options[:stderr]

      channel.on_open_failed do |_channel, code, desc|
        message = "cannot open channel (error code #{code}): #{desc}"
        logger.error(message) if logger
        raise message
      end

      channel.on_data do |_channel, data|
        logger.stdout(data) if logger.respond_to?(:stdout)
        if stdout
          stdout.write(data)
          stdout.flush
        end
      end

      channel.on_extended_data do |_channel, type, data|
        if type == SSH_EXTENDED_DATA_STDERR
          logger.stderr(data) if logger.respond_to?(:stderr)
          if stderr
            stderr.write(data)
            stderr.flush
          end
        else
          logger.warn("unknown extended data type #{type}")
        end
      end

      channel.on_request('exit-status') do |_channel, data|
        channel.open3_waiter_thread[:status].tap do |status|
          status.instance_variable_set(:@exitstatus, data.read_long)
          logger.debug("exit status arrived: #{status.exitstatus}") if logger
        end
      end

      channel.on_request('exit-signal') do |_channel, data|
        channel.open3_waiter_thread[:status].tap do |status|
          status.instance_variable_set(:@termsig, data.read_string)
          status.instance_variable_set(:@coredump, data.read_bool)
          logger.debug("exit signal arrived: #{status.termsig.inspect}, core #{status.coredump?}") if logger
        end
      end

      channel.on_eof do
        logger.debug('server reports EOF') if logger
        [stdout, stderr].each { |io| io.close unless io.nil? || io.closed? }
      end

      channel.on_close do
        logger.debug('channel close command received, will enforce EOF afterwards') if logger
        if stdin
          self.stop_listening_to(stdin)
          stdin.close unless stdin.closed?
        end
        channel.do_eof # Should already be done, but just in case.
      end

      if stdin
        send_packet_size = [1024, channel.remote_maximum_packet_size - REMOTE_PACKET_THRESHOLD].max
        logger.debug("will split stdin into packets with size = #{send_packet_size}") if logger
        self.listen_to(stdin) do
          begin
            data = stdin.readpartial(send_packet_size)
            logger.stdin(data) if logger.respond_to?(:stdin)
            channel.send_data(data)
          rescue EOFError
            logger.debug('sending EOF command') if logger
            self.stop_listening_to(stdin)
            channel.eof!
          end
        end
      end
    end

    REDIRECT_MAPPING = { # :nodoc:
      in: '<',
      out: '>',
      err: '2>'
    }

    def run_popen(*args, internal_options)
      options = (args.pop if Hash === args.last) || {}
      env = (args.shift if Hash === args.first) || {}
      cmdline = args.size == 1 ? args.first : Shellwords.join(args)

      redirects = options[:redirects] and redirects.each_pair do |fd_and_dir, destination|
        cmdline += " #{REDIRECT_MAPPING[fd_and_dir] || fd_and_dir}#{popen_io_name(destination)}"
      end
      logger = options[:logger]
      pty_options = options[:pty]
      retries, delay = options[:channel_retries]
      retries ||= 5
      delay ||= 1

      logger.init(host: self.transport.host_as_string, cmdline: cmdline,
                  env: env, pty: pty_options) if logger.respond_to?(:init)

      begin
        channel = self.open3_open_channel do |channel|
          channel.request_pty(Hash === pty_options ? pty_options : {}) if pty_options
          env.each_pair { |var_name, var_value| channel.env(var_name, var_value) }

          channel.exec cmdline

          install_channel_callbacks channel,
            stdin: internal_options[:stdin],
            stdout: internal_options[:stdout],
            stderr: internal_options[:stderr],
            logger: logger
        end.open3_wait_open
      rescue ChannelOpenFailed
        logger.warn("channel open failed: #$!, #{retries} retries left") if logger
        if (retries -= 1) >= 0
          sleep delay
          retry
        else raise
        end
      end
      logger.debug('channel is open and ready, calling user-defined block') if logger
      yield(*internal_options[:block_pipes], channel.open3_waiter_thread).tap { channel.wait }
    ensure
      [
        *internal_options[:block_pipes],
        internal_options[:stdin],
        internal_options[:stdout],
        internal_options[:stderr]
      ].each { |io| io.close if io && !io.closed? }
    end

    def popen_io_name(name)
      Fixnum === name ? "&#{name}" : Shellwords.shellescape(name)
    end
  end

  class Connection::Session # :nodoc: all
    include Open3

    alias_method_once :initialize_without_open3, :initialize
    def initialize(*args, &block)
      initialize_without_open3(*args, &block)

      # #ping method will pull waiter thread out of select(2) call
      # to update watched Channels and IOs and process incomes.
      pinger_reader, @open3_pinger_writer = IO.pipe
      listen_to(pinger_reader) { pinger_reader.readpartial(1) }

      @open3_channels_mutex = Mutex.new
      @open3_channels_semaphore = ConditionVariable.new

      @session_loop = Thread.new do
        @open3_channels_mutex.synchronize do
          begin
            break unless preprocess { not closed? } # This may remove some channels.
            @open3_channels_semaphore.wait(@open3_channels_mutex) if channels.empty?

            r = listeners.keys
            w = r.select { |w2| w2.respond_to?(:pending_write?) && w2.pending_write? }
            readers, writers, = Compat.io_select(r, w, nil, nil)

            break unless postprocess(readers, writers) { closed? }
          rescue ChannelOpenFailed
            # Ignore this error; it should be passed to the corresponding thread.
          end
        end while not closed?
        channels.each do |_id, channel|
          @open3_channels_mutex.synchronize do
            channel.open3_signal_open
            channel.open3_signal_close
            channel.do_close
          end
        end
      end
    end

    def open3_open_channel(type = 'session', *extra, &on_confirm)
      @open3_channels_mutex.synchronize do
        local_id = get_next_channel_id
        channel = Connection::Channel.new(self, type, local_id, @max_pkt_size, @max_win_size, &on_confirm)
        channel.open3_waiter_thread = Thread.new do
          status = Thread.current[:status] = Process::Status.new
          @open3_channels_mutex.synchronize do
            msg = Buffer.from(:byte, CHANNEL_OPEN, :string, type, :long, local_id,
                              :long, channel.local_maximum_window_size,
                              :long, channel.local_maximum_packet_size, *extra)
            send_message(msg)
            channels[local_id] = channel

            @open3_channels_semaphore.signal
            channel.open3_close_semaphore.wait(@open3_channels_mutex) if channels.key?(channel.local_id)
          end
          raise *channel.open3_exception if channel.open3_exception
          status
        end

        open3_ping
        channel
      end
    end

    private
    def open3_ping
      @open3_pinger_writer.write(?P)
    end
  end

  class Connection::Channel # :nodoc: all
    attr_reader :open3_close_semaphore, :open3_exception, :open3_waiter_thread

    alias_method_once :initialize_without_open3, :initialize
    def initialize(*args, &block)
      initialize_without_open3(*args, &block)
      @open3_close_semaphore = ConditionVariable.new

      @open3_open_mutex = Mutex.new
      @open3_open_semaphore = ConditionVariable.new
    end

    alias_method_once :do_close_without_open3, :do_close
    def do_close(*args)
      do_close_without_open3(*args)
    rescue
      @open3_exception = $!
    ensure
      open3_signal_close
    end

    alias_method_once :do_open_confirmation_without_open3, :do_open_confirmation
    def do_open_confirmation(*args)
      do_open_confirmation_without_open3(*args)
    rescue
      @open3_exception = $!
    ensure
      open3_signal_open
    end

    alias_method_once :do_open_failed_without_open3, :do_open_failed
    def do_open_failed(*args)
      do_open_failed_without_open3(*args)
    rescue
      @open3_exception = $!
    ensure
      open3_signal_open
      open3_signal_close
    end

    def open3_waiter_thread=(value)
      @open3_waiter_thread = value unless @open3_waiter_thread
    end

    def open3_wait_open
      @open3_open_mutex.synchronize { @open3_open_semaphore.wait(@open3_open_mutex) }
      raise *open3_exception if open3_exception
      self
    end

    def wait
      @open3_waiter_thread.join
      self
    end

    def open3_signal_open
      @open3_open_mutex.synchronize { @open3_open_semaphore.signal }
    end

    # Should be called from within session's mutex.
    def open3_signal_close
      @open3_close_semaphore.signal
    end
  end
end
