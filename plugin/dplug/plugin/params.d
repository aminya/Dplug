/*
Cockos WDL License

Copyright (C) 2005 - 2015 Cockos Incorporated
Copyright (C) 2015 and later Auburn Sounds

Portions copyright other contributors, see each source file for more information

This software is provided 'as-is', without any express or implied warranty.  In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.
1. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
1. This notice may not be removed or altered from any source distribution.
*/
module dplug.plugin.params;

import std.math;

import core.stdc.stdio;

import dplug.plugin.client;
import dplug.plugin.unchecked_sync;

class Parameter
{
public:
    string name() pure const nothrow @nogc
    {
        return _name;
    }

    string label() pure const nothrow @nogc
    {
        return _label;
    }

    // From a normalized float, set the parameter value.
    void setFromHost(float hostValue) nothrow @nogc
    {
        setNormalized(hostValue);
        notifyListeners();
    }

    // Returns: A normalized float, represents the parameter value.
    float getForHost() nothrow @nogc
    {
        return getNormalized();
    }

    void toDisplayN(char* buffer, size_t numBytes) nothrow
    {
        toStringN(buffer, numBytes);
    }

    /// Adds a parameter listener.
    void addListener(IParameterListener listener)
    {
        _listeners ~= listener;
    }

    void removeListener(IParameterListener listener)
    {
        static auto removeElement(IParameterListener[] haystack, IParameterListener needle)
        {
            import std.algorithm;
            auto index = haystack.countUntil(needle);
            return (index != -1) ? haystack.remove(index) : haystack;
        }
        _listeners = removeElement(_listeners, listener);
    }

    void beginParamEdit()
    {
        _client.hostCommand().beginParamEdit(_index);
    }

    void endParamEdit()
    {
        _client.hostCommand().endParamEdit(_index);
    }

    /// Returns: A normalized float, representing the default parameter value.
    abstract float getNormalizedDefault() nothrow @nogc;

protected:

    this(Client client, int index, string name, string label)
    {
        _client = client;
        _name = name;
        _label = label;
        _index = index;

        _valueMutex = new UncheckedMutex();

    }

    ~this()
    {
        close();
    }

    void close()
    {
        _valueMutex.close();
    }

    /// From a normalized float, set the parameter value.
    /// No guarantee at all that getNormalized will return the same,
    /// because this value is rounded to fit.
    abstract void setNormalized(float hostValue) nothrow @nogc;

    /// Returns: A normalized float, representing the parameter value.
    abstract float getNormalized() nothrow @nogc;

    /// Display parameter (without label).
    abstract void toStringN(char* buffer, size_t numBytes) nothrow;

    void notifyListeners() nothrow @nogc
    {
        foreach(listener; _listeners)
            listener.onParameterChanged(this);
    }

private:
    Client _client; /// backlink to parameter holder
    int _index;
    string _name;
    string _label;
    IParameterListener[] _listeners;

    UncheckedMutex _valueMutex;
}

/// Parameter listeners are called whenever a parameter is changed from the host POV.
/// Intended making GUI controls call `setDirty()` and move with automation.
interface IParameterListener
{
    void onParameterChanged(Parameter sender) nothrow @nogc;
}


/// A boolean parameter
class BoolParameter : Parameter
{
public:
    this(Client client, int index, string name, string label, bool defaultValue)
    {
        super(client, index, name, label);
        _value = defaultValue;
        _defaultValue = defaultValue;
    }

    override void setNormalized(float hostValue) nothrow @nogc
    {
        _valueMutex.lock();
        if (hostValue < 0.5f)
            _value = false;
        else
            _value = true;
        _valueMutex.unlock();
    }

    override float getNormalized() nothrow @nogc
    {
        _valueMutex.lock();
        float result = _value ? 1.0f : 0.0f;
        _valueMutex.unlock();
        return result;
    }

    override float getNormalizedDefault() nothrow @nogc
    {
        return _defaultValue ? 1.0f : 0.0f;
    }

    override void toStringN(char* buffer, size_t numBytes) nothrow @nogc
    {
        bool v;
        _valueMutex.lock();
        v = _value;
        _valueMutex.unlock();

        if (v)
            snprintf(buffer, numBytes, "true");
        else
            snprintf(buffer, numBytes, "false");
    }

