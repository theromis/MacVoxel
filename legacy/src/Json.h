#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace macvoxel {

// JSON value for the MCP stdio protocol. Numbers that fit in int64 and have
// no fraction or exponent keep their integer form so voxel coordinates
// round-trip exactly.
class Json {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    static Json null();
    static Json boolean(bool value);
    static Json integer(int64_t value);
    static Json number(double value);
    static Json str(std::string value);
    static Json array();
    static Json object();

    Type type() const { return type_; }
    bool is_null() const { return type_ == Type::Null; }
    bool is_bool() const { return type_ == Type::Bool; }
    bool is_number() const { return type_ == Type::Number; }
    bool is_int() const { return type_ == Type::Number && is_int_; }
    bool is_string() const { return type_ == Type::String; }
    bool is_array() const { return type_ == Type::Array; }
    bool is_object() const { return type_ == Type::Object; }

    bool boolean() const { return bool_; }
    int64_t integer() const { return i_; }
    double number() const { return is_int_ ? static_cast<double>(i_) : d_; }
    const std::string& string() const { return s_; }
    const std::vector<Json>& elements() const { return a_; }
    const Json* find(std::string_view key) const;

    void push(Json value);
    void set(std::string key, Json value);

    // One JSON value. Trailing whitespace is allowed; trailing junk is an
    // error. Depth is capped.
    static bool Parse(std::string_view text, Json* out, std::string* error);

    std::string Dump() const;
    std::string DumpPretty() const;

private:
    void DumpInto(std::string* out) const;
    void DumpPrettyInto(std::string* out, int indent) const;

    Type type_ = Type::Null;
    bool is_int_ = false;
    bool bool_ = false;
    int64_t i_ = 0;
    double d_ = 0;
    std::string s_;
    std::vector<Json> a_;
    std::vector<std::pair<std::string, Json>> o_;
};

}  // namespace macvoxel
