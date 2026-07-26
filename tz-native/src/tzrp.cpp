// Facade over the Discord Social SDK's C API, exposing a flat, poll-based,
// C-ABI surface that LuaJIT's FFI can drive from the game's main thread.
//
// Design constraints (see ../CLAUDE.md):
//   * No callbacks into Lua, ever. Diagnostics are queued and drained by
//     TZRP_PollMessage from mod.update.
//   * Every export catches exceptions at the boundary; an unwind crossing
//     extern "C" into the game process is fatal.
//   * Only primitives and const char* / char* buffers cross the boundary.
//
// Rich-presence-only mode: we deliberately never call Discord_Client_Connect.
// Per discordpp.h, presence set on a disconnected client is written straight
// to the local Discord client, which is what the old DiscordRichPresence mod
// got from discord-rpc -- and it skips OAuth entirely.

#include "cdiscord.h"

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#define TZRP_API extern "C" __declspec(dllexport)

namespace {

// ---------------------------------------------------------------- utilities

Discord_String str(const char* s, size_t len)
{
    Discord_String out;
    out.ptr = reinterpret_cast<uint8_t*>(const_cast<char*>(s));
    out.size = len;
    return out;
}

Discord_String str(const std::string& s)
{
    return str(s.data(), s.size());
}

std::string take(Discord_String* s)
{
    if (s == nullptr || s->ptr == nullptr) {
        return std::string();
    }
    return std::string(reinterpret_cast<const char*>(s->ptr), s->size);
}

std::string from_c(const char* s)
{
    return s == nullptr ? std::string() : std::string(s);
}

// Discord validates every presence string and rejects the ENTIRE activity if
// any single one is out of range -- so a 1-character character name would cost
// you the whole presence. We clamp instead: too long is truncated, too short is
// dropped, and the drop is reported so it is visible in the game log.
struct Limit {
    size_t min;
    size_t max;
};

constexpr Limit LIMIT_TEXT{2, 128};  // details, state, *Text, party.id
constexpr Limit LIMIT_IMAGE{1, 300}; // assets.*Image

// Truncates on a UTF-8 boundary. Discord counts these limits in codepoints, so
// cutting at `max` bytes always leaves at most `max` codepoints.
std::string truncate_utf8(const std::string& value, size_t max_bytes)
{
    if (value.size() <= max_bytes) {
        return value;
    }
    size_t end = max_bytes;
    while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) {
        --end; // back off out of the middle of a multi-byte sequence
    }
    return value.substr(0, end);
}

// An optional string: `set` distinguishes "" (explicitly empty) from unset.
struct Field {
    bool set = false;
    std::string value;

    void assign(const char* s)
    {
        if (s == nullptr) {
            set = false;
            value.clear();
        } else {
            set = true;
            value = s;
        }
    }

    bool operator==(const Field& o) const { return set == o.set && value == o.value; }
    bool operator!=(const Field& o) const { return !(*this == o); }
};

struct Button {
    std::string label;
    std::string url;

    bool operator==(const Button& o) const { return label == o.label && url == o.url; }
};

// Everything the Lua side can stage. Compared wholesale to decide whether a
// commit is worth sending -- Discord rate-limits presence updates, and the
// game calls _update_my_presence far more often than anything changes.
struct Presence {
    Field details;
    Field state;
    Field large_image;
    Field large_text;
    Field small_image;
    Field small_text;
    Field party_id;
    int32_t party_current = 0;
    int32_t party_max = 0;
    uint64_t start_time = 0;
    uint64_t end_time = 0;
    int32_t activity_type = 0; // Discord_ActivityTypes_Playing
    std::vector<Button> buttons;

    bool operator==(const Presence& o) const
    {
        return details == o.details && state == o.state && large_image == o.large_image &&
               large_text == o.large_text && small_image == o.small_image &&
               small_text == o.small_text && party_id == o.party_id &&
               party_current == o.party_current && party_max == o.party_max &&
               start_time == o.start_time && end_time == o.end_time &&
               activity_type == o.activity_type && buttons == o.buttons;
    }
};

struct State {
    std::mutex mutex;
    bool initialized = false;
    Discord_Client client{};

    Presence staged;
    Presence last_sent;
    bool has_sent = false;

    std::deque<std::string> messages;
    std::string last_error;
};

State& g()
{
    static State state;
    return state;
}

// Queue a diagnostic line for Lua to drain. Bounded so a broken SDK cannot
// grow this without limit if the mod stops polling.
void push_message(std::string message)
{
    State& s = g();
    if (s.messages.size() >= 128) {
        s.messages.pop_front();
    }
    s.messages.push_back(std::move(message));
}

void push_message_locked(std::string message)
{
    std::lock_guard<std::mutex> lock(g().mutex);
    push_message(std::move(message));
}

