#!/usr/bin/env ruby
# Copyright (c) 2003-2009 Thomas Hurst <tom@hur.st>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# PHP serialize() and unserialize() workalikes
#
# Release History:
#  1.0.0 - 2003-06-02 - First release.
#  1.0.1 - 2003-06-16 - Minor bugfixes.
#  1.0.2 - 2004-09-17 - Switch all {}'s to explicit Hash.new's.
#  1.1.0 - 2009-04-01 - Pass assoc to recursive calls (thanks to Edward Speyer).
#                     - Serialize Symbol like String.
#                     - Add testsuite.
#                     - Instantiate auto-generated Structs properly (thanks
#                       to Philip Hallstrom).
#                     - Unserialize arrays properly in assoc mode.
#                     - Add PHP session support (thanks to TJ Vanderpoel).
#                     - Release as tarball and gem.
#  1.2.0 -            - unserialize() no longer instantiates classes named by
#                       the serialized data.  An 'O:' record is only built if
#                       its class is in classmap, or the caller passes
#                       :on_object => :constants for the old behaviour.
#                     - Add unserialize_data(), which rejects 'O:' records
#                       outright; use it for untrusted input.
#                     - Only public attribute writers are called, and only for
#                       plain identifier attribute names.
#                     - Malformed/truncated input raises UnserializeError
#                       instead of returning partial data or crashing with
#                       NoMethodError.
#                     - Nesting is bounded (:max_depth), so a deeply nested
#                       payload raises UnserializeError rather than
#                       SystemStackError.
#                     - serialize() declares string lengths in bytes, like
#                       PHP.  unserialize() reads byte lengths, still accepts
#                       the character lengths older releases wrote, and
#                       returns strings in the encoding of the input rather
#                       than as binary.
#
# See http://www.php.net/serialize and http://www.php.net/unserialize for
# details on the PHP side of all this.
require 'stringio'

module PHP
	# Raised for any malformed or disallowed serialized input.  Subclasses
	# TypeError, which earlier releases raised for unknown types, so existing
	# rescue clauses keep working.
	class UnserializeError < TypeError; end

	# What to do with an 'O:' object record whose class is not in the classmap.
	#
	#   :strict    - raise UnserializeError (default; safe for untrusted input)
	#   :data      - return the attributes as plain data, instantiating nothing
	#   :constants - resolve the name against the constant namespace and call
	#                .new on it.  This is the pre-1.2 behaviour and lets the
	#                payload choose which class is built; only use it on input
	#                you produced yourself.
	OBJECT_MODES = [:strict, :data, :constants].freeze

	# PHP property names we are willing to turn into a setter call.  Excludes
	# PHP's "\0Class\0prop" private/protected mangling and anything that is not
	# a plain identifier.
	ATTRIBUTE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

	# How deeply arrays and objects may nest.  Parsing is recursive, and
	# SystemStackError is not a StandardError, so an unbounded payload would
	# blow past the caller's rescue; overrunning this raises UnserializeError
	# instead.  Override per call with :max_depth.
	MAX_DEPTH = 512

	# Per-call parse options, threaded through the recursive descent.
	Options = Struct.new(:classmap, :assoc, :on_object, :max_depth)
	private_constant :Options
