#include "Json.h"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace macvoxel {
namespace {

constexpr int kMaxDepth = 64;

class Parser {
public:
    explicit Parser(std::string_view text) : in_(text) {}

    bool Parse(Json* out, std::string* error) {
        error_ = error;
        if (!ParseValue(out, 0)) return false;
        SkipWs();
        if (i_ != in_.size()) return Fail("trailing data after JSON value");
        return true;
    }

private:
    bool Fail(const char* message) {
        if (error_ != nullptr && error_->empty()) *error_ = message;
        return false;
    }

    void SkipWs() {
        while (i_ < in_.size()) {
            const char c = in_[i_];
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
            ++i_;
        }
    }

    bool ParseValue(Json* out, int depth) {
        if (depth > kMaxDepth) return Fail("JSON nested too deeply");
        SkipWs();
        if (i_ >= in_.size()) return Fail("unexpected end of JSON");
        const char c = in_[i_];
        if (c == 'n') return Literal("null", Json::null(), out);
        if (c == 't') return Literal("true", Json::boolean(true), out);
        if (c == 'f') return Literal("false", Json::boolean(false), out);
        if (c == '"') {
            std::string s;
            if (!ParseString(&s)) return false;
            *out = Json::str(std::move(s));
            return true;
        }
        if (c == '[') return ParseArray(out, depth);
        if (c == '{') return ParseObject(out, depth);
        if (c == '-' || (c >= '0' && c <= '9')) return ParseNumber(out);
        return Fail("unexpected character in JSON");
    }

    bool Literal(std::string_view word, Json value, Json* out) {
        if (in_.substr(i_, word.size()) != word) return Fail("invalid JSON literal");
        i_ += word.size();
        *out = std::move(value);
        return true;
    }

    bool ParseArray(Json* out, int depth) {
        ++i_;
        Json arr = Json::array();
        SkipWs();
        if (i_ < in_.size() && in_[i_] == ']') {
            ++i_;
            *out = std::move(arr);
            return true;
        }
        while (i_ < in_.size()) {
            Json elem;
            if (!ParseValue(&elem, depth + 1)) return false;
            arr.push(std::move(elem));
            SkipWs();
            if (i_ >= in_.size()) return Fail("unclosed JSON array");
            if (in_[i_] == ',') {
                ++i_;
                continue;
            }
            if (in_[i_] == ']') {
                ++i_;
                *out = std::move(arr);
                return true;
            }
            return Fail("expected ',' or ']' in JSON array");
        }
        return Fail("unclosed JSON array");
    }

    bool ParseObject(Json* out, int depth) {
        ++i_;
        Json obj = Json::object();
        SkipWs();
        if (i_ < in_.size() && in_[i_] == '}') {
            ++i_;
            *out = std::move(obj);
            return true;
        }
        while (i_ < in_.size()) {
            SkipWs();
            if (i_ >= in_.size() || in_[i_] != '"') {
                return Fail("expected string key in JSON object");
            }
            std::string key;
            if (!ParseString(&key)) return false;
            SkipWs();
            if (i_ >= in_.size() || in_[i_] != ':') return Fail("expected ':' after JSON key");
            ++i_;
            Json value;
            if (!ParseValue(&value, depth + 1)) return false;
            obj.set(std::move(key), std::move(value));
            SkipWs();
            if (i_ >= in_.size()) return Fail("unclosed JSON object");
            if (in_[i_] == ',') {
                ++i_;
                continue;
            }
            if (in_[i_] == '}') {
                ++i_;
                *out = std::move(obj);
                return true;
            }
            return Fail("expected ',' or '}' in JSON object");
        }
        return Fail("unclosed JSON object");
    }

    bool ParseString(std::string* out) {
        ++i_;  // opening quote
        out->clear();
        while (i_ < in_.size()) {
            const unsigned char c = static_cast<unsigned char>(in_[i_]);
            if (c == '"') {
                ++i_;
                return true;
            }
            if (c == '\\') {
                ++i_;
                if (i_ >= in_.size()) return Fail("unterminated escape in JSON string");
                const char e = in_[i_++];
                switch (e) {
                    case '"':
                    case '\\':
                    case '/':
                        out->push_back(e);
                        break;
                    case 'b':
                        out->push_back('\b');
                        break;
                    case 'f':
                        out->push_back('\f');
                        break;
                    case 'n':
                        out->push_back('\n');
                        break;
                    case 'r':
                        out->push_back('\r');
                        break;
                    case 't':
                        out->push_back('\t');
                        break;
                    case 'u':
                        if (!ParseUnicode(out)) return false;
                        break;
                    default:
                        return Fail("invalid escape in JSON string");
                }
                continue;
            }
            if (c < 0x20) return Fail("raw control character in JSON string");
            out->push_back(static_cast<char>(c));
            ++i_;
        }
        return Fail("unterminated JSON string");
    }