void set_error(const std::string& message)
{
    g().last_error = message;
    push_message("error: " + message);
}

bool is_http_url(const std::string& url)
{
    return url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0;
}

// Stable for the lifetime of the process but unique per player, so Discord does
// not group unrelated players into a single party.
const std::string& session_party_id()
{
    static const std::string id =
      "tzrp-" +
      std::to_string(
        static_cast<uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count()) ^
        static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&session_party_id)));
    return id;
}

// ------------------------------------------------------------ SDK callbacks
// These run on whatever thread the SDK dispatches from. They only touch our
// own mutex-guarded queue -- never Lua.

void on_log(Discord_String message, Discord_LoggingSeverity severity, void*)
{
    if (severity < Discord_LoggingSeverity_Warning) {
        return; // info/verbose is far too chatty for the game log
    }
    push_message_locked("sdk: " + take(&message));
}

void on_presence_result(Discord_ClientResult* result, void*)
{
    if (result == nullptr) {
        return;
    }
    if (Discord_ClientResult_Type(result) == Discord_ErrorType_None) {
        push_message_locked("presence updated");
        return;
    }
    Discord_String text{};
    Discord_ClientResult_ToString(result, &text);
    push_message_locked("presence failed: " + take(&text));
}

// ------------------------------------------------------------ activity build

// Owns every SDK handle it creates so a throw or early return cannot leak.
struct ActivityBuilder {
    Discord_Activity activity{};
    Discord_ActivityAssets assets{};
    Discord_ActivityTimestamps timestamps{};
    Discord_ActivityParty party{};
    bool has_assets = false;
    bool has_timestamps = false;
    bool has_party = false;

    ActivityBuilder() { Discord_Activity_Init(&activity); }

    ~ActivityBuilder()
    {
        if (has_party) {
            Discord_ActivityParty_Drop(&party);
        }
        if (has_timestamps) {
            Discord_ActivityTimestamps_Drop(&timestamps);
        }
        if (has_assets) {
            Discord_ActivityAssets_Drop(&assets);
        }
        Discord_Activity_Drop(&activity);
    }

    ActivityBuilder(const ActivityBuilder&) = delete;
    ActivityBuilder& operator=(const ActivityBuilder&) = delete;

    // Returns false when the field is unusable and must be omitted entirely.
    static bool usable(const Field& f, const Limit& limit, const char* name, std::string& out)
    {
        if (!f.set) {
            return false;
        }
        out = truncate_utf8(f.value, limit.max);
        if (out.size() < limit.min) {
            if (!f.value.empty()) {
                push_message(std::string("dropped ") + name + ": shorter than " +
                             std::to_string(limit.min) + " characters");
            }
            return false;
        }
        return true;
    }

    void build(const Presence& p)
    {
        Discord_Activity_SetType(&activity, static_cast<Discord_ActivityTypes>(p.activity_type));

        // These must outlive the Set* calls below; Discord_String is only a view.
        std::string details_text;
        std::string state_text;

        if (usable(p.details, LIMIT_TEXT, "details", details_text)) {
            Discord_String value = str(details_text);
            Discord_Activity_SetDetails(&activity, &value);
        }
        if (usable(p.state, LIMIT_TEXT, "state", state_text)) {
            Discord_String value = str(state_text);
            Discord_Activity_SetState(&activity, &value);
        }

        std::string large_image_text;
        std::string large_text_text;
        std::string small_image_text;
        std::string small_text_text;

        const bool has_large_image =
          usable(p.large_image, LIMIT_IMAGE, "assets.largeImage", large_image_text);
        const bool has_large_text =
          usable(p.large_text, LIMIT_TEXT, "assets.largeText", large_text_text);
        const bool has_small_image =
          usable(p.small_image, LIMIT_IMAGE, "assets.smallImage", small_image_text);
        const bool has_small_text =
          usable(p.small_text, LIMIT_TEXT, "assets.smallText", small_text_text);

        if (has_large_image || has_large_text || has_small_image || has_small_text) {
            Discord_ActivityAssets_Init(&assets);
            has_assets = true;
            Discord_String large_image = str(large_image_text);
            Discord_String large_text = str(large_text_text);
            Discord_String small_image = str(small_image_text);
            Discord_String small_text = str(small_text_text);
            if (has_large_image) {
                Discord_ActivityAssets_SetLargeImage(&assets, &large_image);
            }
            if (has_large_text) {
                Discord_ActivityAssets_SetLargeText(&assets, &large_text);
            }
            if (has_small_image) {
                Discord_ActivityAssets_SetSmallImage(&assets, &small_image);
            }
            if (has_small_text) {
                Discord_ActivityAssets_SetSmallText(&assets, &small_text);
            }
            Discord_Activity_SetAssets(&activity, &assets);
        }

        if (p.start_time != 0 || p.end_time != 0) {
            Discord_ActivityTimestamps_Init(&timestamps);
            has_timestamps = true;
            if (p.start_time != 0) {
                Discord_ActivityTimestamps_SetStart(&timestamps, p.start_time);
            }
            if (p.end_time != 0) {
                Discord_ActivityTimestamps_SetEnd(&timestamps, p.end_time);
            }
            Discord_Activity_SetTimestamps(&activity, &timestamps);
        }

        if (p.party_max > 0) {
            // party.id is mandatory once a party exists. Callers usually only
            // want to show "2 of 4", so fall back to a per-session id rather
            // than dropping the party -- or failing the whole activity.
            std::string party_id;
            if (!usable(p.party_id, LIMIT_TEXT, "party.id", party_id)) {
                party_id = session_party_id();
            }

            Discord_ActivityParty_Init(&party);
            has_party = true;
            Discord_ActivityParty_SetId(&party, str(party_id));
            Discord_ActivityParty_SetCurrentSize(&party, p.party_current);
            Discord_ActivityParty_SetMaxSize(&party, p.party_max);
            Discord_ActivityParty_SetPrivacy(&party, Discord_ActivityPartyPrivacy_Private);
            Discord_Activity_SetParty(&activity, &party);
        }

        for (const Button& b : p.buttons) {
            // A malformed url fails the whole activity, not just the button.
            if (b.label.empty() || !is_http_url(b.url)) {
                push_message("dropped button '" + b.label + "': needs a label and an http(s) url");
                continue;
            }
            Discord_ActivityButton button{};
            Discord_ActivityButton_Init(&button);
            Discord_ActivityButton_SetLabel(&button, str(b.label));
            Discord_ActivityButton_SetUrl(&button, str(b.url));
            Discord_Activity_AddButton(&activity, &button);
            Discord_ActivityButton_Drop(&button);
        }
    }
};

} // namespace