# string = PHP.serialize(mixed var[, bool assoc])
#
# Returns a string representing the argument in a form PHP.unserialize
# and PHP's unserialize() should both be able to load.
#
# Array, Hash, Fixnum, Float, True/FalseClass, NilClass, String and Struct
# are supported; as are objects which support the to_assoc method, which
# returns an array of the form [['attr_name', 'value']..].  Anything else
# will raise a TypeError.
#
# If 'assoc' is specified, Array's who's first element is a two value
# array will be assumed to be an associative array, and will be serialized
# as a PHP associative array rather than a multidimensional array.
	def PHP.serialize(var, assoc = false) # {{{
		s = String.new
		case var
			when Array
				s << "a:#{var.size}:{"
				if assoc and var.first.is_a?(Array) and var.first.size == 2
					var.each { |k,v|
						s << PHP.serialize(k, assoc) << PHP.serialize(v, assoc)
					}
				else
					var.each_with_index { |v,i|
						s << "i:#{i};#{PHP.serialize(v, assoc)}"
					}
				end

				s << '}'

			when Hash
				s << "a:#{var.size}:{"
				var.each do |k,v|
					s << "#{PHP.serialize(k, assoc)}#{PHP.serialize(v, assoc)}"
				end
				s << '}'

			when Struct
				# encode as Object with same name
				s << "O:#{var.class.to_s.length}:\"#{var.class.to_s.downcase}\":#{var.members.length}:{"
				var.members.each do |member|
					s << "#{PHP.serialize(member, assoc)}#{PHP.serialize(var[member], assoc)}"
				end
				s << '}'

			when String, Symbol
				# PHP counts the length in bytes, not characters.
				s << "s:#{var.to_s.bytesize}:\"#{var.to_s}\";"

			when Integer # PHP doesn't have bignums
				s << "i:#{var};"

			when Float
				s << "d:#{var};"

			when NilClass
				s << 'N;'

			when FalseClass, TrueClass
				s << "b:#{var ? 1 :0};"

			else
				if var.respond_to?(:to_assoc)
					v = var.to_assoc
					# encode as Object with same name
					s << "O:#{var.class.to_s.length}:\"#{var.class.to_s.downcase}\":#{v.length}:{"
					v.each do |k,v|
						s << "#{PHP.serialize(k.to_s, assoc)}#{PHP.serialize(v, assoc)}"
					end
					s << '}'
				else
					raise TypeError, "Unable to serialize type #{var.class}"
				end
		end

		s
	end # }}}

# string = PHP.serialize_session(mixed var[, bool assoc])
#
# Like PHP.serialize, but only accepts a Hash or associative Array as the root
# type.  The results are returned in PHP session format.
	def PHP.serialize_session(var, assoc = false) # {{{
		s = String.new
		case var
		when Hash
			var.each do |key,value|
				if key.to_s =~ /\|/
					raise IndexError, "Top level names may not contain pipes"
				end
				s << "#{key}|#{PHP.serialize(value, assoc)}"
			end
		when Array
			var.each do |x|
				case x
				when Array
					if x.size == 2
						s << "#{x[0]}|#{PHP.serialize(x[1])}"
					else
						raise TypeError, "Array is not associative"
					end
				end
			end
		else
			raise TypeError, "Unable to serialize sessions with top level types other than Hash and associative Array"
		end
		s
	end # }}}

# mixed = PHP.unserialize_data(string serialized, [bool assoc])
#
# Like PHP.unserialize, but accepts data only: any 'O:' object record in the
# input, at any depth, raises UnserializeError instead of being turned into a
# Ruby object.  Nothing in the input can name a class or reach a method, so
# this is the call to use for values that came from a database, a cookie, a
# request parameter, or anywhere else outside your own process.
	def PHP.unserialize_data(string, assoc = false, max_depth: MAX_DEPTH) # {{{
		PHP.unserialize(string, nil, assoc, :on_object => :strict, :max_depth => max_depth)
	end # }}}

# mixed = PHP.unserialize(string serialized, [hash classmap, [bool assoc]])
#
# Returns an object containing the reconstituted data from serialized.
#
# If a PHP array (associative; like an ordered hash) is encountered, it
# scans the keys; if they're all incrementing integers counting from 0,
# it's unserialized as an Array, otherwise it's unserialized as a Hash.
# Note: this will lose ordering.  To avoid this, specify assoc=true,
# and it will be unserialized as an associative array: [[key,value],...]
#
# If a serialized object is encountered, the hash 'classmap' is searched for
# the class name (as a symbol).  Since PHP classnames are not case-preserving,
# this *must* be a .capitalize()d representation.  The value is expected
# to be the class itself; i.e. something you could call .new on.
#
# If the class is not in 'classmap', the :on_object option decides what
# happens (see OBJECT_MODES).  The default, :strict, raises UnserializeError:
# serialized input is not allowed to pick which class gets instantiated,
# because both the constructor and the attribute setters can have side
# effects, and those happen before the caller ever sees the return value.
# Pass :on_object => :data to get the attributes back as a plain Hash (or,
# with assoc, an array of pairs), or :on_object => :constants to restore the
# pre-1.2 constant lookup for input you trust.
#
# Each serialized attribute is assigned with the respective {attribute}=()
# method.  The name must be a plain identifier and the method must be a public
# writer on the target, or UnserializeError is raised; PHP's mangled private
# property names are always rejected.
#
# Array, Hash, Integer, Float, True/FalseClass, NilClass and String should
# be returned identically (i.e. foo == PHP.unserialize(PHP.serialize(foo))
# for these types); Struct should be too, provided you passed it in classmap.
	def PHP.unserialize(string, classmap = nil, assoc = false,
			on_object: :strict, max_depth: MAX_DEPTH) # {{{
		if classmap == true or classmap == false
			assoc = classmap
			classmap = {}
		end
		classmap ||= {}

		unless OBJECT_MODES.include?(on_object)
			raise ArgumentError, ":on_object must be one of #{OBJECT_MODES.inspect}"
		end
		raise ArgumentError, ':max_depth must be positive' unless max_depth > 0

		opts = Options.new(classmap, assoc, on_object, max_depth)
		string = StringIO.new(string)

		if string.string =~ /\A(\w+)\|/ # session_name|serialized_data
			ret = Hash.new
			loop do
				if string.string[string.pos, 32] =~ /\A(\w+)\|/
					string.pos += $&.size
					ret[$1] = PHP.do_unserialize(string, opts, 0)
				else
					break
				end
			end
			ret
		else
			PHP.do_unserialize(string, opts, 0)
		end
	end # }}}

