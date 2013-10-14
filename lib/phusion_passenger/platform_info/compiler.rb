#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010-2013 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'phusion_passenger/platform_info'
require 'phusion_passenger/platform_info/operating_system'

module PhusionPassenger

module PlatformInfo
private
	def self.detect_language_extension(language)
		case language
		when :c
			return "c"
		when :cxx
			return "cpp"
		else
			raise ArgumentError, "Unsupported language #{language.inspect}"
		end
	end
	private_class_method :detect_language_extension

	def self.create_compiler_command(language, flags1, flags2, link = false)
		case language
		when :c
			result  = [cc, link ? ENV['EXTRA_PRE_LDFLAGS'] : nil,
				ENV['EXTRA_PRE_CFLAGS'], flags1, flags2, ENV['EXTRA_CFLAGS'],
				ENV['EXTRA_LDFLAGS']]
		when :cxx
			result  = [cxx, link ? ENV['EXTRA_PRE_LDFLAGS'] : nil,
				ENV['EXTRA_PRE_CXXFLAGS'], flags1, flags2, ENV['EXTRA_CXXFLAGS'],
				ENV['EXTRA_LDFLAGS']]
		else
			raise ArgumentError, "Unsupported language #{language.inspect}"
		end
		return result.compact.join(" ").strip
	end
	private_class_method :create_compiler_command

	def self.run_compiler(description, command, source_file, source, capture_output = false)
		if verbose?
			message = "#{description}\n" <<
				"Running: #{command}\n"
			if source.strip.empty?
				message << "Source file is empty."
			else
				message << "Source file contains:\n" <<
					"-------------------------\n" <<
					unindent(source) <<
					"\n-------------------------"
			end
			log(message)
		end
		if capture_output
			begin
				output = `#{command} 2>&1`
				result = $?.exitstatus == 0
			rescue SystemCallError => e
				result = nil
				exec_error_reason = e.message
			end
			log("Output:\n" <<
				"-------------------------\n" <<
				output.to_s <<
				"\n-------------------------")
		elsif verbose?
			result = system(command)
		else
			result = system("(#{command}) >/dev/null 2>/dev/null")
		end
		if result.nil?
			log("Command could not be executed! #{exec_error_reason}".strip)
			return false
		elsif result
			log("Check suceeded")
			if capture_output
				return { :output => output }
			else
				return true
			end
		else
			log("Check failed with exit status #{$?.exitstatus}")
			return false
		end
	end
	private_class_method :run_compiler

