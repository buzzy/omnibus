#
# Copyright 2012 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'fileutils'
require 'uri'
require 'omnibus/manifest_entry'

module Omnibus
  class Software
    class << self
      #
      # @param [Project] project
      #   the project that loaded this software definition
      # @param [String] name
      #   the path to the software definition to load from disk
      #
      # @return [Software]
      #
      def load(project, name, manifest)
        loaded_softwares["#{project.name}:#{name}"] ||= begin
          filepath = Omnibus.software_path(name)

          if filepath.nil?
            raise MissingSoftware.new(name)
          else
            log.internal(log_key) do
              "Loading software `#{name}' from `#{filepath}' using overrides from #{project.name}."
            end
          end

          instance = new(project, filepath, manifest)
          instance.evaluate_file(filepath)
          instance.load_dependencies

          # Add the loaded component to the library
          project.library.component_added(instance)

          instance
        end
      end

      private

      #
      # The list of softwares loaded thus far.
      #
      # @return [Hash<String, Software>]
      #
      def loaded_softwares
        @loaded_softwares ||= {}
      end
    end

    include Cleanroom
    include Digestable
    include Logging
    include NullArgumentable
    include Sugarable

    attr_reader :manifest

    #
    # Create a new software object.
    #
    # @param [Project] project
    #   the Omnibus project that instantiated this software definition
    # @param [String] filepath
    #   the path to where this software definition lives on disk
    # @param [String] manifest
    #   the user-supplied software manifest
    #
    # @return [Software]
    #
    def initialize(project, filepath = nil, manifest=nil)
      unless project.is_a?(Project)
        raise ArgumentError,
          "`project' must be a kind of `Omnibus::Project', but was `#{project.class.inspect}'!"
      end

      # Magical methods
      @filepath = filepath
      @project  = project
      @manifest = manifest

      # Overrides
      @overrides = NULL
    end

    def manifest_entry
      @manifest_entry ||= if manifest
                            log.info(log_key) {"Using user-supplied manifest entry for #{name}"}
                            manifest.entry_for(name)
                          else
                            log.info(log_key) {"Resolving manifest entry for #{name}"}
                            to_manifest_entry
                          end
    end

    #
    # Compare two software projects (by name).
    #
    # @return [1, 0, -1]
    #
    def <=>(other)
      self.name <=> other.name
    end

    #
    # @!group DSL methods
    #
    # The following DSL methods are available from within software definitions.
    # --------------------------------------------------

    #
    # The project that created this software.
    #
    # @return [Project]
    #
    def project
      @project
    end
    expose :project

    #
    # **[Required]** Sets or retreives the name of the software.
    #
    # @raise [MissingRequiredAttribute]
    #
    # @example
    #   name 'libxslt'
    #
    # @param [String] val
    #   name of the Software
    #
    # @return [String]
    #
    def name(val = NULL)
      if null?(val)
        @name || raise(MissingRequiredAttribute.new(self, :name, 'libxslt'))
      else
        @name = val
      end
    end
    expose :name

    #
    # Sets the description of the software.
    #
    # @example
    #   description 'Installs libxslt'
    #
    # @param [String] val
    #   the description of the software
    #
    # @return [String]
    #
    def description(val = NULL)
      if null?(val)
        @description
      else
        @description = val
      end
    end
    expose :description


    #
    # Sets the maintainer of the software.  Currently this is for
    # human consumption only and the tool doesn't do anything with it.
    #
    # @example
    #   maintainer "Joe Bob <joeb@chef.io>"
    #
    # @param [String] val
    #   the maintainer of this sofware def
    #
    # @return [String]
    #
    def maintainer(val = NULL)
      if null?(val)
        @maintainer
      else
        @description = val
      end
    end
    expose :maintainer

    #
    # Add a software dependency to this software.
    #
    # @example
    #   dependency 'libxml2'
    #   dependency 'libpng'
    #
    # @param [String] val
    #   the name of a software dependency
    #
    # @return [Array<String>]
    #   the list of current dependencies
    #
    def dependency(val)
      dependencies << val
      dependencies.dup.sort!
    end
    expose :dependency

    #
    # Set or retrieve the source for the software.
    #
    # @raise [InvalidValue]
    #   if the parameter is not a Hash
    # @raise [InvalidValue]
    #   if the hash includes extraneous keys
    # @raise [InvalidValue]
    #   if the hash declares keys that cannot work together
    #   (like +:git+ and +:path+)
    #
    # @example
    #   source url: 'http://ftp.gnu.org/gnu/autoconf/autoconf-2.68.tar.gz',
    #          md5: 'c3b5247592ce694f7097873aa07d66fe'
    #
    # @param [Hash<Symbol, String>] val
    #   a single key/pair that defines the kind of source and a path specifier
    #
    # @option val [String] :git (nil)
    #   a git URL
    # @option val [String] :url (nil)
    #   general URL
    # @option val [String] :path (nil)
    #   a fully-qualified local file system path
    # @option val [String] :md5 (nil)
    #   the MD5 checksum of the downloaded artifact
    # @option val [String] :sha1 (nil)
    #   the SHA1 checksum of the downloaded artifact
    # @option val [String] :sha256 (nil)
    #   the SHA256 checksum of the downloaded artifact
    # @option val [String] :sha512 (nil)
    #   the SHA512 checksum of the downloaded artifact
    #
    # Only used in net_fetcher:
    #
    # @option val [String] :cookie (nil)
    #   a cookie to set
    # @option val [String] :warning (nil)
    #   a warning message to print when downloading
    # @option val [Symbol] :extract (nil)
    #   either :tar, :lax_tar :seven_zip
    #
    # Only used in path_fetcher:
    #
    # @option val [Hash] :options (nil)
    #   flags/options that are passed through to file_syncer in path_fetcher
    #
    # Only used in git_fetcher:
    #
    # @option val [Boolean] :submodules (false)
    #   clone git submodules
    #
    # If multiple checksum types are provided, only the strongest will be used.
    #
    # @return [Hash]
    #
    def source(val = NULL)
      unless null?(val)
        unless val.is_a?(Hash)
          raise InvalidValue.new(:source,
            "be a kind of `Hash', but was `#{val.class.inspect}'")
        end

        extra_keys = val.keys - [
          :git, :path, :url, # fetcher types
          :md5, :sha1, :sha256, :sha512, # hash type - common to all fetchers
          :cookie, :warning, :unsafe, :extract, # used by net_fetcher
          :options, # used by path_fetcher
          :submodules # used by git_fetcher
        ]
        unless extra_keys.empty?
          raise InvalidValue.new(:source,
            "only include valid keys. Invalid keys: #{extra_keys.inspect}")
        end

        duplicate_keys = val.keys & [:git, :path, :url]
        unless duplicate_keys.size < 2
          raise InvalidValue.new(:source,
            "not include duplicate keys. Duplicate keys: #{duplicate_keys.inspect}")
        end

        @source ||= {}
        @source.merge!(val)
      end

      apply_overrides(:source)
    end
    expose :source

    #
    # Set or retrieve the {#default_version} of the software to build.
    #
    # @example
    #   default_version '1.2.3'
    #
    # @param [String] val
    #   the default version to set for the software.
    #   For a git source, the default version may be a git ref (e.g. tag, branch name, or sha).
    #
    # @return [String]
    #
    def default_version(val = NULL)
      if null?(val)
        @version
      else
        @version = val
      end
    end
    expose :default_version

    #
    # Evaluate a block only if the version matches.
    #
    # @example
    #   version '1.2.3' do
    #     source path: '/local/path/to/software-1.2.3'
    #   end
    #
    # @param [String] val
    #   the version of the software
    # @param [Proc] block
    #   the block to run if the version we are building matches the argument
    #
    # @return [String, Proc]
    #
    def version(val = NULL, &block)
      final_version = apply_overrides(:version)

      if block_given?
        if val.equal?(NULL)
          raise InvalidValue.new(:version,
            'pass a block when given a version argument')
        else
          if val == final_version
            block.call
          end
        end
      end

      return if final_version.nil?

      begin
        Chef::Sugar::Constraints::Version.new(final_version)
      rescue ArgumentError
        log.warn(log_key) do
          "Version #{final_version} for software #{name} was not parseable. " \
          'Comparison methods such as #satisfies? will not be available for this version.'
        end
        final_version
      end
    end
    expose :version

    #
    # Add a file to the healthcheck whitelist.
    #
    # @example
    #   whitelist_file '/path/to/file'
    #
    # @param [String, Regexp] file
    #   the name of a file to ignore in the healthcheck
    #
    # @return [Array<String>]
    #   the list of currently whitelisted files
    #
    def whitelist_file(file)
      file = Regexp.new(file) unless file.kind_of?(Regexp)
      whitelist_files << file
      whitelist_files.dup
    end
    expose :whitelist_file

    #
    # The path relative to fetch_dir where relevant project files are
    # stored. This applies to all sources.
    #
    # Any command executed in the build step are run after cwd-ing into
    # this path. The default is to stay at the top level of fetch_dir
    # where the source tar-ball/git repo/file/directory has been staged.
    #
    # @example
    #   relative_path 'example-1.2.3'
    #
    # @param [String] val
    #   the relative path inside the source directory. default: '.'
    #
    # Due to back-compat reasons, relative_path works completely
    # differently for anything other than tar-balls/archives. In those
    # situations, the source is checked out rooted at relative_path
    # instead 'cause reasons.
    # TODO: Fix this in omnibus 6.
    #
    # @return [String]
    #
    def relative_path(val = NULL)
      if null?(val)
        @relative_path || '.'
      else
        @relative_path = val
      end
    end
    expose :relative_path

    #
    # The path where the extracted software lives. All build commands
    # associated with this software definition are run for under this path.
    #
    # Why is it called project_dir when this is a software definition, I hear
    # you cry. Because history and reasons. This really is a location
    # underneath the global omnibus source directory that you have focused
    # into using relative_path above.
    #
    # These are not the only files your project fetches. They are merely the
    # files that your project cares about. A source tarball may contain more
    # directories that are not under your project_dir.

    # The file (if any) containing the license
    # TODO - Should accept a block
    def license(val = NULL)
      if null?(val)
        licenses = []
        unless @licenses.nil?
          @licenses.each do |one_license|
            unless one_license[:path].nil?
              contents = File.open(
                File.join(project_dir, one_license[:path]),
                external_encoding: one_license[:encoding]
              ).read()
            end

            unless one_license[:url].nil?
              contents = one_license[:url]
            end

            if one_license[:encoding]
              contents.encode!(Encoding::UTF_8)
            end

            pos = unless one_license[:cue].nil?
                    contents.index(one_license[:cue])
                  else
                    0
                  end
            licenses.push(contents[pos..-1])
          end
          licenses
        end
      else
        unless val.is_a?(Hash)
          raise InvalidValue.new(:license,
            "be a kind of `Hash', but was `#{val.class.inspect}'")
        end

        extra_keys = val.keys - [:path, :cue, :encoding, :url]
        unless extra_keys.empty?
          raise InvalidValue.new(:license,
            "only include valid keys. Invalid keys: #{extra_keys.inspect}")
        end

        duplicate_keys = val.keys & [:path, :url]
        unless duplicate_keys.size < 2
          raise InvalidValue.new(:license,
            "not include duplicate keys. Duplicate keys: #{duplicate_keys.inspect}")
        end

        @licenses ||= []
        @licenses.push(val)
      end
    end
    expose :license

    #
    # The path where the extracted software lives.

    #
    # @return [String]
    #
    def project_dir
      File.expand_path("#{fetch_dir}/#{relative_path}")
    end
    expose :project_dir

    #
    # The path where the software will be built.
    #
    # @return [String]
    #
    def build_dir
      File.expand_path("#{Config.build_dir}/#{project.name}")
    end
    expose :build_dir

    #
    # The directory where this software is installed on disk.
    #
    # @example
    #   { 'PATH' => "#{install_dir}/embedded/bin:#{ENV["PATH"]}", }
    #
    # @return [String]
    #
    def install_dir
      @project.install_dir
    end
    expose :install_dir

    #
    # Define a series of {Builder} DSL commands that are executed to build the
    # software.
    #
    # @see Builder
    #
    # @param [Proc] block
    #   a block of build commands
    #
    # @return [Proc]
    #   the build block
    #
    def build(&block)
      builder.evaluate(&block)
    end
    expose :build

    #
    # The path to the downloaded file from a NetFetcher.
    #
    # @deprecated There is no replacement for this DSL method
    #
    def project_file
      if fetcher && fetcher.is_a?(NetFetcher)
        log.deprecated(log_key) do
          "project_file (DSL). This is a property of the NetFetcher and will " \
          "not be publically exposed in the next major release. In general, " \
          "you should not be using this method in your software definitions " \
          "as it is an internal implementation detail of the NetFetcher. If " \
          "you disagree with this statement, you should open an issue on the " \
          "Omnibus repository on GitHub an explain your use case. For now, " \
          "I will return the path to the downloaded file on disk, but please " \
          "rethink the problem you are trying to solve :)."
        end

        fetcher.downloaded_file
      else
        log.warn(log_key) do
          "Cannot retrieve a `project_file' for software `#{name}'. This " \
          "attribute is actually an internal representation that is unique " \
          "to the NetFetcher class and requires the use of a `source' " \
          "attribute that is declared using a `:url' key. For backwards-" \
          "compatability, I will return `nil', but this is most likely not " \
          "your desired behavior."
        end

        nil
      end
    end
    expose :project_file

    #
    # Add standard compiler flags to the environment hash to produce omnibus
    # binaries (correct RPATH, etc).
    #
    # Supported options:
    #    :aix => :use_gcc    force using gcc/g++ compilers on aix
    #    :bfd_flags => true   the default build targets for windows based on
    #       the current platform architecture are added ARFLAGS and RCFLAGS.
    #
    # @param [Hash] env
    # @param [Hash] opts
    #
    # @return [Hash]
    #
    def with_standard_compiler_flags(env = {}, opts = {})
      env ||= {}
      opts ||= {}
      compiler_flags =
        case Ohai['platform']
        when "aix"
          {
            "CC" => "xlc_r -q64",
            "CXX" => "xlC_r -q64",
            "CFLAGS" => "-q64 -I#{install_dir}/embedded/include -D_LARGE_FILES -O",
            "LDFLAGS" => "-q64 -L#{install_dir}/embedded/lib -Wl,-blibpath:#{install_dir}/embedded/lib:/usr/lib:/lib",
            "LD" => "ld -b64",
            "OBJECT_MODE" => "64",
            "ARFLAGS" => "-X64 cru",
          }
        when "mac_os_x"
          {
            "LDFLAGS" => "-L#{install_dir}/embedded/lib",
            "CFLAGS" => "-I#{install_dir}/embedded/include -O2",
          }
        when "solaris2"
          {
            # this override is due to a bug in libtool documented here:
            # http://lists.gnu.org/archive/html/bug-libtool/2005-10/msg00004.html
            "CC" => "gcc -static-libgcc",
            "LDFLAGS" => "-R#{install_dir}/embedded/lib -L#{install_dir}/embedded/lib -static-libgcc",
            "CFLAGS" => "-I#{install_dir}/embedded/include",
          }
        when "freebsd"
          freebsd_flags = {
            "LDFLAGS" => "-L#{install_dir}/embedded/lib",
            "CFLAGS" => "-I#{install_dir}/embedded/include -O2",
          }
          # Clang became the default compiler in FreeBSD 10+
          if Ohai['os_version'].to_i >= 1000024
            freebsd_flags.merge!(
              "CC" => "clang",
              "CXX" => "clang++",
            )
          end
          freebsd_flags
        when "windows"
          arch_flag = windows_arch_i386? ? "-m32" : "-m64"
          opt_flag = windows_arch_i386? ? "-march=i686" : "-march=x86-64"
          {
            "LDFLAGS" => "-L#{install_dir}/embedded/lib #{arch_flag}",
            # If we're happy with these flags, enable SSE for other platforms running x86 too.
            "CFLAGS" => "-I#{install_dir}/embedded/include #{arch_flag} -O3 -mfpmath=sse -msse2 #{opt_flag}"
          }
        else
          {
            "LDFLAGS" => "-Wl,-rpath,#{install_dir}/embedded/lib -L#{install_dir}/embedded/lib",
            "CFLAGS" => "-I#{install_dir}/embedded/include -O2",
          }
        end

      # There are some weird, misbehaving makefiles on windows that hate ARFLAGS because it
      # replaces the "rcs" flags in some build steps.  So we provide this flag behind an
      # optional flag.
      if opts[:bfd_flags] && windows?
        bfd_target = windows_arch_i386? ? "pe-i386" : "pe-x86-64"
        compiler_flags.merge!(
          {
            "RCFLAGS" => "--target=#{bfd_target}",
            "ARFLAGS" => "--target=#{bfd_target}",
          }
        )
      end

      # Add extra CFLAGS and LDFLAGS if required in the configuration
      unless Config.inject_cflags.empty?
        compiler_flags["CFLAGS"] = "#{compiler_flags["CFLAGS"]} #{Config.inject_cflags}"
      end

      unless Config.inject_ldflags.empty?
        compiler_flags["LDFLAGS"] = "#{compiler_flags["LDFLAGS"]} #{Config.inject_ldflags}"
      end

      # merge LD_RUN_PATH into the environment.  most unix distros will fall
      # back to this if there is no LDFLAGS passed to the linker that sets
      # the rpath.  the LDFLAGS -R or -Wl,-rpath will override this, but in
      # some cases software may drop our LDFLAGS or think it knows better
      # and edit them, and we *really* want the rpath setting and do know
      # better.  in that case LD_RUN_PATH will probably survive whatever
      # edits the configure script does
      extra_linker_flags = {
        "LD_RUN_PATH" => "#{install_dir}/embedded/lib"
      }

      if solaris2?
        # in order to provide compatibility for earlier versions of libc on solaris 10,
        # we need to specify a mapfile that restricts the version of system libraries
        # used. See http://docs.oracle.com/cd/E23824_01/html/819-0690/chapter5-1.html
        # for more information
        # use the mapfile if it exists, otherwise ignore it
        ld_options = "-R#{install_dir}/embedded/lib"
        mapfile_path = File.expand_path(Config.solaris_linker_mapfile, Config.project_root)
        ld_options  << " -M #{mapfile_path}" if File.exist?(mapfile_path)

        # solaris linker can also use LD_OPTIONS, so we throw the kitchen sink against
        # the linker, to find every way to make it use our rpath. This is also required
        # to use the aforementioned mapfile.
        extra_linker_flags.merge!(
          {
            "LD_OPTIONS" => ld_options
          }
        )
      end

      env.merge(compiler_flags).
        merge(extra_linker_flags).
        # always want to favor pkg-config from embedded location to not hose
        # configure scripts which try to be too clever and ignore our explicit
        # CFLAGS and LDFLAGS in favor of pkg-config info
        merge({"PKG_CONFIG_PATH" => "#{install_dir}/embedded/lib/pkgconfig"}).
        # Set default values for CXXFLAGS and CPPFLAGS.
        merge('CXXFLAGS' => compiler_flags['CFLAGS']).
        merge('CPPFLAGS' => compiler_flags['CFLAGS'])
    end
    expose :with_standard_compiler_flags

    #
    # A PATH variable format string representing the current PATH with the
    # project's embedded/bin directory prepended. The correct path separator
    # for the platform is used to join the paths.
    #
    # @param [Hash] env
    # @param [Hash] opts
    #   :msys => true  add the embedded msys path if building on windows.
    #
    # @return [Hash]
    #
    def with_embedded_path(env = {}, opts = {})
      paths = ["#{install_dir}/bin", "#{install_dir}/embedded/bin"]
      paths << "#{install_dir}/embedded/msys/1.0/bin" if opts[:msys] && windows?
      path_value = prepend_path(paths)
      env.merge(path_key => path_value)
    end
    expose :with_embedded_path

    #
    # A PATH variable format string representing the current PATH with the
    # given path prepended. The correct path separator
    # for the platform is used to join the paths.
    #
    # @param [Array<String>] paths
    #
    # @return [String]
    #
    def prepend_path(*paths)
      path_values = Array(paths)
      path_values << ENV[path_key]

      separator = File::PATH_SEPARATOR || ':'
      path_values.join(separator)
    end
    expose :prepend_path

    #
    # A proxy method to the underlying Ohai system.
    #
    # @example
    #   ohai['platform_family']
    #
    # @return [Ohai]
    #
    def ohai
      Ohai
    end
    expose :ohai

    #
    # @!endgroup
    # --------------------------------------------------

    #
    # @!group Public API
    #
    # In addition to the DSL methods, the following methods are considered to
    # be the "public API" for a software.
    # --------------------------------------------------

    #
    # Recursively load all the dependencies for this software.
    #
    # @return [true]
    #
    def load_dependencies
      dependencies.each do |dependency|
        Software.load(project, dependency, manifest)
      end

      true
    end

    #
    # The builder object for this software definition.
    #
    # @return [Builder]
    #
    def builder
      @builder ||= Builder.new(self)
    end

    def to_manifest_entry
      Omnibus::ManifestEntry.new(name, {
                                   source_type: source_type,
                                   described_version: version,
                                   locked_version: Fetcher.resolve_version(version, source),
                                   locked_source: source})
    end

    #
    # Fetch the software definition using the appropriate fetcher. This may
    # fetch the software from a local path location, git location, or download
    # the software from a remote URL (HTTP(s)/FTP)
    #
    # @return [true, false]
    #   true if the software was fetched, false if it was cached
    #
    def fetch
      if fetcher.fetch_required?
        fetcher.fetch
        true
      else
        false
      end
    end

    #
    # The list of software dependencies for this software. These is the software
    # that comprises your software, and is distinct from runtime dependencies.
    #
    # @see #dependency
    #
    # @param [Array<String>]
    #
    # @return [Array<String>]
    #
    def dependencies
      @dependencies ||= []
    end

    #
    # The list of files to ignore in the healthcheck.
    #
    # @return [Array<String>]
    #
    def whitelist_files
      @whitelist_files ||= []
    end

    #
    # The path (on disk) where this software came from. Warning: this can be
    # +nil+ if a software was dynamically created!
    #
    # @return [String, nil]
    #
    def filepath
      @filepath
    end

    #
    # The repo-level and project-level overrides for the software.
    #
    # @return [Hash]
    #
    def overrides
      if null?(@overrides)
        # lazily initialized because we need the 'name' to be parsed first
        @overrides = {}
        @overrides = project.overrides[name.to_sym].dup if project.overrides[name.to_sym]
      end

      @overrides
    end

    #
    # Determine if this software version overridden externally, relative to the
    # version declared within the software DSL file?
    #
    # @return [true, false]
    #
    def overridden?
      # NOTE: using instance variables to bypass accessors that enforce overrides
      @overrides.key?(:version) && (@overrides[:version] != @version)
    end

    #
    # @!endgroup
    # --------------------------------------------------

    #
    # Path to where any source is extracted to.
    #
    # Files in a source directory are staged underneath here. Files from
    # a url are fetched and extracted here. Look outside this directory
    # at your own peril.
    #
    # @return [String] the full absolute path to the software root fetch
    #   directory.
    #
    def fetch_dir(val = NULL)
      if null?(val)
        @fetch_dir || File.expand_path("#{Config.source_dir}/#{name}")
      else
        @fetch_dir = val
      end
    end

    # @todo see comments on {Omnibus::Fetcher#without_caching_for}
    def version_guid
      fetcher.version_guid
    end

    # Returns the version to be used in cache.
    def version_for_cache
      @version_for_cache ||= if fetcher.version_for_cache
        fetcher.version_for_cache
      elsif version
        version
      else
        log.warn(log_key) do
          "No version given! This is probably a bad thing. I am going to " \
          "assume the version `0.0.0', but that is most certainly not your " \
          "desired behavior. If git caching seems off, this is probably why."
        end

        '0.0.0'
      end
    end

    #
    # The fetcher for this software
    #
    # This is where we handle all the crazy back-compat on relative_path.
    # All fetchers in omnibus 4 use relative_path incorrectly. net_fetcher was
    # the only one to use to sensibly, and even then only if fetch_dir was
    # Config.source_dir and the source was an archive. Therefore, to not break
    # everyone ever, we will still pass project_dir for all other fetchers.
    # There is still one issue where other omnibus software (such as the
    # appbundler dsl) currently assume that fetch_dir the same as source_dir.
    # Therefore, we make one extra concession - when relative_path is set in a
    # software definition to be the same as name (a very common scenario), we
    # land the source into the fetch directory instead of project_dir. This
    # is to avoid fiddling with the appbundler dsl until it gets sorted out.
    #
    # @return [Fetcher]
    #
    def fetcher
      @fetcher ||=
        if source_type == :url && File.basename(source[:url], '?*').end_with?(*NetFetcher::ALL_EXTENSIONS)
          Fetcher.fetcher_class_for_source(self.source).new(manifest_entry, fetch_dir, build_dir)
        else
          Fetcher.fetcher_class_for_source(self.source).new(manifest_entry, project_dir, build_dir)
        end
    end

    #
    # The type of source specified for this software defintion.
    #
    # @return [Symbol]
    #
    def source_type
      if source
        if source[:url]
          :url
        elsif source[:git]
          :git
        elsif source[:path]
          :path
        end
      else
        :project_local
      end
    end

    #
    # Build the software package. If git caching is turned on (see
    # {Config#use_git_caching}), the build is restored according to the
    # documented restoration procedure in the git cache. If the build cannot
    # be restored (if the tag does not exist), the actual build steps are
    # executed.
    #
    # @return [true]
    #
    def build_me
      if Config.use_git_caching
        if project.dirty?
          log.info(log_key) do
            "Building because `#{project.culprit.name}' dirtied the cache"
          end
          execute_build
        elsif git_cache.restore
          log.info(log_key) { "Restored from cache" }
        else
          log.info(log_key) { "Could not restore from cache" }
          execute_build
          project.dirty!(self)
        end
      else
        log.debug(log_key) { "Forcing build because git caching is off" }
        execute_build
      end

      project.build_version_dsl.resolve(self)
      true
    end

    #
    # The unique "hash" for this software.
    #
    # @see (#shasum)
    #
    # @return [Fixnum]
    #
    def hash
      shasum.hash
    end

    #
    # Determine if two softwares are identical.
    #
    # @param [Software] other
    #
    # @return [true, false]
    #
    def ==(other)
      self.hash == other.hash
    end
    alias_method :eql?, :==

    #
    # The unique SHA256 for this sofware definition.
    #
    # A software is defined by its parent project's shasum, its own name, its
    # version_for_cache, and any overrides (as JSON). Additionally, if provided,
    # the actual file contents are included in the SHA to ensure uniqueness.
    #
    # @return [String]
    #
    def shasum
      @shasum ||= begin
        digest = Digest::SHA256.new

        update_with_string(digest, project.shasum)
        update_with_string(digest, builder.shasum)
        update_with_string(digest, name)
        update_with_string(digest, version_for_cache)
        update_with_string(digest, JSON.fast_generate(overrides))

        log.internal(log_key) { "project.shasum: #{project.shasum}" }
        log.internal(log_key) { "builder.shasum: #{builder.shasum}" }
        log.internal(log_key) { "name: #{name}" }
        log.internal(log_key) { "version_for_cache: #{version_for_cache}" }
        log.internal(log_key) { "overrides: #{JSON.fast_generate(overrides)}" }

        if filepath && File.exist?(filepath)
          update_with_file_contents(digest, filepath)
          log.internal(log_key) { "filepath: #{filepath}" }
        else
          update_with_string(digest, '<DYNAMIC>')
          log.internal(log_key) { "filepath: <DYNAMIC>" }
        end

        digest.hexdigest
      end
    end

    private

    #
    # The git caching implementation for this software.
    #
    # @return [GitCache]
    #
    def git_cache
      @git_cache ||= GitCache.new(self)
    end

    #
    # The proper platform-specific "$PATH" key.
    #
    # @return [String]
    #
    def path_key
      # The ruby devkit needs ENV['Path'] set instead of ENV['PATH'] because
      # $WINDOWSRAGE, and if you don't set that your native gem compiles
      # will fail because the magic fixup it does to add the mingw compiler
      # stuff won't work.
      #
      # Turns out there is other build environments that only set ENV['PATH'] and if we
      # modify ENV['Path'] then it ignores that.  So, we scan ENV and returns the first
      # one that we find.
      #
      if Ohai['platform'] == 'windows'
        ENV.keys.grep(/\Apath\Z/i).first
      else
        'PATH'
      end
    end

    #
    # Apply overrides in the @overrides hash that mask instance variables
    # that are set by parsing the DSL
    #
    def apply_overrides(attr)
      val = instance_variable_get(:"@#{attr}")
      if val.is_a?(Hash) || overrides[attr].is_a?(Hash)
        val ||= {}
        override = overrides[attr] || {}
        val.merge(override)
      else
        overrides[attr] || val
      end
    end

    #
    # Actually build this software, executing the steps provided in the
    # {#build} block and dirtying the cache.
    #
    # @return [void]
    #
    def execute_build
      fetcher.clean
      builder.build

      if Config.use_git_caching
        git_cache.incremental
        log.info(log_key) { 'Dirtied the cache' }
      end
    end

    #
    # The log key for this software, including its name.
    #
    # @return [String]
    #
    def log_key
      @log_key ||= "#{super}: #{name}"
    end

    def to_s
      "#{name}[#{filepath}]"
    end
  end
end
