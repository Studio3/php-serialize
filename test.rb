#!/usr/local/bin/ruby

require 'test/unit'

$:.unshift "lib"
require 'php_serialize'

TestStruct = Struct.new(:name, :value)
class TestClass
	attr_accessor :name
	attr_accessor :value

	def initialize(name = nil, value = nil)
		@name = name
		@value = value
	end

	def to_assoc
		[['name', @name], ['value', @value]]
	end

	def ==(other)
		other.class == self.class and other.name == @name and other.value == @value
	end
end

# Stands in for a class in the app's bundle with a side-effecting constructor
# and setter.  A payload must not be able to reach it by name.
class Gadget
	def self.log
		@log ||= []
	end

	def initialize
		Gadget.log << :constructed
	end

	def payload=(value)
		Gadget.log << [:payload, value]
	end

	private

	def secret=(value)
		Gadget.log << [:secret, value]
	end
end

ClassMap = {
	TestStruct.name.capitalize.intern => TestStruct,
	TestClass.name.capitalize.intern => TestClass
}

class TestPhpSerialize < Test::Unit::TestCase
	def self.test(ruby, php, opts = {})
		if opts[:name]
			name = opts[:name]
		else
			name = ruby.to_s
		end

		define_method("test_#{name}".intern) do
			assert_nothing_thrown do
				serialized = PHP.serialize(ruby)
				assert_equal php, serialized

				unserialized = PHP.unserialize(serialized, ClassMap)
				case ruby
				when Symbol
					assert_equal ruby.to_s, unserialized
				else
					assert_equal ruby, unserialized
				end
			end
		end
	end

	test nil, 'N;'
	test false, 'b:0;'
	test true, 'b:1;'
	test 42, 'i:42;'
	test -42, 'i:-42;'
	test 2147483647, "i:2147483647;", :name => 'Max Fixnum'
	test -2147483648, "i:-2147483648;", :name => 'Min Fixnum'
	test 4.2, 'd:4.2;'
	test 'test', 's:4:"test";'
	test :test, 's:4:"test";', :name => 'Symbol'
	test "\"\n\t\"", "s:4:\"\"\n\t\"\";", :name => 'Complex string'
	test [nil, true, false, 42, 4.2, 'test'], 'a:6:{i:0;N;i:1;b:1;i:2;b:0;i:3;i:42;i:4;d:4.2;i:5;s:4:"test";}',
		:name => 'Array'
	test({'foo' => 'bar', 4 => [5,4,3,2]}, 'a:2:{s:3:"foo";s:3:"bar";i:4;a:4:{i:0;i:5;i:1;i:4;i:2;i:3;i:3;i:2;}}', :name => 'Hash')
	test TestStruct.new("Foo", 65), 'O:10:"teststruct":2:{s:4:"name";s:3:"Foo";s:5:"value";i:65;}',
		:name => 'Struct'
	test TestClass.new("Foo", 65), 'O:9:"testclass":2:{s:4:"name";s:3:"Foo";s:5:"value";i:65;}',
		:name => 'Class'

	# Verify assoc is passed down calls.
	# Slightly awkward because hashes don't guarantee order.
	def test_assoc
		assert_nothing_raised do
			ruby = {'foo' => ['bar','baz'], 'hash' => {'hash' => 'smoke'}}
			ruby_assoc = [['foo', ['bar','baz']], ['hash', [['hash','smoke']]]]
			phps = [
				'a:2:{s:4:"hash";a:1:{s:4:"hash";s:5:"smoke";}s:3:"foo";a:2:{i:0;s:3:"bar";i:1;s:3:"baz";}}',
				'a:2:{s:3:"foo";a:2:{i:0;s:3:"bar";i:1;s:3:"baz";}s:4:"hash";a:1:{s:4:"hash";s:5:"smoke";}}'
			]
			serialized = PHP.serialize(ruby, true)
			assert phps.include?(serialized)
			unserialized = PHP.unserialize(serialized, true)
			assert_equal ruby_assoc.sort, unserialized.sort
		end
	end

	def test_sessions
		assert_nothing_raised do
			ruby = {'session_id' => 42, 'user_data' => {'uid' => 666}}
			phps = [
				'session_id|i:42;user_data|a:1:{s:3:"uid";i:666;}',
				'user_data|a:1:{s:3:"uid";i:666;}session_id|i:42;'
			]
			unserialized = PHP.unserialize(phps.first)
			assert_equal ruby, unserialized
			serialized = PHP.serialize_session(ruby)
			assert phps.include?(serialized)
		end
	end
end