    bool ParseUnicode(std::string* out) {
        uint32_t cp = 0;
        if (!Hex4(&cp)) return false;
        if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (i_ + 2 > in_.size() || in_[i_] != '\\' || in_[i_ + 1] != 'u') {
                AppendUtf8(out, 0xFFFD);
                return true;
            }
            i_ += 2;
            uint32_t low = 0;
            if (!Hex4(&low)) return false;
            if (low < 0xDC00 || low > 0xDFFF) {
                AppendUtf8(out, 0xFFFD);
                return true;
            }
            cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
        } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
            cp = 0xFFFD;
        }
        AppendUtf8(out, cp);
        return true;
    }

    bool Hex4(uint32_t* out) {
        if (i_ + 4 > in_.size()) return Fail("short unicode escape in JSON string");
        uint32_t v = 0;
        for (int n = 0; n < 4; ++n) {
            const char c = in_[i_++];
            v <<= 4;
            if (c >= '0' && c <= '9') {
                v |= static_cast<uint32_t>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                v |= static_cast<uint32_t>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                v |= static_cast<uint32_t>(c - 'A' + 10);
            } else {
                return Fail("invalid unicode escape in JSON string");
            }
        }
        *out = v;
        return true;
    }

    static void AppendUtf8(std::string* out, uint32_t cp) {
        if (cp < 0x80) {
            out->push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out->push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool ParseNumber(Json* out) {
        const size_t begin = i_;
        if (in_[i_] == '-') ++i_;
        if (i_ >= in_.size() || in_[i_] < '0' || in_[i_] > '9') {
            return Fail("invalid JSON number");
        }
        if (in_[i_] == '0') {
            ++i_;
        } else {
            while (i_ < in_.size() && in_[i_] >= '0' && in_[i_] <= '9') ++i_;
        }
        bool integral = true;
        if (i_ < in_.size() && in_[i_] == '.') {
            integral = false;
            ++i_;
            if (i_ >= in_.size() || in_[i_] < '0' || in_[i_] > '9') {
                return Fail("invalid JSON number");
            }
            while (i_ < in_.size() && in_[i_] >= '0' && in_[i_] <= '9') ++i_;
        }
        if (i_ < in_.size() && (in_[i_] == 'e' || in_[i_] == 'E')) {
            integral = false;
            ++i_;
            if (i_ < in_.size() && (in_[i_] == '+' || in_[i_] == '-')) ++i_;
            if (i_ >= in_.size() || in_[i_] < '0' || in_[i_] > '9') {
                return Fail("invalid JSON number");
            }
            while (i_ < in_.size() && in_[i_] >= '0' && in_[i_] <= '9') ++i_;
        }
        const std::string_view token = in_.substr(begin, i_ - begin);
        if (integral) {
            int64_t v = 0;
            const char* first = token.data();
            const char* last = first + token.size();
            const auto res = std::from_chars(first, last, v);
            if (res.ec != std::errc{} || res.ptr != last) return Fail("JSON integer out of range");
            *out = Json::integer(v);
            return true;
        }
        // std::from_chars for floating point is not available at this
        // deployment target. The token is a validated JSON number.
        std::string token_owned(token);
        char* end = nullptr;
        const double v = std::strtod(token_owned.c_str(), &end);
        if (end != token_owned.c_str() + token_owned.size() || !std::isfinite(v)) {
            return Fail("invalid JSON number");
        }
        *out = Json::number(v);
        return true;
    }

    std::string_view in_;
    size_t i_ = 0;
    std::string* error_ = nullptr;
};

void AppendEscaped(std::string* out, std::string_view s) {
    out->push_back('"');
    for (unsigned char c : s) {
        switch (c) {
            case '"':
                out->append("\\\"");
                break;
            case '\\':
                out->append("\\\\");
                break;
            case '\b':
                out->append("\\b");
                break;
            case '\f':
                out->append("\\f");
                break;
            case '\n':
                out->append("\\n");
                break;
            case '\r':
                out->append("\\r");
                break;
            case '\t':
                out->append("\\t");
                break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out->append(buf);
                } else {
                    out->push_back(static_cast<char>(c));
                }
                break;
        }
    }
    out->push_back('"');
}