// ------------------------------------------------------------------ exports
// Every one of these wraps its body in try/catch: an exception escaping into
// the game through extern "C" is unrecoverable and pcall cannot catch it.

#define TZRP_GUARD(default_value)                                                                  \
    catch (const std::exception& e)                                                                \
    {                                                                                              \
        try {                                                                                      \
            std::lock_guard<std::mutex> lock(g().mutex);                                           \
            set_error(e.what());                                                                   \
        } catch (...) {                                                                            \
        }                                                                                          \
        return default_value;                                                                      \
    }                                                                                              \
    catch (...)                                                                                    \
    {                                                                                              \
        return default_value;                                                                      \
    }

#define TZRP_GUARD_VOID                                                                                catch (const std::exception& e)                                                                    {                                                                                                      try {                                                                                                  std::lock_guard<std::mutex> lock(g().mutex);                                                       set_error(e.what());                                                                           } catch (...) {                                                                                    }                                                                                                  return;                                                                                        }                                                                                                  catch (...)                                                                                        {                                                                                                      return;                                                                                        }

/// Creates the Discord client for `application_id` (decimal snowflake string).
/// Returns 1 on success, 0 on failure (see TZRP_LastError).
TZRP_API int TZRP_Init(const char* application_id)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);

        if (s.initialized) {
            return 1;
        }

        const std::string id_text = from_c(application_id);
        if (id_text.empty()) {
            set_error("application id is empty");
            return 0;
        }

        char* parse_end = nullptr;
        const uint64_t id = std::strtoull(id_text.c_str(), &parse_end, 10);
        if (id == 0 || parse_end == nullptr || *parse_end != '\0') {
            set_error("application id is not a decimal snowflake: " + id_text);
            return 0;
        }

        Discord_Client_Init(&s.client);
        Discord_Client_SetApplicationId(&s.client, id);
        Discord_Client_AddLogCallback(
          &s.client, on_log, nullptr, nullptr, Discord_LoggingSeverity_Warning);

        s.initialized = true;
        s.has_sent = false;
        push_message("initialized for application " + id_text);
        return 1;
    }
    TZRP_GUARD(0)
}

/// Drops the client. Safe to call when uninitialized.
TZRP_API void TZRP_Shutdown(void)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        if (!s.initialized) {
            return;
        }
        Discord_Client_Drop(&s.client);
        s.client = Discord_Client{};
        s.initialized = false;
        s.has_sent = false;
    }
    TZRP_GUARD_VOID
}

/// Pumps the SDK. Must be called every frame from mod.update -- without it
/// no result callback ever fires and queued work never drains.
TZRP_API void TZRP_Update(void)
{
    try {
        Discord_RunCallbacks();
    }
    TZRP_GUARD_VOID
}

