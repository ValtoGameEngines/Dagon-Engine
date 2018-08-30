﻿/*
Copyright (c) 2018 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dagon.graphics.shader;

import std.stdio;
import dlib.core.ownership;
import dlib.core.memory;
import dlib.container.array;
import dlib.container.dict;
import dlib.math.vector;
import dlib.image.color;

// TODO: move to separate module
class MappedList(T): Owner
{
    DynamicArray!T data;
    Dict!(size_t, string) indices;
    
    this(Owner o)
    {
        super(o);
        indices = New!(Dict!(size_t, string))();
    }
    
    void set(string name, T val)
    {
        data.append(val);
        indices[name] = data.length - 1;
    }
    
    T get(string name)
    {
        return data[indices[name]];
    }
    
    ~this()
    {
        data.free();
        Delete(indices);
    }
}

/*
 * A shader class that wraps OpenGL shader creation and uniform initialization.
 * Currently in WIP status.
 */

abstract class BaseShaderParameter: Owner
{    
    Shader shader;
    string name;
    //TODO: uniform
    
    this(Shader shader, string name)
    {
        super(shader);
        this.shader = shader;
        this.name = name;
    }
    
    final void initUniform()
    {
        //TODO
    }
    
    void bind();    
    void unbind();
}

class ShaderParameter(T): BaseShaderParameter
if (is(T == bool) || 
    is(T == int) ||
    is(T == float) ||
    is(T == Vector2f) ||
    is(T == Vector3f) ||
    is(T == Vector4f) ||
    is(T == Color4f))
{
    T* source;
    T value;
    
    this(Shader shader, string name, T* source)
    {
        super(shader, name);
        this.source = source;
        initUniform();
    }
    
    this(Shader shader, string name, T value)
    {
        super(shader, name);
        this.source = null;
        this.value = value;
        initUniform();
    }
    
    override void bind()
    {
        if (source)
            value = *source;
        
        writefln("%s: %s", name, value);

        static if (is(T == bool) || is(T == int)) 
        {
			//TODO
        }
        else static if (is(T == float))
        {
			//TODO
        }
        else static if (is(T == Vector2f))
        {
			//TODO
        }
        else static if (is(T == Vector3f))
        {
			//TODO
        } 
        else static if (is(T == Vector4f))
        {
			//TODO
        }
        else static if (is(T == Color4f))
        {
			//TODO
        } 
    }
    
    override void unbind()
    {
		//TODO
    }
}

class Shader: Owner
{
    MappedList!BaseShaderParameter parameters;
    
    this(Owner o)
    {
        super(o);
        parameters = New!(MappedList!BaseShaderParameter)(this);
    }
    
    ShaderParameter!T setParameter(T)(string name, T val)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return null;
            }
            
            sp.value = val;
            sp.source = null;
            return sp;
        }
        else
        {
            auto sp = New!(ShaderParameter!T)(this, name, val);
            parameters.set(name, sp);
            return sp;
        }
    }
    
    ShaderParameter!T setParameterRef(T)(string name, ref T val)
    {
        if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return null;
            }
            
            sp.source = &val;
            return sp;
        }
        else
        {
            auto sp = New!(ShaderParameter!T)(this, name, &val);
            parameters.set(name, sp);
            return sp;
        }
    }
	
	T getParameter(T)(string name)
	{
		if (name in parameters.indices)
        {
            auto sp = cast(ShaderParameter!T)parameters.get(name);
            if (sp is null)
            {
                writefln("Warning: type mismatch for shader parameter \"%s\"", name);
                return T.init;
            }
            
			if (sp.source)
				return *sp.source;
			else
				return sp.value;
        }
		else
		{
			writefln("Warning: unknown shader parameter \"%s\"", name);
			return T.init;
		}
	}
    
    void bindParams()
    {
        foreach(v; parameters.data)
        {
            v.bind();
        }
    }
    
    ~this()
    {
    }
}

unittest
{
	class TestClass
	{
		Color4f col = Color4f(1,0,0,1);
	}
    auto c = New!TestClass();
	
	Shader s = New!Shader(null);
    bool test = true;
    s.setParameter("num", 0.5f);
    s.setParameterRef("test", test);
    s.setParameter("test2", Vector3f(1, 0, 0));
    s.setParameterRef("color", c.col);
    c.col.b = 1;
	
    s.bindParams();
	assert(s.getParameter!float("num") == 0.5f);
	assert(s.getParameter!bool("test") == true);
	assert(s.getParameter!bool("test2") == Vector3f(1, 0, 0));
	assert(s.getParameter!bool("color") == Color4f(1,0,1,1));
	
	Delete(s);
	Delete(c);
}