void Indent(std::string* out, int n) {
    out->append(static_cast<size_t>(n) * 2, ' ');
}

}  // namespace

Json Json::null() { return Json(); }

Json Json::boolean(bool value) {
    Json j;
    j.type_ = Type::Bool;
    j.bool_ = value;
    return j;
}

Json Json::integer(int64_t value) {
    Json j;
    j.type_ = Type::Number;
    j.is_int_ = true;
    j.i_ = value;
    return j;
}

Json Json::number(double value) {
    Json j;
    j.type_ = Type::Number;
    j.d_ = value;
    return j;
}

Json Json::str(std::string value) {
    Json j;
    j.type_ = Type::String;
    j.s_ = std::move(value);
    return j;
}

Json Json::array() {
    Json j;
    j.type_ = Type::Array;
    return j;
}

Json Json::object() {
    Json j;
    j.type_ = Type::Object;
    return j;
}

const Json* Json::find(std::string_view key) const {
    if (type_ != Type::Object) return nullptr;
    for (const auto& [k, v] : o_) {
        if (k == key) return &v;
    }
    return nullptr;
}

void Json::push(Json value) {
    if (type_ != Type::Array) return;
    a_.push_back(std::move(value));
}

void Json::set(std::string key, Json value) {
    if (type_ != Type::Object) return;
    for (auto& [k, v] : o_) {
        if (k == key) {
            v = std::move(value);
            return;
        }
    }
    o_.emplace_back(std::move(key), std::move(value));
}

bool Json::Parse(std::string_view text, Json* out, std::string* error) {
    if (error != nullptr) error->clear();
    Parser parser(text);
    return parser.Parse(out, error);
}

void Json::DumpInto(std::string* out) const {
    switch (type_) {
        case Type::Null:
            out->append("null");
            break;
        case Type::Bool:
            out->append(bool_ ? "true" : "false");
            break;
        case Type::Number:
            if (is_int_) {
                out->append(std::to_string(i_));
            } else {
                char buf[64];
                std::snprintf(buf, sizeof(buf), "%.17g", d_);
                out->append(buf);
            }
            break;
        case Type::String:
            AppendEscaped(out, s_);
            break;
        case Type::Array:
            out->push_back('[');
            for (size_t n = 0; n < a_.size(); ++n) {
                if (n != 0) out->push_back(',');
                a_[n].DumpInto(out);
            }
            out->push_back(']');
            break;
        case Type::Object:
            out->push_back('{');
            for (size_t n = 0; n < o_.size(); ++n) {
                if (n != 0) out->push_back(',');
                AppendEscaped(out, o_[n].first);
                out->push_back(':');
                o_[n].second.DumpInto(out);
            }
            out->push_back('}');
            break;
    }
}

void Json::DumpPrettyInto(std::string* out, int indent) const {
    switch (type_) {
        case Type::Array:
            if (a_.empty()) {
                out->append("[]");
                return;
            }
            out->append("[\n");
            for (size_t n = 0; n < a_.size(); ++n) {
                Indent(out, indent + 1);
                a_[n].DumpPrettyInto(out, indent + 1);
                if (n + 1 != a_.size()) out->push_back(',');
                out->push_back('\n');
            }
            Indent(out, indent);
            out->push_back(']');
            return;
        case Type::Object:
            if (o_.empty()) {
                out->append("{}");
                return;
            }
            out->append("{\n");
            for (size_t n = 0; n < o_.size(); ++n) {
                Indent(out, indent + 1);
                AppendEscaped(out, o_[n].first);
                out->append(": ");
                o_[n].second.DumpPrettyInto(out, indent + 1);
                if (n + 1 != o_.size()) out->push_back(',');
                out->push_back('\n');
            }
            Indent(out, indent);
            out->push_back('}');
            return;
        default:
            DumpInto(out);
            return;
    }
}

std::string Json::Dump() const {
    std::string out;
    DumpInto(&out);
    return out;
}

std::string Json::DumpPretty() const {
    std::string out;
    DumpPrettyInto(&out, 0);
    return out;
}

}  // namespace macvoxel