# Guards against the unsafe object-instantiation primitive in 'O:' records:
# a serialized payload must never be able to pick which Ruby class gets
# instantiated, nor which method gets called on it.
class TestPhpSerializeSecurity < Test::Unit::TestCase
	def setup
		Gadget.log.clear
	end

	# 'O:6:"gadget":1:{s:7:"payload";s:5:"pwned";}'
	GADGET_PAYLOAD = 'O:6:"gadget":1:{s:7:"payload";s:5:"pwned";}'

	def test_object_record_does_not_reach_a_toplevel_constant
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize(GADGET_PAYLOAD)
		end
		assert_equal [], Gadget.log, 'payload instantiated a constant it was not given'
	end

	# Struct.const_defined? follows Object's constants, so it reached anything too.
	def test_object_record_does_not_reach_a_constant_via_struct
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize('O:4:"file":1:{s:4:"path";s:9:"/etc/pwnd";}')
		end
	end

	def test_unknown_class_can_be_unserialized_as_plain_data
		val = PHP.unserialize(GADGET_PAYLOAD, :on_object => :data)
		assert_equal 'pwned', val['payload']
		assert_equal [], Gadget.log
	end

	def test_classmap_entries_are_still_instantiated
		val = PHP.unserialize(GADGET_PAYLOAD, {:Gadget => Gadget})
		assert_equal Gadget, val.class
		assert_equal [:constructed, [:payload, 'pwned']], Gadget.log
	end

	# Legacy behaviour, now reachable only when the caller asks for it by name.
	def test_constant_lookup_is_available_as_an_explicit_opt_in
		val = PHP.unserialize(GADGET_PAYLOAD, :on_object => :constants)
		assert_equal Gadget, val.class
		assert_equal [:constructed, [:payload, 'pwned']], Gadget.log
	end

	def test_struct_fallback_does_not_define_a_constant
		PHP.unserialize('O:11:"pollutedref":0:{}', :on_object => :data)
		assert !Struct.const_defined?(:Pollutedref, false),
			'unserializing leaked a constant into the Struct namespace'
	end

	def test_setter_must_be_a_public_writer_on_the_target
		payload = 'O:6:"gadget":1:{s:6:"secret";s:4:"nope";}'
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize(payload, {:Gadget => Gadget})
		end
		assert_equal [:constructed], Gadget.log
	end

	def test_mangled_private_property_names_are_rejected
		payload = "O:6:\"gadget\":1:{s:15:\"\0Gadget\0payload\";s:1:\"x\";}"
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize(payload, {:Gadget => Gadget})
		end
	end

	def test_non_string_attribute_names_are_rejected
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize('O:6:"gadget":1:{i:0;s:1:"x";}',
				{:Gadget => Gadget})
		end
	end

	# Data-only entry point: the recommended call for untrusted input.
	def test_unserialize_data_rejects_object_records
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize_data(GADGET_PAYLOAD)
		end
		assert_equal [], Gadget.log
	end

	def test_unserialize_data_rejects_nested_object_records
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize_data("a:1:{s:3:\"key\";#{GADGET_PAYLOAD}}")
		end
		assert_equal [], Gadget.log
	end

	def test_unserialize_data_parses_plain_data
		assert_equal({'foo' => 'bar', 'n' => [1, 2.5, nil, true]},
			PHP.unserialize_data('a:2:{s:3:"foo";s:3:"bar";s:1:"n";a:4:{i:0;i:1;i:1;d:2.5;i:2;N;i:3;b:1;}}'))
	end

	def test_truncated_input_raises_unserialize_error
		['s:4:"tes', 'a:2:{i:0;i:1;', 'i:42', '', 'O:6:"gadget"'].each do |bad|
			assert_raise(PHP::UnserializeError, "expected #{bad.inspect} to be rejected") do
				PHP.unserialize_data(bad)
			end
		end
	end

	# SystemStackError is not a StandardError, so it escapes the caller's
	# rescue; nesting has to be bounded here instead.
	def test_deeply_nested_input_raises_unserialize_error
		deep = 'a:1:{i:0;' * 100_000 + 'N;' + '}' * 100_000
		assert_raise(PHP::UnserializeError) { PHP.unserialize_data(deep) }
	end

	def test_nesting_limit_is_configurable
		nested = 'a:1:{i:0;' * 4 + 'N;' + '}' * 4
		assert_equal [[[[nil]]]], PHP.unserialize_data(nested)
		assert_raise(PHP::UnserializeError) do
			PHP.unserialize(nested, :max_depth => 3)
		end
	end

	def test_unknown_type_raises_unserialize_error
		assert_raise(PHP::UnserializeError) { PHP.unserialize_data('X:1:{}') }
	end

	def test_declared_string_length_must_match
		assert_raise(PHP::UnserializeError) { PHP.unserialize_data('s:400:"short";') }
	end
end

# PHP counts 's:' lengths in bytes.  Strict parsing must not turn existing
# multibyte content into an error or a binary string.
class TestPhpSerializeEncoding < Test::Unit::TestCase
	MULTIBYTE = 'héllo wörld'

	def test_serialize_declares_the_byte_length
		assert_equal "s:#{MULTIBYTE.bytesize}:\"#{MULTIBYTE}\";", PHP.serialize(MULTIBYTE)
	end

	def test_multibyte_strings_round_trip
		out = PHP.unserialize_data(PHP.serialize(MULTIBYTE))
		assert_equal MULTIBYTE, out
		assert_equal MULTIBYTE.encoding, out.encoding
	end

	# Releases before 1.2.0 emitted the character count, so rows written by
	# them are still out there.
	def test_legacy_character_length_strings_are_readable
		legacy = "s:#{MULTIBYTE.length}:\"#{MULTIBYTE}\";"
		assert_equal MULTIBYTE, PHP.unserialize_data(legacy)
	end

	def test_legacy_character_length_in_nested_structures
		legacy = 'a:2:{s:3:"ké";s:2:"vé";i:1;s:1:"é";}'
		assert_equal({'ké' => 'vé', 1 => 'é'}, PHP.unserialize_data(legacy))
	end

	def test_a_string_containing_the_terminator_is_not_truncated
		tricky = 'a";b'
		assert_equal tricky, PHP.unserialize_data(PHP.serialize(tricky))
	end

	def test_length_that_matches_nothing_is_still_rejected
		assert_raise(PHP::UnserializeError) { PHP.unserialize_data('s:9:"short";') }
	end
end

require 'test/unit/ui/console/testrunner'
ok = Test::Unit::UI::Console::TestRunner.run(TestPhpSerialize).passed?
ok &= Test::Unit::UI::Console::TestRunner.run(TestPhpSerializeSecurity).passed?
ok &= Test::Unit::UI::Console::TestRunner.run(TestPhpSerializeEncoding).passed?
exit(ok ? 0 : 1)