private
	# Reads until 'char', which is consumed.  Raises rather than returning a
	# truncated value, so a chopped-off payload can't be parsed as something
	# else.
	def PHP.read_until(string, char) # {{{
		val = String.new
		while (c = string.read(1)) != char
			raise UnserializeError, "Unexpected end of serialized data" if c.nil?
			val << c
		end
		val
	end # }}}

	def PHP.read_exactly(string, length) # {{{
		raise UnserializeError, "Negative length in serialized data" if length < 0
		val = string.read(length)
		if val.nil? ? length > 0 : val.bytesize < length
			raise UnserializeError, "Unexpected end of serialized data"
		end
		val
	end # }}}

	def PHP.read_integer(string, terminator) # {{{
		val = read_until(string, terminator)
		unless val =~ /\A-?\d+\z/
			raise UnserializeError, "Expected an integer, got #{val.inspect}"
		end
		val.to_i
	end # }}}

	# Returns the next 'length' bytes without consuming them.
	def PHP.peek(string, length) # {{{
		pos = string.pos
		val = string.read(length)
		string.pos = pos
		val
	end # }}}

	# Reads the s:length:"data"; body, verifying the declared length and the
	# closing quote and semicolon.  Values come back in the encoding of the
	# serialized string rather than as binary.
	def PHP.read_string(string) # {{{
		length = read_integer(string, ':')
		quote = read_exactly(string, 1)
		raise UnserializeError, 'Expected an opening quote' unless quote == '"'
		encoding = string.string.encoding

		val = read_exactly(string, length)
		if peek(string, 2) == '";'
			read_exactly(string, 2)
			return val.force_encoding(encoding)
		end

		# PHP declares the length in bytes.  Releases of this library before
		# 1.2.0 declared it in characters, so multibyte values they wrote are
		# short by one byte per continuation byte.  Extend the value until the
		# terminator lines up and the character count matches what was
		# declared; anything else is malformed.
		val.force_encoding(Encoding::BINARY)
		limit = length * 3 # most extra bytes the characters could account for
		extra = 0
		while extra < limit
			c = string.read(1)
			raise UnserializeError, 'Unexpected end of serialized data' if c.nil?
			val << c
			extra += 1
			next unless peek(string, 2) == '";'
			candidate = val.dup.force_encoding(encoding)
			if candidate.valid_encoding? and candidate.length == length
				read_exactly(string, 2)
				return candidate
			end
		end
		raise UnserializeError, "String of declared length #{length} is not terminated"
	end # }}}

	def PHP.do_unserialize(string, opts, depth)
		if depth > opts.max_depth
			raise UnserializeError, "Serialized data nests deeper than #{opts.max_depth}"
		end

		val = nil
		# determine a type
		type = read_exactly(string, 1)
		unless type == 'N'
			separator = read_exactly(string, 1)
			raise UnserializeError, "Malformed '#{type}' record" unless separator == ':'
		end

		case type
			when 'a' # associative array, a:length:{[index][value]...}
				count = read_integer(string, ':')
				raise UnserializeError, 'Negative array length' if count < 0
				brace = read_exactly(string, 1)
				raise UnserializeError, 'Expected {' unless brace == '{'
				val = vals = Array.new
				count.times do |i|
					vals << [do_unserialize(string, opts, depth + 1),
						do_unserialize(string, opts, depth + 1)]
				end
				closing = read_exactly(string, 1) # the ending }
				raise UnserializeError, 'Expected }' unless closing == '}'

				# now, we have an associative array, let's clean it up a bit...
				# arrays have all numeric indexes, in order; otherwise we assume a hash
				array = true
				i = 0
				vals.each do |key,value|
					if key != i # wrong index -> assume hash
						array = false
						break
					end
					i += 1
				end

				if array
					vals.collect! do |key,value|
						value
					end
				else
					if opts.assoc
						val = vals.map {|v| v }
					else
						val = Hash.new
						vals.each do |key,value|
							val[key] = value
						end
					end
				end

			when 'O' # object, O:length:"class":length:{[attribute][value]...}
				val = do_unserialize_object(string, opts, depth)

			when 's' # string, s:length:"data";
				val = read_string(string)

			when 'i' # integer, i:123;
				val = read_integer(string, ';')

			when 'd' # double (float), d:1.23;
				val = read_until(string, ';')
				unless val =~ /\A-?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?\z/ or
						%w[NAN INF -INF].include?(val)
					raise UnserializeError, "Expected a float, got #{val.inspect}"
				end
				val = case val
					when 'NAN' then Float::NAN
					when 'INF' then Float::INFINITY
					when '-INF' then -Float::INFINITY
					else val.to_f
				end

			when 'N' # NULL, N;
				terminator = read_exactly(string, 1)
				raise UnserializeError, "Malformed 'N' record" unless terminator == ';'
				val = nil

			when 'b' # bool, b:0; or b:1;
				flag = read_until(string, ';')
				unless flag == '0' or flag == '1'
					raise UnserializeError, "Expected a boolean, got #{flag.inspect}"
				end
				val = flag == '1'

			else
				raise UnserializeError, "Unable to unserialize type '#{type}'"
		end

		val
	end

	# Handles the 'O:' record.  The class name comes from the input, so it is
	# only ever used as a lookup key -- never to build a Ruby object -- unless
	# the caller opted in via classmap or :on_object => :constants.
	def PHP.do_unserialize_object(string, opts, depth) # {{{
		# class name (lowercase in PHP, grr)
		name = read_string_body_of_class_name(string)
		klass = name.capitalize.intern

		# read the attributes
		count = read_integer(string, ':')
		raise UnserializeError, 'Negative attribute count' if count < 0
		brace = read_exactly(string, 1)
		raise UnserializeError, 'Expected {' unless brace == '{'

		attrs = []
		count.times do
			attr = do_unserialize(string, opts, depth + 1)
			attrs << [attr, do_unserialize(string, opts, depth + 1)]
		end
		closing = read_exactly(string, 1)
		raise UnserializeError, 'Expected }' unless closing == '}'

		target = resolve_object_class(klass, name, opts)

		if target.nil? # :data -- hand back the attributes, instantiate nothing
			return opts.assoc ? attrs : Hash[attrs]
		end

		val = target.new
		attrs.each do |attr,v|
			unless attr.is_a?(String) and attr =~ ATTRIBUTE_NAME
				raise UnserializeError,
					"Refusing to assign attribute #{attr.inspect} of #{name.inspect}"
			end
			writer = "#{attr}=".intern
			unless val.respond_to?(writer)
				raise UnserializeError,
					"#{target} has no public #{writer} to assign attribute #{attr.inspect}"
			end
			val.public_send(writer, v)
		end
		val
	end # }}}

	# The class name in an 'O:' record is length-prefixed like a string, but
	# terminated by ':' rather than ';'.
	def PHP.read_string_body_of_class_name(string) # {{{
		length = read_integer(string, ':')
		quote = read_exactly(string, 1)
		raise UnserializeError, 'Expected an opening quote' unless quote == '"'
		name = read_exactly(string, length)
		tail = read_exactly(string, 2)
		unless tail == '":'
			raise UnserializeError, "Class name of declared length #{length} is not terminated"
		end
		name.force_encoding(string.string.encoding)
	end # }}}

	# Returns the class to instantiate, or nil to mean "return plain data".
	def PHP.resolve_object_class(klass, name, opts) # {{{
		classmap = opts.classmap
		return classmap[klass] if classmap.has_key?(klass)

		case opts.on_object
		when :data
			nil
		when :constants
			begin
				classmap[klass] = Object.const_get(klass, false)
			rescue NameError
				raise UnserializeError, "Unable to resolve class #{name.inspect}"
			end
		else
			raise UnserializeError,
				"Refusing to instantiate class #{name.inspect} from serialized data; " \
				"add it to classmap to allow it, or pass :on_object => :data"
		end
	end # }}}
end