/// Current Discord_Client_Status. In rich-presence-only mode this stays
/// Disconnected (0); it is here for diagnostics and future Connect support.
TZRP_API int TZRP_Status(void)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        if (!s.initialized) {
            return -1;
        }
        return static_cast<int>(Discord_Client_GetStatus(&s.client));
    }
    TZRP_GUARD(-1)
}

// -- staging setters. NULL clears a field; "" sets it to an empty string.

#define TZRP_SETTER(name, member)                                                                  \
    TZRP_API void name(const char* value)                                                          \
    {                                                                                              \
        try {                                                                                      \
            State& s = g();                                                                        \
            std::lock_guard<std::mutex> lock(s.mutex);                                             \
            s.staged.member.assign(value);                                                         \
        }                                                                                          \
        TZRP_GUARD_VOID                                                                               \
    }

TZRP_SETTER(TZRP_SetDetails, details)
TZRP_SETTER(TZRP_SetState, state)

TZRP_API void TZRP_SetLargeImage(const char* key, const char* text)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        s.staged.large_image.assign(key);
        s.staged.large_text.assign(text);
    }
    TZRP_GUARD_VOID
}

TZRP_API void TZRP_SetSmallImage(const char* key, const char* text)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        s.staged.small_image.assign(key);
        s.staged.small_text.assign(text);
    }
    TZRP_GUARD_VOID
}

/// max <= 0 removes the party field entirely.
TZRP_API void TZRP_SetParty(const char* id, int current, int max)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        s.staged.party_id.assign(id == nullptr ? "" : id);
        s.staged.party_current = current;
        s.staged.party_max = max;
    }
    TZRP_GUARD_VOID
}

/// Unix seconds; 0 means unset. A start time makes Discord show "XX:XX elapsed".
TZRP_API void TZRP_SetTimestamps(int64_t start_time, int64_t end_time)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        s.staged.start_time = start_time > 0 ? static_cast<uint64_t>(start_time) : 0;
        s.staged.end_time = end_time > 0 ? static_cast<uint64_t>(end_time) : 0;
    }
    TZRP_GUARD_VOID
}

/// Discord_ActivityTypes; 0 = Playing.
TZRP_API void TZRP_SetActivityType(int activity_type)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        s.staged.activity_type = activity_type;
    }
    TZRP_GUARD_VOID
}

TZRP_API void TZRP_ClearButtons(void)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        s.staged.buttons.clear();
    }
    TZRP_GUARD_VOID
}

/// Discord displays at most two buttons; further calls are ignored.
TZRP_API void TZRP_AddButton(const char* label, const char* url)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.staged.buttons.size() >= 2 || label == nullptr || url == nullptr) {
            return;
        }
        s.staged.buttons.push_back(Button{label, url});
    }
    TZRP_GUARD_VOID
}

/// Sends the staged presence. Returns 1 if a request went out, 0 if it was
/// skipped as unchanged or the client is not initialized. Pass force != 0 to
/// send regardless -- but mind Discord's presence rate limit.
TZRP_API int TZRP_Commit(int force)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);

        if (!s.initialized) {
            set_error("commit before init");
            return 0;
        }
        if (force == 0 && s.has_sent && s.staged == s.last_sent) {
            return 0;
        }

        ActivityBuilder builder;
        builder.build(s.staged);
        Discord_Client_UpdateRichPresence(
          &s.client, &builder.activity, on_presence_result, nullptr, nullptr);

        s.last_sent = s.staged;
        s.has_sent = true;
        return 1;
    }
    TZRP_GUARD(0)
}

/// Clears presence in Discord. Staged fields are left alone so a later
/// Commit(force) can restore them.
TZRP_API void TZRP_Clear(void)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        if (!s.initialized) {
            return;
        }
        Discord_Client_ClearRichPresence(&s.client);
        s.has_sent = false;
    }
    TZRP_GUARD_VOID
}

/// Drains one queued diagnostic into `buffer` (always NUL-terminated).
/// Returns 1 if a message was written, 0 if the queue is empty.
TZRP_API int TZRP_PollMessage(char* buffer, int buffer_size)
{
    try {
        if (buffer == nullptr || buffer_size <= 0) {
            return 0;
        }

        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.messages.empty()) {
            return 0;
        }

        const std::string message = std::move(s.messages.front());
        s.messages.pop_front();

        const size_t length =
          message.size() < static_cast<size_t>(buffer_size) - 1
            ? message.size()
            : static_cast<size_t>(buffer_size) - 1;
        std::memcpy(buffer, message.data(), length);
        buffer[length] = '\0';
        return 1;
    }
    TZRP_GUARD(0)
}

/// Last error text, or "". Valid until the next failing call.
TZRP_API const char* TZRP_LastError(void)
{
    try {
        State& s = g();
        std::lock_guard<std::mutex> lock(s.mutex);
        return s.last_error.c_str();
    }
    TZRP_GUARD("")
}