    void setFromGUI(bool value)
    {
        _valueMutex.lock();
        _value = value;
        _valueMutex.unlock();

        // Important
        // There is a race here on _value, because spinlocks aren't reentrant we had to move this line
        // out of the mutex.
        // That said, the potential for harm seems reduced (receiving a setParameter between _value assignment and getNormalized).

        float normalized = getNormalized();

        _client.hostCommand().paramAutomate(_index, normalized);
        notifyListeners();
    }

    bool value() nothrow @nogc
    {
        _valueMutex.lock();
        scope(exit) _valueMutex.unlock();
        return _value;
    }

    bool defaultValue() pure const nothrow @nogc
    {
        return _defaultValue;
    }

private:
    bool _value;
    bool _defaultValue;
}

/// A float parameter
class FloatParameter : Parameter
{
public:
    this(Client client, int index, string name, string label, float min = 0.0f, float max = 1.0f, float defaultValue = 0.5f)
    {
        super(client, index, name, label);
        assert(defaultValue >= min && defaultValue <= max);
        _defaultValue = defaultValue;
        _name = name;
        _value = _defaultValue;
        _min = min;
        _max = max;
    }

    void setFromGUI(float value)
    {
        if (value < _min)
            value = _min;
        if (value > _max)
            value = _max;

        float normalized;

        _valueMutex.lock();
        _value = value;
        _valueMutex.unlock();

        // Important
        // There is a race here on _value, because spinlocks aren't reentrant we had to move this line
        // out of the mutex.
        // That said, the potential for harm seems reduced (receiving a setParameter between _value assignment and getNormalized).

        normalized = getNormalized();

        _client.hostCommand().paramAutomate(_index, normalized);
        notifyListeners();
    }

    override void setNormalized(float hostValue) nothrow @nogc
    {
        float v = clamp!float(_min + (_max - _min) * hostValue, _min, _max);
        _valueMutex.lock();
        _value = v;
        _valueMutex.unlock();
    }

    override float getNormalized() nothrow @nogc
    {
        float normalized = clamp!float( (value() - _min) / (_max - _min), 0.0f, 1.0f);
        return normalized;
    }

    override float getNormalizedDefault() nothrow @nogc
    {
        float normalized = clamp!float( (_defaultValue - _min) / (_max - _min), 0.0f, 1.0f);
        return normalized;
    }

    override void toStringN(char* buffer, size_t numBytes) nothrow @nogc
    {
        snprintf(buffer, numBytes, "%2.2f", value());
    }

    float value() nothrow @nogc
    {
        _valueMutex.lock();
        scope(exit) _valueMutex.unlock();
        return _value;
    }

    float minValue() pure const nothrow @nogc
    {
        return _min;
    }

    float maxValue() pure const nothrow @nogc
    {
        return _max;
    }

    float defaultValue() pure const nothrow @nogc
    {
        return _defaultValue;
    }

private:
    float _value;
    float _min;
    float _max;
    float _defaultValue;
}

/// An integer parameter
class IntParameter : Parameter
{
public:
    this(Client client, int index, string name, string label, int min = 0, int max = 1, int defaultValue = 0)
    {
        super(client, index, name, label);
        _name = name;
        _value = clamp!int(defaultValue, min, max);
        _min = min;
        _max = max;
    }

    override void setNormalized(float hostValue)
    {
        int rounded = cast(int)lround( _min + (_max - _min) * hostValue );

        _valueMutex.lock();
        _value = clamp!int(rounded, _min, _max);
        _valueMutex.unlock();
    }

    override float getNormalized() nothrow @nogc
    {
        int v;
        _valueMutex.lock();
        v = _value;
        _valueMutex.unlock();

        float normalized = clamp!float( (cast(float)v - _min) / (_max - _min), 0.0f, 1.0f);
        return normalized;
    }

    override void toStringN(char* buffer, size_t numBytes) nothrow @nogc
    {
        int v;
        _valueMutex.lock();
        v = _value;
        _valueMutex.unlock();
        snprintf(buffer, numBytes, "%d", v);
    }

    int value() nothrow @nogc
    {
        _valueMutex.lock();
        scope(exit) _valueMutex.unlock();
        return _value;
    }

private:
    int _value;
    int _min;
    int _max;
}

private
{
    T clamp(T)(T x, T min, T max) pure nothrow @nogc
    {
        if (x < min)
            return min;
        else if (x > max)
            return max;
        else
            return x;
    }
}
