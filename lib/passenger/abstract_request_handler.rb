#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'socket'
require 'base64'
require 'passenger/native_support'
module Passenger

# The request handler is the layer which connects Apache with the underlying application's
# request dispatcher (i.e. either Rails's Dispatcher class or Rack).
# The request handler's job is to process incoming HTTP requests using the
# currently loaded Ruby on Rails application. HTTP requests are forwarded
# to the request handler by the web server. HTTP responses generated by the
# RoR application are forwarded to the web server, which, in turn, sends the
# response back to the HTTP client.
#
# AbstractRequestHandler is an abstract base class for easing the implementation
# of request handlers for Rails and Rack.
#
# == Design decisions
#
# Some design decisions are made because we want to decrease system
# administrator maintenance overhead. These decisions are documented
# in this section.
#
# === Abstract namespace Unix sockets
#
# AbstractRequestHandler listens on a Unix socket for incoming requests. If possible,
# AbstractRequestHandler will try to create a Unix socket on the _abstract namespace_,
# instead of on the filesystem. If the RoR application crashes (segfault),
# or if it gets killed by SIGKILL, or if the system loses power, then there
# will be no stale socket files left on the filesystem.
# Unfortunately, abstract namespace Unix sockets are only supported by Linux.
# On systems that do not support abstract namespace Unix sockets,
# AbstractRequestHandler will automatically fallback to using regular Unix socket files.
#
# It is possible to force AbstractRequestHandler to use regular Unix socket files by
# setting the environment variable PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS
# to 1.
#
# === Owner pipes
#
# Because only the web server communicates directly with a request handler,
# we want the request handler to exit if the web server has also exited.
# This is implemented by using a so-called _owner pipe_. The writable part
# of the pipe will be owned by the web server. AbstractRequestHandler will
# continuously check whether the other side of the pipe has been closed. If
# so, then it knows that the web server has exited, and so the request handler
# will exit as well. This works even if the web server gets killed by SIGKILL.
#
#
# == Request format
#
# Incoming "HTTP requests" are not true HTTP requests, i.e. their binary
# representation do not conform to RFC 2616. Instead, the request format
# is based on CGI, and is similar to that of SCGI.
#
# The format consists of 3 parts:
# - A 32-bit big-endian integer, containing the size of the transformed
#   headers.
# - The transformed HTTP headers.
# - The verbatim (untransformed) HTTP request body.
#
# HTTP headers are transformed to a format that satisfies the following
# grammar:
#
#  headers ::= header*
#  header ::= name NUL value NUL
#  name ::= notnull+
#  value ::= notnull+
#  notnull ::= "\x01" | "\x02" | "\x02" | ... | "\xFF"
#  NUL = "\x00"
#
# The web server transforms the HTTP request to the aforementioned format,
# and sends it to the request handler.
class AbstractRequestHandler
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE = 50
	MAX_HEADER_SIZE = 128 * 1024
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE              = 'IGNORE'              # :nodoc:
	DEFAULT             = 'DEFAULT'             # :nodoc:
	CONTENT_LENGTH      = 'CONTENT_LENGTH'      # :nodoc:
	HTTP_CONTENT_LENGTH = 'HTTP_CONTENT_LENGTH' # :nodoc:
	X_POWERED_BY        = 'X-Powered-By'        # :nodoc:
	
	# The name of the socket on which the request handler accepts
	# new connections. This is either a Unix socket filename, or
	# the name for an abstract namespace Unix socket.
	#
	# If +socket_name+ refers to an abstract namespace Unix socket,
	# then the name does _not_ contain a leading null byte.
	#
	# See also using_abstract_namespace?
	attr_reader :socket_name

	# Create a new RequestHandler with the given owner pipe.
	# +owner_pipe+ must be the readable part of a pipe IO object.
	def initialize(owner_pipe)
		if abstract_namespace_sockets_allowed?
			@using_abstract_namespace = create_unix_socket_on_abstract_namespace
		else
			@using_abstract_namespace = false
		end
		if !@using_abstract_namespace
			create_unix_socket_on_filesystem
		end
		@owner_pipe = owner_pipe
		@previous_signal_handlers = {}
	end
	
	# Clean up temporary stuff created by the request handler.
	# This method should be called after the main loop has exited.
	def cleanup
		@socket.close rescue nil
		@owner_pipe.close rescue nil
		if !using_abstract_namespace?
			File.unlink(@socket_name) rescue nil
		end
	end
	
	# Returns whether socket_name refers to an abstract namespace Unix socket.
	def using_abstract_namespace?
		return @using_abstract_namespace
	end
	
	# Enter the request handler's main loop.
	def main_loop
		reset_signal_handlers
		begin
			done = false
			while !done
				client = accept_connection
				if client.nil?
					break
				end
				trap SOFT_TERMINATION_SIGNAL do
					done = true
				end
				begin
					headers, input = parse_request(client)
					if headers
						process_request(headers, input, client)
					end
				rescue IOError, SocketError, SystemCallError => e
					print_exception("Passenger RequestHandler", e)
				ensure
					client.close rescue nil
				end
				trap SOFT_TERMINATION_SIGNAL, DEFAULT
			end
		rescue EOFError
			# Exit main loop.
		rescue Interrupt
			# Exit main loop.
		rescue SignalException => signal
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		ensure
			revert_signal_handlers
		end
	end