public
	def self.cc
		return string_env('CC', default_cc)
	end
	
	def self.cxx
		return string_env('CXX', default_cxx)
	end

	def self.default_cc
		# OS X Mavericks (10.9) switched from GCC to Clang as the default compiler,
		# i.e. as an alias for 'cc'. Since the Nginx by default uses 'cc' as the compiler,
		# we'll have to do that too. Otherwise we'll get C++ linker errors because Nginx
		# is compiled with Clang while Phusion Passenger is compiled with GCC.
		# https://code.google.com/p/phusion-passenger/issues/detail?id=950
		if PlatformInfo.os_name == "macosx"
			return 'cc'
		else
			return 'gcc'
		end
	end

	def self.default_cxx
		if PlatformInfo.os_name == "macosx"
			return 'c++'
		else
			return 'g++'
		end
	end

	def self.cc_is_gcc?
		`#{cc} -v 2>&1` =~ /gcc version/
	end
	memoize :cc_is_gcc?

	def self.cc_is_clang?
		`#{cc} --version 2>&1` =~ /clang version/
	end
	memoize :cc_is_clang?

	def self.cxx_is_clang?
		`#{cxx} --version 2>&1` =~ /clang version/
	end
	memoize :cxx_is_clang?

	def self.cc_is_sun_studio?
		`#{cc} -V 2>&1` =~ /Sun C/ || `#{cc} -flags 2>&1` =~ /Sun C/
	end
	memoize :cc_is_sun_studio?


	# Looks for the given C or C++ header. This works by invoking the compiler and
	# searching in the compiler's header search path. Returns its full filename,
	# or true if this function knows that the header exists but can't find it (e.g.
	# because the compiler cannot tell us what its header search path is).
	# Returns nil if the header cannot be found.
	def self.find_header(header_name, language, flags = nil)
		extension = detect_language_extension(language)
		create_temp_file("passenger-compile-check.#{extension}") do |filename, f|
			source = %Q{
				#include <#{header_name}>
			}
			f.puts(source)
			f.close
			begin
				command = create_compiler_command(language,
					"-v -c '#{filename}' -o '#{filename}.o'",
					flags)
				if result = run_compiler("Checking for #{header_name}", command, filename, source, true)
					result[:output] =~ /^#include <...> search starts here:$(.+?)^End of search list\.$/m
					search_paths = $1.to_s.strip.split("\n").map{ |line| line.strip }
					search_paths.each do |dir|
						if File.file?("#{dir}/#{header_name}")
							return "#{dir}/#{header_name}"
						end
					end
					return true
				else
					return nil
				end
			ensure
				File.unlink("#{filename}.o") rescue nil
			end
		end
	end

	def self.try_compile(description, language, source, flags = nil)
		extension = detect_language_extension(language)
		create_temp_file("passenger-compile-check.#{extension}") do |filename, f|
			f.puts(source)
			f.close
			begin
				command = create_compiler_command(language,
					"-c '#{filename}' -o '#{filename}.o'",
					flags)
				return run_compiler(description, command, filename, source)
			ensure
				File.unlink("#{filename}.o") rescue nil
			end
		end
	end
	
	def self.try_link(description, language, source, flags = nil)
		extension = detect_language_extension(language)
		create_temp_file("passenger-link-check.#{extension}") do |filename, f|
			f.puts(source)
			f.close
			begin
				command = create_compiler_command(language,
					"'#{filename}' -o '#{filename}.out'",
					flags, true)
				return run_compiler(description, command, filename, source)
			ensure
				File.unlink("#{filename}.out") rescue nil
			end
		end
	end
	
	def self.try_compile_and_run(description, language, source, flags = nil)
		extension = detect_language_extension(language)
		create_temp_file("passenger-run-check.#{extension}", tmpexedir) do |filename, f|
			f.puts(source)
			f.close
			begin
				command = create_compiler_command(language,
					"'#{filename}' -o '#{filename}.out'",
					flags, true)
				if run_compiler(description, command, filename, source)
					log("Running #{filename}.out")
					begin
						output = `'#{filename}.out' 2>&1`
					rescue SystemCallError => e
						log("Command failed: #{e}")
						return false
					end
					status = $?.exitstatus
					log("Command exited with status #{status}. Output:\n--------------\n#{output}\n--------------")
					return status == 0
				else
					return false
				end
			ensure
				File.unlink("#{filename}.out") rescue nil
			end
		end
	end


	# Checks whether the compiler supports "-arch #{arch}".
	def self.compiler_supports_architecture?(arch)
		return try_compile("Checking for C compiler '-arch' support",
			:c, '', "-arch #{arch}")
	end
	
	def self.compiler_supports_visibility_flag?
		return false if os_name =~ /aix/
		return try_compile("Checking for C compiler '-fvisibility' support",
			:c, '', '-fvisibility=hidden')
	end
	memoize :compiler_supports_visibility_flag?, true
	
	def self.compiler_supports_wno_attributes_flag?
		return try_compile("Checking for C compiler '-Wno-attributes' support",
			:c, '', '-Wno-attributes')
	end
	memoize :compiler_supports_wno_attributes_flag?, true

	def self.compiler_supports_wno_missing_field_initializers_flag?
		return try_compile("Checking for C compiler '-Wno-missing-field-initializers' support",
			:c, '', '-Wno-missing-field-initializers')
	end
	memoize :compiler_supports_wno_missing_field_initializers_flag?, true
	
	def self.compiler_supports_no_tls_direct_seg_refs_option?
		return try_compile("Checking for C compiler '-mno-tls-direct-seg-refs' support",
			:c, '', '-mno-tls-direct-seg-refs')
	end
	memoize :compiler_supports_no_tls_direct_seg_refs_option?, true

	def self.compiler_supports_wno_ambiguous_member_template?
		return try_compile("Checking for C compiler '-Wno-ambiguous-member-template' support",
			:c, '', '-Wno-ambiguous-member-template')
	end
	memoize :compiler_supports_wno_ambiguous_member_template?, true

	def self.compiler_supports_feliminate_unused_debug?
		create_temp_file("passenger-compile-check.c") do |filename, f|
			f.close
			begin
				command = create_compiler_command(:c,
					"-c '#{filename}' -o '#{filename}.o'",
					'-feliminate-unused-debug-symbols -feliminate-unused-debug-types')
				result = run_compiler("Checking for C compiler '--feliminate-unused-debug-{symbols,types}' support",
					command, filename, '', true)
				return result && result[:output].empty?
			ensure
				File.unlink("#{filename}.o") rescue nil
			end
		end
	end
	
	# Returns whether compiling C++ with -fvisibility=hidden might result
	# in tons of useless warnings, like this:
	# http://code.google.com/p/phusion-passenger/issues/detail?id=526
	# This appears to be a bug in older g++ versions:
	# http://gcc.gnu.org/ml/gcc-patches/2006-07/msg00861.html
	# Warnings should be suppressed with -Wno-attributes.
	def self.compiler_visibility_flag_generates_warnings?
		if os_name =~ /linux/ && `#{cxx} -v 2>&1` =~ /gcc version (.*?)/
			return $1 <= "4.1.2"
		else
			return false
		end
	end
	memoize :compiler_visibility_flag_generates_warnings?, true
	
	def self.has_math_library?
		return try_link("Checking for -lmath support",
			:c, "int main() { return 0; }\n", '-lmath')
	end
	memoize :has_math_library?, true
	
	def self.has_alloca_h?
		return try_compile("Checking for alloca.h",
			:c, '#include <alloca.h>')
	end
	memoize :has_alloca_h?, true
	
	# C compiler flags that should be passed in order to enable debugging information.
	def self.debugging_cflags
		# According to OpenBSD's pthreads man page, pthreads do not work
		# correctly when an app is compiled with -g. It recommends using
		# -ggdb instead.
		#
		# In any case we'll always want to use -ggdb for better GDB debugging.
		if cc_is_gcc?
			return '-ggdb'
		else
			return '-g'
		end
	end

	def self.dmalloc_ldflags
		if !ENV['DMALLOC_LIBS'].to_s.empty?
			return ENV['DMALLOC_LIBS']
		end
		if os_name == "macosx"
			['/opt/local', '/usr/local', '/usr'].each do |prefix|
				filename = "#{prefix}/lib/libdmallocthcxx.a"
				if File.exist?(filename)
					return filename
				end
			end
			return nil
		else
			return "-ldmallocthcxx"
		end
	end
	memoize :dmalloc_ldflags

	def self.electric_fence_ldflags
		if os_name == "macosx"
			['/opt/local', '/usr/local', '/usr'].each do |prefix|
				filename = "#{prefix}/lib/libefence.a"
				if File.exist?(filename)
					return filename
				end
			end
			return nil
		else
			return "-lefence"
		end
	end
	memoize :electric_fence_ldflags
	
	def self.export_dynamic_flags
		if os_name == "linux"
			return '-rdynamic'
		else
			return nil
		end
	end


	def self.make
		return string_env('MAKE', find_command('make'))
	end
	memoize :make, true

	def self.gnu_make
		if result = string_env('GMAKE')
			return result
		else
			result = find_command('gmake')
			if !result
				result = find_command('make')
				if result
					if `#{result} --version 2>&1` =~ /GNU/
						return result
					else
						return nil
					end
				else
					return nil
				end
			else
				return result
			end
		end
	end
	memoize :gnu_make, true
end

end # module PhusionPassenger
