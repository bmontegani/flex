# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See the LICENSE.txt file in the project root
# for the license information.

# This script:
# * generates the `base.cs' file from the native header file.
# * has to be ran every time the header file changes.
# * needs to be ran on a Mac, therefore it's okay to check the generated file
#   into source control so that people on Windows can use the code.

FLEX_PATH = '../..'
DLL_NAME = 'flex'
OUTPUT_FILE = 'base.cs'
FORCE_ENUM_PROPERTIES = {
  'justify_content' => 'Align',
  'align_content' => 'Align',
  'align_items' => 'Align',
  'align_self' => 'Align'
}

class Generator
  def run
    gen_flex_bs
    parse_flex_bs
    gen_base_cs
  end

  def gen_flex_bs
    flex_bs = '/tmp/flex.bs'
    Dir.chdir(FLEX_PATH) do
      die "can't generate bridgesupport file" unless system("/usr/bin/gen_bridge_metadata -c '-I.' -o \"#{flex_bs}\" flex.h")
    end
    @flex_bs = flex_bs
  end

  def parse_flex_bs
    require 'rexml/document'
    doc = REXML::Document.new(File.read(@flex_bs))
    root = doc.get_elements('signatures')[0]
    
    @enums = {}
    root.get_elements('enum').each do |elem|
      enum_name = elem.attributes['name']
      die "invalid enum #{elem.to_s}" unless md = enum_name.match(/^FLEX_([^_]+)_(.+)$/)
      group = csharp_name(md[1])
      name = csharp_name(md[2])
      value = elem.attributes['value'].to_i
      (@enums[group] ||= []) << [name, value]
    end

    @functions = []
    @delegates = {}
    root.get_elements('function').each do |elem|
      name = elem.attributes['name']
      @functions << [name, *convert_function_type(elem)]
    end
    @functions.sort { |x, y| x[0] <=> y[0] }
  end

  def gen_base_cs
    @io = File.open(OUTPUT_FILE, 'w')
    @indent = 0

    out <<EOS
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See the LICENSE.txt file in the project root
// for the license information.

// This file was generated by #{__FILE__}. Do not edit manually.

using System;
using System.Runtime.InteropServices;
using static Xamarin.Flex.NativeFunctions;

namespace Xamarin.Flex
{
EOS
    @indent += 1
    
    @enums.to_a.sort { |x, y| x[0] <=> y[0] }.each do |group, values|
      out "public enum #{group} : int"
      out '{'
      @indent += 1
      values.sort { |x, y| x[1] <=> y[1] }.each do |name, value|
        out "#{name} = #{value},"
      end
      @indent -= 1
      out '}'
      out ''
    end

    out 'internal class NativeFunctions'
    out '{'
    @indent += 1
    out 'const string dll_name = "flex";'
    out ''
    properties = {}
    @functions.sort { |x, y| x[0] <=> y[0] }.each do |name, retval, args|
      i = 0
      args_list = args.map { |x| x + " arg#{i += 1}" }.join(', ')
      func_line = "#{retval} #{name} (#{args_list})"
      out "[DllImport(dll_name)] public static extern #{func_line};"
    
      if md = name.match(/^flex_item_(g|s)et_(.+)$/)
        name = md[2]
        what = md[1] == 'g' ? :get : :set
        type = what == :get ? retval : args[1]
        if type == 'int'
          enum_type = (FORCE_ENUM_PROPERTIES[name] or name.capitalize)
          type = enum_type if @enums.has_key?(enum_type)
        end
        unless type.match(/^(IntPtr|Delegate)/) # ignore 'internal' properties
          (properties[name] ||= [type]) << what
        end
      end
    end
    out ''
    @delegates.each do |types, name|
      retval = types[0]
      i = 0
      args = types[1]
      args_list = args.map { |x| x + " arg#{i += 1}" }.join(', ')
      out "public delegate #{retval} #{name} (#{args_list});"
    end
    @indent -= 1
    out '}'
    out ''
    
    die "no properties?" if properties.empty?

    out 'enum Properties'
    out '{'
    @indent += 1
    properties.each do |name, prop|
      if prop[1..-1].include?(:set)
        out "#{csharp_name(name)},"
      end
    end
    @indent -= 1
    out '}'
    out ''
 
    out 'public partial class Item'
    out '{'
    @indent += 1
    first = true;
    properties.each do |name, prop|
      type = prop[0]
      is_enum = type.match(/^[A-Z]/) # good enough
    
      out '' unless first; first = false
      out "public #{type} #{csharp_name(name)}"
      out '{'
      @indent += 1
      prop[1..-1].each do |method|
        case method
          when :get
            cast = is_enum ? "(#{type})" : ''
            out "get { return #{cast}flex_item_get_#{name}(item); }"
          when :set
            cast = is_enum ? "(int)" : ''
            out 'set'
            out '{'
            @indent += 1
            out "ValidatePropertyValue(Properties.#{csharp_name(name)}, #{cast}value);"
            out "flex_item_set_#{name}(item, #{cast}value);"
            @indent -= 1
            out '}'
        end
      end
      @indent -= 1
      out '}'
    end
    out ''
    out 'partial void ValidatePropertyValue(Properties property, int value);'
    out 'partial void ValidatePropertyValue(Properties property, float value);'
    @indent -= 1
    out '}'
    @indent -= 1
    out '}'
    @io.close
  end

  def out(str)
    line = "#{' ' * (@indent * 4)}#{str}"
    line = '' if line.strip.empty?
    @io.puts line
  end

  def csharp_name(name)
    name.capitalize.gsub(/_(.)/) { |md| md[1].upcase }
  end

  def convert_function_type(elem)
    retval_elem = elem.get_elements('retval')
    retval = retval_elem.size == 1 ? convert_type(retval_elem[0]) : 'void'
    args = elem.get_elements('arg').map { |arg_elem| convert_type(arg_elem) }
    [retval, args]
  end
 
  def convert_type(elem)
    if elem.attributes['function_pointer'] == 'true'
      ftype = convert_function_type(elem)
      @delegates[ftype] ||= "Delegate#{@delegates.size}"
    else
      case type = elem.attributes['type']
        when 'I', 'i'
          'int'
        when 'v'
          'void'
        when 'f'
          'float'
        when /^\^/
          'IntPtr'
        else
          die "invalid type #{type}"
      end
    end
  end

  def die(*msg)
    $stderr.puts msg
    exit 1
  end
end

Generator.new.run