private
	include Utils

	def create_unix_socket_on_abstract_namespace
		while true
			begin
				# I have no idea why, but using base64-encoded IDs
				# don't pass the unit tests. I couldn't find the cause
				# of the problem. The system supports base64-encoded
				# names for abstract namespace unix sockets just fine.
				@socket_name = generate_random_id(:hex)
				@socket_name = @socket_name.slice(0, NativeSupport::UNIX_PATH_MAX - 2)
				fd = NativeSupport.create_unix_socket("\x00#{socket_name}", BACKLOG_SIZE)
				@socket = IO.new(fd)
				@socket.instance_eval do
					def accept
						fd = NativeSupport.accept(fileno)
						return IO.new(fd)
					end
				end
				return true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			rescue Errno::ENOENT
				# Abstract namespace sockets not supported on this system.
				return false
			end
		end
	end
	
	def create_unix_socket_on_filesystem
		done = false
		while !done
			begin
				@socket_name = "/tmp/passenger.#{generate_random_id(:base64)}"
				@socket_name = @socket_name.slice(0, NativeSupport::UNIX_PATH_MAX - 1)
				@socket = UNIXServer.new(@socket_name)
				File.chmod(0600, @socket_name)
				done = true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			end
		end
	end

	def reset_signal_handlers
		Signal.list.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		prev_handler = trap('HUP', IGNORE)
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end
	
	def accept_connection
		ios = select([@socket, @owner_pipe])[0]
		if ios.include?(@socket)
			return @socket.accept
		else
			# The other end of the pipe has been closed.
			# So we know all owning processes have quit.
			return nil
		end
	end
	
	def parse_request(socket)
		channel = MessageChannel.new(socket)
		headers_data = channel.read_scalar(MAX_HEADER_SIZE)
		if headers_data.nil?
			return
		end
		headers = Hash[*headers_data.split("\0")]
		headers[CONTENT_LENGTH] = headers[HTTP_CONTENT_LENGTH]
		headers_data = nil
		return [headers, socket]
	rescue SecurityError => e
		STDERR.puts("*** Passenger RequestHandler: HTTP header size exceeded maximum.")
		STDERR.flush
		print_exception("Passenger RequestHandler", e)
	end
	
	# Generate a long, cryptographically secure random ID string, which
	# is also a valid filename.
	def generate_random_id(method)
		case method
		when :base64
			data = Base64.encode64(File.read("/dev/urandom", 64))
			data.gsub!("\n", '')
			data.gsub!("+", '')
			data.gsub!("/", '')
			data.gsub!(/==$/, '')
		when :hex
			data = File.read("/dev/urandom", 64).unpack('H*')[0]
		end
		return data
	end
	
	def abstract_namespace_sockets_allowed?
		return !ENV['PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS'] ||
			ENV['PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS'].empty?
	end

	def self.determine_passenger_version
		rakefile = "#{File.dirname(__FILE__)}/../../Rakefile"
		if File.exist?(rakefile)
			File.read(rakefile) =~ /^PACKAGE_VERSION = "(.*)"$/
			return $1
		else
			return File.read("/etc/passenger_version.txt")
		end
	end
	
	def self.determine_passenger_header
		header = "Phusion Passenger (mod_rails) #{PASSENGER_VERSION}"
		if File.exist?("#{File.dirname(__FILE__)}/../../enterprisey.txt") ||
		   File.exist?("/etc/passenger_enterprisey.txt")
			header << ", Enterprise Edition"
		end
		return header
	end

public
	PASSENGER_VERSION = determine_passenger_version
	PASSENGER_HEADER = determine_passenger_header
end

end # module Passenger
