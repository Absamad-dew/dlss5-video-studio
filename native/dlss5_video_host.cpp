// dlss5-feed-host64 - the 64-bit half of DLSS5-Feeder for 32-bit games.
//
// A 32-bit game cannot load NGX or the DLSS 5 add-on (both x64-only). This little
// process can: it puts ReShade x64 (dxgi.dll) and renodx-dlss5.addon64 next to
// itself, opens a hidden 1x1 window with a minimal D3D12 swapchain -- so from the
// DLSS 5 add-on's point of view it IS a D3D12 game -- and runs the NGX DLAA
// evaluate on frames the game delivers through cross-process shared textures
// (created game-side on D3D11; see the phase-0 spike) and shared fences.
//
//   dlss5-feed-host64.exe --test   stand-alone: synthetic pattern, no game needed
//                                  (phase-1 proof: "feature 18 created" in ReShade.log)
//   dlss5-feed-host64.exe <pid>    serve the game with that PID over the pipe
//
// Logs to dlss5-feed-host.log next to the exe; the DLSS 5 add-on's own state
// appears in the host's ReShade.log.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <d3dcompiler.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstdarg>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <deque>
#include <filesystem>
#include <fstream>
#include <exception>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <io.h>

#include <nvsdk_ngx.h>
#include <nvsdk_ngx_helpers.h>
#include <DirectXPackedVector.h>

#include <sl.h>
#include <sl_consts.h>
#include <sl_dlss_g.h>
#include <sl_pcl.h>
#include <sl_reflex.h>

#include "feed_ipc.h"

namespace fs = std::filesystem;

static const std::array<char, 8> kMotionMagicV1 = {'D', '5', 'M', 'V', '0', '0', '0', '1'};
static const std::array<char, 8> kMotionMagicV2 = {'D', '5', 'M', 'V', '0', '0', '0', '2'};
static const std::array<char, 8> kMotionMagicV3 = {'D', '5', 'M', 'V', '0', '0', '0', '3'};
static const std::array<char, 8> kDepthMagic = {'D', '5', 'D', 'P', '0', '0', '0', '2'};

#pragma pack(push, 1)
struct MotionHeader
{
    char magic[8];
    uint32_t width, height, tile, frames, tiles_x, tiles_y, record_bytes, flags;
};
struct MotionRecord
{
    uint16_t x, y;
    uint8_t valid, confidence;
};
struct DepthHeader
{
    char magic[8];
    uint32_t width, height, frames, record_bytes, flags;
};
#pragma pack(pop)

static_assert(sizeof(MotionHeader) == 40);
static_assert(sizeof(MotionRecord) == 6);
static_assert(sizeof(DepthHeader) == 28);

struct BatchOptions
{
    bool enabled = false;
    bool reset_every_frame = false;
    bool timings = false;
    bool quiet_frames = false;
    bool prefetch = false;
    bool async_write = true;
    bool stream = false;
    bool delete_chunks = false;
    bool preview = false;
    bool preview_only = false;
    bool fast_start = false;
    bool fullscreen = false;
    bool motion_frame_generation = false;
    bool nvidia_frame_generation = false;
    bool nvidia_dynamic_mfg = false;
    uint32_t nvidia_generated_frames = 1;
    uint32_t nvidia_dynamic_target_fps = 0;
    fs::path input, output, encode_mp4, encode_chunks_dir, motion, depth;
    fs::path control_file, telemetry_file, chunk_ack_map;
    std::string codec = "h264";
    uint32_t width = 0, height = 0, frames = 0;
    uint32_t output_width = 0, output_height = 0;
    uint32_t fps = 25;
    uint32_t quality = 18;
    uint64_t encoder_affinity_mask = 0;
    double media_start_seconds = 0.0;
    double media_duration_seconds = 0.0;
};

using BatchClock = std::chrono::steady_clock;

static double ElapsedMs(BatchClock::time_point begin)
{
    return std::chrono::duration<double, std::milli>(BatchClock::now() - begin).count();
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

static char g_log_path[MAX_PATH];
static bool g_show_window = false;   // visible host window = the user's door to the DLSS 5 panel
static bool g_preview_mode = false;
static bool g_preview_direct = false;
static bool g_preview_has_frame = false;
static UINT g_preview_width = 960;
static UINT g_preview_height = 540;
static bool g_preview_fullscreen = false;
static bool g_preview_paused = false;
static bool g_preview_controls_visible = true;
static bool g_preview_controls_manually_hidden = false;
static bool g_preview_fps_visible = false;
static bool g_preview_window_revealed = false;
static bool g_d3d_debug_enabled = false;
static ID3D12InfoQueue *g_d3d_info_queue = nullptr;
static UINT64 g_preview_control_activity = 0;
static uint64_t g_preview_frame_index = 0;
static uint32_t g_preview_fps = 25;
static double g_preview_media_start_seconds = 0.0;
static double g_preview_media_duration_seconds = 0.0;
static fs::path g_preview_control_file;
static fs::path g_preview_event_file;
static fs::path g_preview_telemetry_file;
static RECT g_preview_windowed_rect = {};
static HWND g_preview_buttons[10] = {};
static HWND g_preview_seekbar = nullptr;
static HWND g_preview_time_current = nullptr;
static HWND g_preview_time_total = nullptr;
static HWND g_preview_controls_window = nullptr;
static HWND g_preview_fps_window = nullptr;
static HWND g_preview_fps_text = nullptr;
static HWND g_preview_backdrop = nullptr;
static bool g_preview_muted = false;
static BatchClock::time_point g_preview_fps_window_start = {};
static uint64_t g_preview_real_window_frames = 0;
static uint64_t g_preview_presented_window_frames = 0;
static uint64_t g_preview_real_total_frames = 0;
static uint64_t g_preview_presented_total_frames = 0;
static double g_preview_real_fps_live = 0.0;
static double g_preview_display_fps_live = 0.0;
static bool g_renodx_lazy = false;   // DLSS 5 add-on is v45+ (per-present rescan, lazy adoption)
static HMODULE g_reshade_proxy = nullptr;
static bool g_streamline_initialized = false;
static bool g_streamline_fg_requested = false;
static bool g_streamline_fg_enabled = false;
static bool g_streamline_fg_activate_after_present = false;
static sl::DLSSGOptions g_streamline_requested_options{};
static uint32_t g_streamline_last_present_count = 1;
static uint64_t g_streamline_frame_index = 0;
static volatile LONG g_streamline_api_error = S_OK;
static HRESULT g_streamline_last_present_hresult = S_OK;
static sl::ViewportHandle g_streamline_viewport(0);
static ID3D12Device *g_streamline_device_proxy = nullptr;
static ID3D12CommandQueue *g_streamline_queue_proxy = nullptr;
static ID3D12CommandQueue *g_streamline_pump_proxy = nullptr;
static IDXGIFactory2 *g_streamline_factory_proxy = nullptr;
using PFN_D3D12_SERIALIZE_ROOT_SIGNATURE_ = HRESULT (WINAPI *)(
    const D3D12_ROOT_SIGNATURE_DESC *, D3D_ROOT_SIGNATURE_VERSION, ID3DBlob **, ID3DBlob **);
static PFN_D3D12_SERIALIZE_ROOT_SIGNATURE_ g_d3d12_serialize_root_signature = nullptr;

static void Log(const char *fmt, ...);
static void SuspendStreamlineFrameGeneration(const char *reason);

// Detect the DLSS 5 add-on generation next to this exe: v45+ ('EnableHooks' marker in
// the binary) rescans every present and adopts missed features lazily, so the warm-up
// re-create is unnecessary -- and its EnableHooks key should be '2' (NGX-only) for this
// feeder, written into OUR ReShade.ini before ReShade loads and the add-on reads it.
static void DetectRenodxAddon()
{
    char dir[MAX_PATH], path[MAX_PATH], ini[MAX_PATH];
    GetModuleFileNameA(nullptr, dir, MAX_PATH);
    if (char *s = strrchr(dir, '\\')) *(s + 1) = '\0';
    sprintf_s(path, "%srenodx-dlss5.addon64", dir);
    sprintf_s(ini, "%sReShade.ini", dir);

    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) { Log("[host] renodx-dlss5.addon64 not found next to the host"); return; }
    const DWORD size = GetFileSize(f, nullptr);
    DWORD got = 0;
    char *buf = (size > 0 && size < 8u * 1024 * 1024) ? static_cast<char *>(malloc(size)) : nullptr;
    if (buf != nullptr && ReadFile(f, buf, size, &got, nullptr) && got == size)
        for (DWORD i = 0; i + 11 < size; ++i)
            if (memcmp(buf + i, "EnableHooks", 11) == 0) { g_renodx_lazy = true; break; }
    free(buf);
    CloseHandle(f);

    char ver[48] = "?";
    DWORD dummy = 0;
    const DWORD vsize = GetFileVersionInfoSizeA(path, &dummy);
    if (vsize > 0)
    {
        void *vdata = malloc(vsize);
        VS_FIXEDFILEINFO *ffi = nullptr;
        UINT flen = 0;
        if (vdata != nullptr && GetFileVersionInfoA(path, 0, vsize, vdata) &&
            VerQueryValueA(vdata, "\\", reinterpret_cast<void **>(&ffi), &flen) && ffi != nullptr)
            sprintf_s(ver, "%u.%u.%u.%u", HIWORD(ffi->dwFileVersionMS), LOWORD(ffi->dwFileVersionMS),
                      HIWORD(ffi->dwFileVersionLS), LOWORD(ffi->dwFileVersionLS));
        free(vdata);
    }
    Log("[host] DLSS 5 add-on: v%s -- %s engine", ver,
        g_renodx_lazy ? "v45+ (lazy adoption; warm-up skipped)" : "classic (warm-up stays on)");

    if (g_renodx_lazy)
    {
        char v[16] = {};
        GetPrivateProfileStringA("RenoDX.DLSS5", "EnableHooks", "", v, sizeof(v), ini);
        if (v[0] == '\0')
        {
            WritePrivateProfileStringA("RenoDX.DLSS5", "EnableHooks", "2", ini);
            Log("[host] EnableHooks was unset; wrote EnableHooks=2 into the host's ReShade.ini");
        }
        else
            Log("[host] EnableHooks=%s (user-set; leaving it alone)", v);
    }
}

static void Log(const char *fmt, ...)
{
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf_s(line, sizeof(line), _TRUNCATE, fmt, ap);
    va_end(ap);
    SYSTEMTIME st;
    GetLocalTime(&st);
    printf("%02u:%02u:%02u.%03u  %s\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, line);
    FILE *f = nullptr;
    if (fopen_s(&f, g_log_path, "a") == 0 && f != nullptr)
    {
        fprintf(f, "%02u:%02u:%02u.%03u  %s\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, line);
        fclose(f);
    }
}

static const char *NgxResultName(NVSDK_NGX_Result r)
{
    switch (static_cast<unsigned>(r))
    {
    case 0x1:        return "Success";
    case 0xBAD00005: return "InvalidParameter";
    case 0xBAD00007: return "NotInitialized";
    case 0xBAD00008: return "UnsupportedInputFormat";
    case 0xBAD0000A: return "MissingInput";
    case 0xBAD0000B: return "UnableToInitializeFeature";
    case 0xBAD0000D: return "OutOfGPUMemory";
    case 0xBAD0000E: return "UnsupportedFormat";
    default:         return "?";
    }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

struct Host
{
    HWND                       hwnd;
    IDXGISwapChain1           *swap;
    ID3D12Device              *dev;
    ID3D12CommandQueue        *queue;      // NGX work
    ID3D12CommandQueue        *pump_queue; // owns the dummy swapchain
    ID3D12GraphicsCommandList *list;
    // Batch mode submits upload, NGX evaluation and readback as separate command
    // lists.  Keep enough allocators for several complete frames in flight so
    // the CPU does not have to wait for the previous DLSS evaluation merely to
    // reset a command allocator.
    static const int           kFrames = 12;
    ID3D12CommandAllocator    *alloc[kFrames];
    UINT64                     alloc_fence[kFrames];
    int                        frame_slot;
    ID3D12Fence               *fence;      // internal (allocator ring)
    HANDLE                     fence_event;
    UINT64                     fence_value;

    // cross-process
    ID3D12Fence *fence_in;   // game signals, host waits
    ID3D12Fence *fence_out;  // host signals, game waits

    bool                 ngx_inited;
    NVSDK_NGX_Parameter *params;
    NVSDK_NGX_Handle    *feature;

    ID3D12Resource *tex[FEED_SLOTS];
    UINT            width, height;
    DXGI_FORMAT     color_fmt, output_fmt;
};

static Host h;

// ---------------------------------------------------------------------------
// Command submission (allocator ring), same shape as the add-on
// ---------------------------------------------------------------------------

static bool BeginCommands()
{
    const int slot = h.frame_slot;
    const UINT64 retire = h.alloc_fence[slot];
    if (retire != 0 && h.fence->GetCompletedValue() < retire)
    {
        h.fence->SetEventOnCompletion(retire, h.fence_event);
        if (WaitForSingleObject(h.fence_event, 2000) != WAIT_OBJECT_0)
        { Log("[host] GPU did not retire allocator slot %d", slot); return false; }
    }
    if (FAILED(h.alloc[slot]->Reset())) return false;
    return SUCCEEDED(h.list->Reset(h.alloc[slot], nullptr));
}

static UINT64 EndCommands()
{
    h.list->Close();
    ID3D12CommandList *lists[] = { h.list };
    h.queue->ExecuteCommandLists(1, lists);
    const UINT64 v = ++h.fence_value;
    h.queue->Signal(h.fence, v);
    h.alloc_fence[h.frame_slot] = v;
    h.frame_slot = (h.frame_slot + 1) % Host::kFrames;
    return v;
}

static bool WaitFenceValue(ID3D12Fence *f, UINT64 v, DWORD ms)
{
    if (f->GetCompletedValue() >= v) return true;
    f->SetEventOnCompletion(v, h.fence_event);
    return WaitForSingleObject(h.fence_event, ms) == WAIT_OBJECT_0;
}

static void CloseListGuarded()
{
    __try { h.list->Close(); } __except (EXCEPTION_EXECUTE_HANDLER) {}
}

static void AbortCommands()   // never execute a list NGX crashed in
{
    if (h.list == nullptr) return;
    CloseListGuarded();
    h.list->Release();
    h.list = nullptr;
    if (SUCCEEDED(h.dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, h.alloc[h.frame_slot], nullptr,
                                           __uuidof(ID3D12GraphicsCommandList), reinterpret_cast<void **>(&h.list))))
        h.list->Close();
}

static NVSDK_NGX_Result SafeCreateDLSS(NVSDK_NGX_DLSS_Create_Params *cp, DWORD *code)
{
    *code = 0;
    __try { return NGX_D3D12_CREATE_DLSS_EXT(h.list, 1, 1, &h.feature, h.params, cp); }
    __except (EXCEPTION_EXECUTE_HANDLER) { *code = GetExceptionCode(); return static_cast<NVSDK_NGX_Result>(0x7FFFFFFF); }
}

static NVSDK_NGX_Result SafeEvaluateDLSS(NVSDK_NGX_D3D12_DLSS_Eval_Params *ep, DWORD *code)
{
    *code = 0;
    __try { return NGX_D3D12_EVALUATE_DLSS_EXT(h.list, h.feature, h.params, ep); }
    __except (EXCEPTION_EXECUTE_HANDLER) { *code = GetExceptionCode(); return static_cast<NVSDK_NGX_Result>(0x7FFFFFFF); }
}

static void SafeReleaseFeature(NVSDK_NGX_Handle *f)
{
    if (f == nullptr) return;
    __try { NVSDK_NGX_D3D12_ReleaseFeature(f); }
    __except (EXCEPTION_EXECUTE_HANDLER) { Log("[host] ReleaseFeature raised 0x%08X (ignored)", GetExceptionCode()); }
}

// ---------------------------------------------------------------------------
// The disguise: hidden window + minimal D3D12 swapchain so ReShade x64 loads
// and the DLSS 5 add-on arms itself, exactly as in a real D3D12 game.
// In display-only mode this window also acts as a small, GPU-direct player.
// ---------------------------------------------------------------------------

enum PreviewControlId
{
    IDC_SEEK_BACK_BIG = 1001,
    IDC_SEEK_BACK = 1002,
    IDC_PAUSE = 1003,
    IDC_SEEK_FORWARD = 1004,
    IDC_SEEK_FORWARD_BIG = 1005,
    IDC_MUTE = 1006,
    IDC_FULLSCREEN = 1007,
    IDC_TOGGLE_FPS = 1008,
    IDC_HIDE_MENU = 1009,
    IDC_CLOSE_PLAYER = 1010
};

static double CurrentPreviewSeconds()
{
    return g_preview_media_start_seconds +
           static_cast<double>(g_preview_frame_index) / std::max(1u, g_preview_fps);
}

// Load the portable ReShade proxy explicitly before D3D12/DXGI initialization.
// The host deliberately resolves the operating-system DXGI exports by their
// absolute System32 paths, so relying on normal DLL search order does not load
// the adjacent proxy.  Previously the proxy happened to be loaded only by the
// optional Streamline/DLSS-G path, which meant Feature 18 was silently absent
// whenever frame generation was disabled.
static bool LoadPortableReShade()
{
    wchar_t executable[MAX_PATH] = {};
    if (GetModuleFileNameW(nullptr, executable, static_cast<DWORD>(_countof(executable))) == 0)
        return false;
    fs::path proxy_path = fs::path(executable).parent_path() / L"dxgi.dll";
    if (!fs::is_regular_file(proxy_path))
    {
        Log("[host] portable ReShade proxy is missing next to the host");
        return false;
    }
    g_reshade_proxy = LoadLibraryExW(proxy_path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (g_reshade_proxy == nullptr)
    {
        Log("[host] portable ReShade proxy load failed: Win32 %lu", GetLastError());
        return false;
    }
    wchar_t loaded[MAX_PATH] = {};
    GetModuleFileNameW(g_reshade_proxy, loaded, static_cast<DWORD>(_countof(loaded)));
    Log("[host] portable ReShade loaded: %ls", loaded);
    return true;
}

static void DumpD3DDebugMessages(const char *stage)
{
    if (g_d3d_info_queue == nullptr) return;
    const UINT64 count = g_d3d_info_queue->GetNumStoredMessagesAllowedByRetrievalFilter();
    for (UINT64 i = 0; i < count; ++i)
    {
        SIZE_T bytes = 0;
        if (FAILED(g_d3d_info_queue->GetMessage(i, nullptr, &bytes)) || bytes == 0) continue;
        std::vector<uint8_t> storage(bytes);
        auto *message = reinterpret_cast<D3D12_MESSAGE *>(storage.data());
        if (SUCCEEDED(g_d3d_info_queue->GetMessage(i, message, &bytes)))
            Log("[d3d12-debug] %s severity=%u id=%u %s", stage,
                static_cast<unsigned>(message->Severity), static_cast<unsigned>(message->ID),
                message->pDescription != nullptr ? message->pDescription : "<no description>");
    }
    g_d3d_info_queue->ClearStoredMessages();
}

static std::wstring FormatPreviewTime(double seconds)
{
    const uint64_t total = static_cast<uint64_t>(std::max(0.0, seconds));
    const uint64_t hours = total / 3600;
    const uint64_t minutes = (total / 60) % 60;
    const uint64_t secs = total % 60;
    wchar_t text[32] = {};
    if (hours > 0) swprintf_s(text, L"%llu:%02llu:%02llu", hours, minutes, secs);
    else swprintf_s(text, L"%02llu:%02llu", minutes, secs);
    return text;
}

static void PositionPreviewFps()
{
    if (h.hwnd == nullptr || g_preview_fps_window == nullptr) return;
    POINT origin = {16, 16};
    ClientToScreen(h.hwnd, &origin);
    SetWindowPos(g_preview_fps_window, HWND_TOP, origin.x, origin.y, 600, 82,
                 SWP_NOACTIVATE | (g_preview_window_revealed && g_preview_fps_visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
}

static void ShowPreviewFps(bool show)
{
    g_preview_fps_visible = show;
    if (g_preview_buttons[7] != nullptr)
        SetWindowTextW(g_preview_buttons[7], show ? L"Скрыть FPS" : L"Показать FPS");
    if (g_preview_fps_window != nullptr)
    {
        if (show) PositionPreviewFps();
        else ShowWindow(g_preview_fps_window, SW_HIDE);
    }
}

static void WritePreviewTelemetry()
{
    if (g_preview_telemetry_file.empty()) return;
    const fs::path temporary = g_preview_telemetry_file.wstring() + L".tmp";
    char line[512] = {};
    sprintf_s(line,
              "media_seconds=%.6f real_fps=%.4f display_fps=%.4f real_frames=%llu presented_frames=%llu generated_frames=%llu\n",
              CurrentPreviewSeconds(), g_preview_real_fps_live, g_preview_display_fps_live,
              static_cast<unsigned long long>(g_preview_real_total_frames),
              static_cast<unsigned long long>(g_preview_presented_total_frames),
              static_cast<unsigned long long>(g_preview_presented_total_frames - g_preview_real_total_frames));
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output) return;
        output << line;
        output.flush();
        if (!output) return;
    }
    MoveFileExW(temporary.c_str(), g_preview_telemetry_file.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

static bool ReadPreviewBufferStats(double &remaining_seconds, double &target_seconds,
                                   double &refill_fps, double &refill_realtime,
                                   int &paused, int &fill_on_pause, int &full, int &rebuffering)
{
    if (g_preview_control_file.empty()) return false;
    const fs::path state_file = g_preview_control_file.wstring() + L".buffer";
    std::ifstream input(state_file, std::ios::binary);
    if (!input) return false;
    std::string token;
    bool found_remaining = false;
    while (input >> token)
    {
        double value = 0.0;
        int flag = 0;
        if (sscanf_s(token.c_str(), "remaining_seconds=%lf", &value) == 1)
        {
            remaining_seconds = value;
            found_remaining = true;
        }
        else if (sscanf_s(token.c_str(), "target_seconds=%lf", &value) == 1) target_seconds = value;
        else if (sscanf_s(token.c_str(), "refill_fps=%lf", &value) == 1) refill_fps = value;
        else if (sscanf_s(token.c_str(), "refill_realtime=%lf", &value) == 1) refill_realtime = value;
        else if (sscanf_s(token.c_str(), "paused=%d", &flag) == 1) paused = flag;
        else if (sscanf_s(token.c_str(), "fill_on_pause=%d", &flag) == 1) fill_on_pause = flag;
        else if (sscanf_s(token.c_str(), "full=%d", &flag) == 1) full = flag;
        else if (sscanf_s(token.c_str(), "rebuffering=%d", &flag) == 1) rebuffering = flag;
    }
    return found_remaining;
}

static void UpdatePreviewPerformance(uint32_t presented_frames)
{
    const auto now = BatchClock::now();
    if (g_preview_fps_window_start.time_since_epoch().count() == 0)
        g_preview_fps_window_start = now;
    ++g_preview_real_window_frames;
    g_preview_presented_window_frames += std::max(1u, presented_frames);
    ++g_preview_real_total_frames;
    g_preview_presented_total_frames += std::max(1u, presented_frames);
    const double elapsed = std::chrono::duration<double>(now - g_preview_fps_window_start).count();
    if (elapsed < 0.5) return;
    g_preview_real_fps_live = g_preview_real_window_frames / elapsed;
    g_preview_display_fps_live = g_preview_presented_window_frames / elapsed;
    double buffer_remaining = 0.0, buffer_target = 0.0, refill_fps = 0.0, refill_realtime = 0.0;
    int paused = 0, fill_on_pause = 0, buffer_full = 0, rebuffering = 0;
    const bool has_buffer = ReadPreviewBufferStats(buffer_remaining, buffer_target, refill_fps,
                                                   refill_realtime, paused, fill_on_pause, buffer_full, rebuffering);
    wchar_t label[512] = {};
    if (has_buffer)
    {
        const wchar_t *buffer_state = rebuffering ? L"ожидание кадров" :
            (buffer_full ? L"полон" : (paused ? (fill_on_pause ? L"пауза + наполнение" : L"пауза") : L"пополняется"));
        swprintf_s(label,
                   L"Текущий FPS: %.1f   |   Реальный FPS: %.1f\nMFG: %llu сгенерировано\nБуфер: %.2f / %.2f сек · +%.1f FPS (%.2fx) · %ls",
                   g_preview_display_fps_live, g_preview_real_fps_live,
                   static_cast<unsigned long long>(g_preview_presented_total_frames - g_preview_real_total_frames),
                   buffer_remaining, buffer_target, refill_fps, refill_realtime, buffer_state);
    }
    else
    {
        swprintf_s(label, L"Текущий FPS: %.1f   |   Реальный FPS: %.1f\nMFG: %llu сгенерировано\nБуфер: подготовка телеметрии",
                   g_preview_display_fps_live, g_preview_real_fps_live,
                   static_cast<unsigned long long>(g_preview_presented_total_frames - g_preview_real_total_frames));
    }
    if (g_preview_fps_text != nullptr) SetWindowTextW(g_preview_fps_text, label);
    WritePreviewTelemetry();
    g_preview_real_window_frames = 0;
    g_preview_presented_window_frames = 0;
    g_preview_fps_window_start = now;
}

static void UpdatePreviewTimeline(uint64_t frame_index)
{
    g_preview_frame_index = frame_index;
    const double current = CurrentPreviewSeconds();
    if (g_preview_time_current != nullptr)
        SetWindowTextW(g_preview_time_current, FormatPreviewTime(current).c_str());
    if (g_preview_seekbar != nullptr && g_preview_media_duration_seconds > 0)
    {
        const int position = static_cast<int>(std::lround(
            10000.0 * std::clamp(current / g_preview_media_duration_seconds, 0.0, 1.0)));
        SendMessageW(g_preview_seekbar, TBM_SETPOS, TRUE, position);
    }
}

static void LayoutPreviewControls(HWND window)
{
    RECT client = {};
    GetClientRect(window, &client);
    const int count = 10;
    const int gap = 6;
    const int button_width = std::clamp((client.right - 16 - (count - 1) * gap) / count, 68L, 104L);
    const int button_height = 36;
    const int total_width = count * button_width + (count - 1) * gap;
    const int left = std::max(8L, (client.right - total_width) / 2L);
    const int top = std::max(8L, client.bottom - button_height - 12L);
    const int timeline_top = std::max(8, top - 40);
    const int time_width = 84;
    if (g_preview_time_current != nullptr)
        SetWindowPos(g_preview_time_current, HWND_TOP, 12, timeline_top + 6, time_width, 24, SWP_NOACTIVATE);
    if (g_preview_time_total != nullptr)
        SetWindowPos(g_preview_time_total, HWND_TOP, std::max(12L, client.right - time_width - 12L), timeline_top + 6,
                     time_width, 24, SWP_NOACTIVATE);
    if (g_preview_seekbar != nullptr)
        SetWindowPos(g_preview_seekbar, HWND_TOP, 12 + time_width, timeline_top,
                     std::max(80L, client.right - 2 * (12 + time_width)), 34, SWP_NOACTIVATE);
    for (int i = 0; i < count; ++i)
    {
        if (g_preview_buttons[i] == nullptr) continue;
        SetWindowPos(g_preview_buttons[i], HWND_TOP, left + i * (button_width + gap), top,
                     button_width, button_height, SWP_NOACTIVATE);
        ShowWindow(g_preview_buttons[i], g_preview_controls_visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    }
    for (HWND control : {g_preview_seekbar, g_preview_time_current, g_preview_time_total})
        if (control != nullptr) ShowWindow(control, g_preview_controls_visible ? SW_SHOWNOACTIVATE : SW_HIDE);
}

static void PositionPreviewControls()
{
    if (h.hwnd == nullptr || g_preview_controls_window == nullptr) return;
    RECT client = {};
    GetClientRect(h.hwnd, &client);
    POINT origin = { 0, 0 };
    ClientToScreen(h.hwnd, &origin);
    constexpr int overlay_height = 96;
    const int width = std::max(320L, client.right - client.left);
    const int height = static_cast<int>(std::min<long>(overlay_height, std::max(72L, client.bottom - client.top)));
    SetWindowPos(g_preview_controls_window, HWND_TOP, origin.x,
                 origin.y + std::max(0L, client.bottom - height), width, height,
                 SWP_NOACTIVATE | (g_preview_window_revealed && g_preview_controls_visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    LayoutPreviewControls(g_preview_controls_window);
    PositionPreviewFps();
}

static void ShowPreviewControls(bool show)
{
    g_preview_controls_visible = show;
    g_preview_control_activity = GetTickCount64();
    if (g_preview_controls_window != nullptr)
    {
        if (!g_preview_window_revealed)
        {
            ShowWindow(g_preview_controls_window, SW_HIDE);
            return;
        }
        if (show)
        {
            PositionPreviewControls();
            ShowWindow(g_preview_controls_window, SW_SHOWNOACTIVATE);
        }
        else ShowWindow(g_preview_controls_window, SW_HIDE);
    }
}

static void PositionPreviewFullscreen()
{
    if (h.hwnd == nullptr || !g_preview_window_revealed) return;
    MONITORINFO monitor = { sizeof(monitor) };
    GetMonitorInfoW(MonitorFromWindow(h.hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    const int monitor_width = monitor.rcMonitor.right - monitor.rcMonitor.left;
    const int monitor_height = monitor.rcMonitor.bottom - monitor.rcMonitor.top;
    if (g_preview_backdrop == nullptr)
    {
        g_preview_backdrop = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"dlss5feedhost", L"",
            WS_POPUP, monitor.rcMonitor.left, monitor.rcMonitor.top,
            monitor_width, monitor_height, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    }
    if (g_preview_backdrop != nullptr)
        SetWindowPos(g_preview_backdrop, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                     monitor_width, monitor_height, SWP_NOACTIVATE | SWP_SHOWWINDOW);

    const double fit = std::min(monitor_width / static_cast<double>(g_preview_width),
                                monitor_height / static_cast<double>(g_preview_height));
    const int width = std::max(320, static_cast<int>(std::lround(g_preview_width * fit)));
    const int height = std::max(180, static_cast<int>(std::lround(g_preview_height * fit)));
    const int x = monitor.rcMonitor.left + (monitor_width - width) / 2;
    const int y = monitor.rcMonitor.top + (monitor_height - height) / 2;
    SetWindowLongPtrW(h.hwnd, GWL_STYLE, WS_POPUP);
    SetWindowPos(h.hwnd, HWND_TOP, x, y, width, height, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    SetForegroundWindow(h.hwnd);
    SetFocus(h.hwnd);
}

static void RevealPreviewWindow()
{
    if (!g_preview_mode || !g_preview_direct || !g_show_window || g_preview_window_revealed || h.hwnd == nullptr)
        return;
    // The swap-chain is intentionally created and warmed while hidden.  A
    // fullscreen black HWND during depth/DLSS prebuffering looks exactly like a
    // failed MFG run.  Reveal only after a complete real frame has already been
    // copied and presented, so the first visible compositor surface is video.
    g_preview_window_revealed = true;
    if (g_preview_fullscreen) PositionPreviewFullscreen();
    else ShowWindow(h.hwnd, SW_SHOW);
    SetForegroundWindow(h.hwnd);
    SetFocus(h.hwnd);
    ShowPreviewControls(g_preview_controls_visible);
    PositionPreviewFps();
    printf("HOST_PREVIEW_VISIBLE first_frame=1\n");
    fflush(stdout);
}

static void TogglePreviewFullscreen(bool fullscreen)
{
    if (h.hwnd == nullptr || fullscreen == g_preview_fullscreen) return;
    SuspendStreamlineFrameGeneration("fullscreen transition");
    if (fullscreen)
    {
        GetWindowRect(h.hwnd, &g_preview_windowed_rect);
        PositionPreviewFullscreen();
    }
    else
    {
        if (g_preview_backdrop != nullptr) ShowWindow(g_preview_backdrop, SW_HIDE);
        SetWindowLongPtrW(h.hwnd, GWL_STYLE, WS_POPUP);
        SetWindowPos(h.hwnd, HWND_TOP, g_preview_windowed_rect.left, g_preview_windowed_rect.top,
                     g_preview_windowed_rect.right - g_preview_windowed_rect.left,
                     g_preview_windowed_rect.bottom - g_preview_windowed_rect.top,
                     SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    }
    g_preview_fullscreen = fullscreen;
    if (g_preview_buttons[6] != nullptr)
        SetWindowTextW(g_preview_buttons[6], fullscreen ? L"В окно" : L"Во весь экран");
    ShowPreviewControls(true);
    PositionPreviewFps();
}

static bool WritePreviewControl(const char *command)
{
    if (g_preview_event_file.empty()) return false;
    // Native player events are an append-only queue.  A single shared mailbox
    // lost PLAYING/BUFFER_READY whenever two events arrived inside the
    // controller's polling interval, which in turn left audio stopped after a
    // short underrun.  User commands travel in the separate control file.
    std::ofstream control(g_preview_event_file, std::ios::binary | std::ios::app);
    if (!control) return false;
    control << command << "\n";
    control.flush();
    return static_cast<bool>(control);
}

static void RequestPreviewSeek(double delta_seconds)
{
    const double target = std::clamp(CurrentPreviewSeconds() + delta_seconds, 0.0,
                                     std::max(0.0, g_preview_media_duration_seconds - 0.05));
    char command[96] = {};
    sprintf_s(command, "SEEK %.6f", target);
    if (WritePreviewControl(command))
    {
        g_preview_paused = true; // hold the current frame until the controller relaunches us
        SetWindowTextW(g_preview_buttons[2], L"Продолжить");
        ShowPreviewControls(true);
    }
}

static void RequestPreviewSeekAbsolute(double target)
{
    target = std::clamp(target, 0.0, std::max(0.0, g_preview_media_duration_seconds - 0.05));
    char command[96] = {};
    sprintf_s(command, "SEEK %.6f", target);
    if (WritePreviewControl(command))
    {
        g_preview_paused = true;
        SetWindowTextW(g_preview_buttons[2], L"Продолжить");
        ShowPreviewControls(true);
    }
}

static void TogglePreviewPause()
{
    g_preview_paused = !g_preview_paused;
    if (g_preview_paused) SuspendStreamlineFrameGeneration("pause");
    else if (g_streamline_fg_requested) g_streamline_fg_activate_after_present = true;
    if (g_preview_buttons[2] != nullptr)
        SetWindowTextW(g_preview_buttons[2], g_preview_paused ? L"Продолжить" : L"Пауза");
    char command[96] = {};
    sprintf_s(command, "%s %.6f", g_preview_paused ? "PAUSE" : "RESUME", CurrentPreviewSeconds());
    WritePreviewControl(command);
    ShowPreviewControls(true);
}

static void TogglePreviewMute()
{
    g_preview_muted = !g_preview_muted;
    if (g_preview_buttons[5] != nullptr)
        SetWindowTextW(g_preview_buttons[5], g_preview_muted ? L"Включить звук" : L"Без звука");
    char command[96] = {};
    sprintf_s(command, "%s %.6f", g_preview_muted ? "MUTE" : "UNMUTE", CurrentPreviewSeconds());
    WritePreviewControl(command);
    ShowPreviewControls(true);
}

static void CreatePreviewControls(HWND parent)
{
    g_preview_controls_window = CreateWindowExW(
        WS_EX_TOOLWINDOW, L"dlss5feedhost", L"Управление DLSS5-плеером",
        WS_POPUP | WS_CLIPCHILDREN, 0, 0, 960, 96, parent, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (g_preview_controls_window == nullptr) return;
    const wchar_t *labels[] = { L"-5 мин", L"-10 сек", L"Пауза", L"+10 сек", L"+5 мин", L"Без звука",
                                L"Во весь экран", L"Показать FPS", L"Скрыть меню", L"Закрыть" };
    const int ids[] = { IDC_SEEK_BACK_BIG, IDC_SEEK_BACK, IDC_PAUSE, IDC_SEEK_FORWARD,
                        IDC_SEEK_FORWARD_BIG, IDC_MUTE, IDC_FULLSCREEN, IDC_TOGGLE_FPS,
                        IDC_HIDE_MENU, IDC_CLOSE_PLAYER };
    HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
    for (int i = 0; i < 10; ++i)
    {
        g_preview_buttons[i] = CreateWindowExW(0, L"BUTTON", labels[i],
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
            0, 0, 98, 38, g_preview_controls_window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(ids[i])),
            GetModuleHandleW(nullptr), nullptr);
        if (g_preview_buttons[i] != nullptr)
            SendMessageW(g_preview_buttons[i], WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    }
    g_preview_time_current = CreateWindowExW(0, L"STATIC", L"00:00", WS_CHILD | WS_VISIBLE | SS_CENTER,
        0, 0, 84, 24, g_preview_controls_window, nullptr, GetModuleHandleW(nullptr), nullptr);
    g_preview_time_total = CreateWindowExW(0, L"STATIC", FormatPreviewTime(g_preview_media_duration_seconds).c_str(),
        WS_CHILD | WS_VISIBLE | SS_CENTER, 0, 0, 84, 24, g_preview_controls_window, nullptr, GetModuleHandleW(nullptr), nullptr);
    g_preview_seekbar = CreateWindowExW(0, TRACKBAR_CLASSW, L"", WS_CHILD | WS_VISIBLE | TBS_HORZ | TBS_NOTICKS,
        0, 0, 400, 34, g_preview_controls_window, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (g_preview_seekbar != nullptr) SendMessageW(g_preview_seekbar, TBM_SETRANGE, TRUE, MAKELPARAM(0, 10000));
    for (HWND label : {g_preview_time_current, g_preview_time_total})
        if (label != nullptr) SendMessageW(label, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);

    g_preview_fps_window = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"dlss5feedhost", L"FPS",
        WS_POPUP | WS_CLIPCHILDREN, 0, 0, 600, 82, parent, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (g_preview_fps_window != nullptr)
    {
        g_preview_fps_text = CreateWindowExW(0, L"STATIC",
            L"Текущий FPS: —   |   Реальный FPS: —\nMFG: ожидание кадров\nБуфер: подготовка телеметрии",
            WS_CHILD | WS_VISIBLE | SS_LEFT, 12, 8, 576, 68, g_preview_fps_window,
            nullptr, GetModuleHandleW(nullptr), nullptr);
        if (g_preview_fps_text != nullptr)
            SendMessageW(g_preview_fps_text, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    }
    PositionPreviewControls();
    ShowPreviewControls(true);
    ShowPreviewFps(false);
}

static LRESULT CALLBACK WndProc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    if (g_preview_mode && g_preview_direct)
    {
        switch (m)
        {
        case WM_SIZE:
            if (w == h.hwnd) { PositionPreviewControls(); PositionPreviewFps(); }
            else if (w == g_preview_controls_window) LayoutPreviewControls(w);
            return 0;
        case WM_MOUSEMOVE:
            if (!g_preview_controls_visible && !g_preview_controls_manually_hidden) ShowPreviewControls(true);
            else g_preview_control_activity = GetTickCount64();
            break;
        case WM_LBUTTONDBLCLK:
            TogglePreviewFullscreen(!g_preview_fullscreen);
            return 0;
        case WM_SYSKEYDOWN:
            if (wp == VK_RETURN && (GetKeyState(VK_MENU) & 0x8000))
            {
                TogglePreviewFullscreen(!g_preview_fullscreen);
                return 0;
            }
            break;
        case WM_HSCROLL:
            if (reinterpret_cast<HWND>(lp) == g_preview_seekbar && g_preview_media_duration_seconds > 0)
            {
                const int code = LOWORD(wp);
                const int position = static_cast<int>(SendMessageW(g_preview_seekbar, TBM_GETPOS, 0, 0));
                const double target = g_preview_media_duration_seconds * position / 10000.0;
                if (g_preview_time_current != nullptr)
                    SetWindowTextW(g_preview_time_current, FormatPreviewTime(target).c_str());
                if (code == TB_ENDTRACK || code == TB_THUMBPOSITION)
                    RequestPreviewSeekAbsolute(target);
                return 0;
            }
            break;
        case WM_CTLCOLORSTATIC:
            SetTextColor(reinterpret_cast<HDC>(wp), RGB(235, 242, 250));
            SetBkColor(reinterpret_cast<HDC>(wp), RGB(8, 12, 18));
            return reinterpret_cast<LRESULT>(GetStockObject(BLACK_BRUSH));
        case WM_KEYDOWN:
        {
            const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
            const bool control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
            if (wp == VK_F11) { TogglePreviewFullscreen(!g_preview_fullscreen); return 0; }
            if (wp == VK_F1 || wp == VK_TAB)
            {
                g_preview_controls_manually_hidden = g_preview_controls_visible;
                ShowPreviewControls(!g_preview_controls_visible);
                return 0;
            }
            if (wp == VK_F2) { ShowPreviewFps(!g_preview_fps_visible); return 0; }
            if (wp == VK_SPACE) { TogglePreviewPause(); return 0; }
            if (wp == VK_LEFT) { RequestPreviewSeek(shift ? -300.0 : (control ? -60.0 : -10.0)); return 0; }
            if (wp == VK_RIGHT) { RequestPreviewSeek(shift ? 300.0 : (control ? 60.0 : 10.0)); return 0; }
            if (wp == VK_PRIOR) { RequestPreviewSeek(-300.0); return 0; }
            if (wp == VK_NEXT) { RequestPreviewSeek(300.0); return 0; }
            if (wp == VK_ESCAPE)
            {
                if (g_preview_fullscreen) TogglePreviewFullscreen(false);
                else WritePreviewControl("CLOSE");
                return 0;
            }
            break;
        }
        case WM_COMMAND:
            SetFocus(w); // button clicks must not steal the keyboard shortcuts
            switch (LOWORD(wp))
            {
            case IDC_SEEK_BACK_BIG: RequestPreviewSeek(-300.0); return 0;
            case IDC_SEEK_BACK: RequestPreviewSeek(-10.0); return 0;
            case IDC_PAUSE: TogglePreviewPause(); return 0;
            case IDC_SEEK_FORWARD: RequestPreviewSeek(10.0); return 0;
            case IDC_SEEK_FORWARD_BIG: RequestPreviewSeek(300.0); return 0;
            case IDC_MUTE: TogglePreviewMute(); return 0;
            case IDC_FULLSCREEN: TogglePreviewFullscreen(!g_preview_fullscreen); return 0;
            case IDC_TOGGLE_FPS: ShowPreviewFps(!g_preview_fps_visible); return 0;
            case IDC_HIDE_MENU:
                g_preview_controls_manually_hidden = true;
                ShowPreviewControls(false);
                return 0;
            case IDC_CLOSE_PLAYER: WritePreviewControl("CLOSE"); return 0;
            default: break;
            }
            break;
        case WM_CLOSE:
            WritePreviewControl("CLOSE");
            return 0;
        default: break;
        }
    }
    if (m == WM_CLOSE) { ShowWindow(w, SW_HIDE); return 0; }
    return DefWindowProcW(w, m, wp, lp);
}

// --- banner: "32-bit DLSS 5 Feeder" rendered once with GDI, copied into every frame ---

static ID3D12Resource             *g_banner;
static IDXGISwapChain3            *g_swap3;
static ID3D12CommandAllocator     *g_pump_alloc;
static ID3D12GraphicsCommandList  *g_pump_list;
static ID3D12Fence                *g_pump_fence;
static UINT64                      g_pump_val;
static HANDLE                      g_pump_ev;
static ID3D12Resource             *g_preview_upload;
static UINT                        g_preview_pitch;

static bool BeginCommands();
static UINT64 EndCommands();
static bool WaitFenceValue(ID3D12Fence *f, UINT64 v, DWORD ms);

static void InitPumpObjects()
{
    if (g_pump_alloc != nullptr) return;
    h.dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator),
                                  reinterpret_cast<void **>(&g_pump_alloc));
    if (g_pump_alloc != nullptr)
        h.dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, g_pump_alloc, nullptr,
                                 __uuidof(ID3D12GraphicsCommandList), reinterpret_cast<void **>(&g_pump_list));
    if (g_pump_list != nullptr) g_pump_list->Close();
    h.dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), reinterpret_cast<void **>(&g_pump_fence));
    g_pump_ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    h.swap->QueryInterface(__uuidof(IDXGISwapChain3), reinterpret_cast<void **>(&g_swap3));

    if (g_preview_mode)
    {
        g_preview_pitch = (g_preview_width * 4 + 255u) & ~255u;
        D3D12_HEAP_PROPERTIES hp = {};
        hp.Type = D3D12_HEAP_TYPE_UPLOAD;
        D3D12_RESOURCE_DESC bd = {};
        bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        bd.Width = static_cast<UINT64>(g_preview_pitch) * g_preview_height;
        bd.Height = 1;
        bd.DepthOrArraySize = 1;
        bd.MipLevels = 1;
        bd.SampleDesc.Count = 1;
        bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        h.dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ,
                                       nullptr, __uuidof(ID3D12Resource), reinterpret_cast<void **>(&g_preview_upload));
    }
}

static void InitBanner()
{
    const int W = 960, H = 540;

    // 1. Render the text with GDI into a 32-bit DIB.
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize        = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth       = W;
    bi.bmiHeader.biHeight      = -H;   // top-down
    bi.bmiHeader.biPlanes      = 1;
    bi.bmiHeader.biBitCount    = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HDC dc = CreateCompatibleDC(nullptr);
    HBITMAP bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (dc == nullptr || bmp == nullptr || bits == nullptr) return;
    HGDIOBJ old_bmp = SelectObject(dc, bmp);

    RECT full = { 0, 0, W, H };
    HBRUSH bg = CreateSolidBrush(RGB(18, 18, 22));
    FillRect(dc, &full, bg);
    DeleteObject(bg);
    SetBkMode(dc, TRANSPARENT);

    HFONT fnt_big   = CreateFontW(64, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0,
                                  CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    HFONT fnt_small = CreateFontW(26, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0,
                                  CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    HGDIOBJ old_font = SelectObject(dc, fnt_big);
    SetTextColor(dc, RGB(118, 185, 0));
    RECT r1 = { 0, 150, W, 240 };
    DrawTextW(dc, L"32-bit DLSS 5 Feeder", -1, &r1, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
    SelectObject(dc, fnt_small);
    SetTextColor(dc, RGB(200, 200, 205));
    RECT r2 = { 0, 260, W, 300 };
    DrawTextW(dc, L"DLSS 5 neural rendering runs here for your 32-bit game.", -1, &r2,
              DT_CENTER | DT_SINGLELINE | DT_VCENTER);
    RECT r3 = { 0, 305, W, 345 };
    DrawTextW(dc, L"Press  Home  in this window to tune it  \x2022  closing only hides the window", -1, &r3,
              DT_CENTER | DT_SINGLELINE | DT_VCENTER);
    SelectObject(dc, old_font);
    DeleteObject(fnt_big);
    DeleteObject(fnt_small);
    GdiFlush();

    // 2. Upload it (BGRA -> RGBA) and keep it as a copy source.
    D3D12_HEAP_PROPERTIES up = {};
    up.Type = D3D12_HEAP_TYPE_UPLOAD;
    const UINT pitch = (W * 4 + 255) & ~255u;
    D3D12_RESOURCE_DESC bd = {};
    bd.Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER;
    bd.Width            = static_cast<UINT64>(pitch) * H;
    bd.Height           = 1;
    bd.DepthOrArraySize = 1;
    bd.MipLevels        = 1;
    bd.SampleDesc.Count = 1;
    bd.Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource *staging = nullptr;
    D3D12_HEAP_PROPERTIES def = {};
    def.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC td = {};
    td.Dimension        = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width            = W;
    td.Height           = H;
    td.DepthOrArraySize = 1;
    td.MipLevels        = 1;
    td.Format           = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Layout           = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    if (FAILED(h.dev->CreateCommittedResource(&up, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ,
                                              nullptr, __uuidof(ID3D12Resource), reinterpret_cast<void **>(&staging))) ||
        FAILED(h.dev->CreateCommittedResource(&def, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_COPY_DEST,
                                              nullptr, __uuidof(ID3D12Resource), reinterpret_cast<void **>(&g_banner))))
    { SelectObject(dc, old_bmp); DeleteObject(bmp); DeleteDC(dc); return; }

    BYTE *dst = nullptr;
    staging->Map(0, nullptr, reinterpret_cast<void **>(&dst));
    const BYTE *srcp = static_cast<const BYTE *>(bits);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x)
        {
            const BYTE *p = srcp + (static_cast<size_t>(y) * W + x) * 4;   // GDI: BGRA
            BYTE *q = dst + static_cast<size_t>(y) * pitch + static_cast<size_t>(x) * 4;
            q[0] = p[2]; q[1] = p[1]; q[2] = p[0]; q[3] = 0xFF;
        }
    staging->Unmap(0, nullptr);
    SelectObject(dc, old_bmp);
    DeleteObject(bmp);
    DeleteDC(dc);

    if (BeginCommands())
    {
        D3D12_TEXTURE_COPY_LOCATION src = {}, dcl = {};
        src.pResource = staging;
        src.Type      = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src.PlacedFootprint.Footprint.Format   = DXGI_FORMAT_R8G8B8A8_UNORM;
        src.PlacedFootprint.Footprint.Width    = W;
        src.PlacedFootprint.Footprint.Height   = H;
        src.PlacedFootprint.Footprint.Depth    = 1;
        src.PlacedFootprint.Footprint.RowPitch = pitch;
        dcl.pResource = g_banner;
        dcl.Type      = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        h.list->CopyTextureRegion(&dcl, 0, 0, 0, &src, nullptr);
        D3D12_RESOURCE_BARRIER b = {};
        b.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition.pResource   = g_banner;
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
        b.Transition.StateAfter  = D3D12_RESOURCE_STATE_COPY_SOURCE;
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        h.list->ResourceBarrier(1, &b);
        const UINT64 v = EndCommands();
        WaitFenceValue(h.fence, v, 2000);
    }
    staging->Release();

    // 3. A tiny allocator/list/fence pair on the pump queue for the per-frame copy.
    InitPumpObjects();
    Log("[host] banner ready");
}

typedef HRESULT (WINAPI *PFN_D3D12CreateDevice_)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
typedef HRESULT (WINAPI *PFN_CreateDXGIFactory2_)(UINT, REFIID, void **);

static bool InitStreamline()
{
    wchar_t executable[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, executable, MAX_PATH);
    fs::path root = fs::path(executable).parent_path();
    const wchar_t *plugin_paths[] = {root.c_str()};
    const sl::Feature features[] = {sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL};
    sl::Preferences preferences{};
    preferences.renderAPI = sl::RenderAPI::eD3D12;
    // Preferences default to OTA opt-in.  Assign (rather than OR) the exact
    // integration flags so the 2.12.129 driver-cache plugins cannot replace
    // selected members of the portable 2.12.0 runtime.  Mixing those builds
    // left the async DLSS-G swap-chain in DXGI_ERROR_INVALID_CALL after its
    // first frame on the RTX 5080.
    preferences.flags = sl::PreferenceFlags::eUseManualHooking;
    // ReShade is an injected DXGI layer in this host.  Use an actual factory
    // proxy instead of patching the third-party factory v-table in place.
    preferences.flags |= sl::PreferenceFlags::eUseDXGIFactoryProxy;
    preferences.flags |= sl::PreferenceFlags::eUseFrameBasedResourceTagging;
    preferences.featuresToLoad = features;
    preferences.numFeaturesToLoad = static_cast<uint32_t>(_countof(features));
    preferences.projectId = "a0f57b54-1daf-4934-90ae-c4035c19df04";
    preferences.engine = sl::EngineType::eCustom;
    preferences.engineVersion = "DLSS5 Video Studio V11";
    preferences.pathsToPlugins = plugin_paths;
    preferences.numPathsToPlugins = 1;
    preferences.pathToLogsAndData = root.c_str();
    preferences.logLevel = sl::LogLevel::eDefault;
    const sl::Result result = slInit(preferences);
    Log("[streamline] slInit -> %d", static_cast<int>(result));
    g_streamline_initialized = result == sl::Result::eOk;
    return g_streamline_initialized;
}

static bool UpgradeStreamlineInterface(void **object, const char *label)
{
    const sl::Result result = slUpgradeInterface(object);
    Log("[streamline] upgrade %s -> %d", label, static_cast<int>(result));
    return result == sl::Result::eOk && *object != nullptr;
}

static sl::float4x4 StreamlineIdentity()
{
    sl::float4x4 matrix{};
    matrix[0] = sl::float4(1.0f, 0.0f, 0.0f, 0.0f);
    matrix[1] = sl::float4(0.0f, 1.0f, 0.0f, 0.0f);
    matrix[2] = sl::float4(0.0f, 0.0f, 1.0f, 0.0f);
    matrix[3] = sl::float4(0.0f, 0.0f, 0.0f, 1.0f);
    return matrix;
}

static void StreamlineAPIError(const sl::APIError &error)
{
    InterlockedExchange(&g_streamline_api_error, static_cast<LONG>(error.hres));
}

static bool EnableStreamlineFrameGeneration(UINT render_width, UINT render_height,
                                             UINT output_width, UINT output_height,
                                             bool dynamic_mfg,
                                             uint32_t generated_frames,
                                             uint32_t dynamic_target_fps)
{
    if (!g_streamline_initialized) return false;
    sl::ReflexOptions reflex{};
    reflex.mode = sl::ReflexMode::eLowLatency;
    // This host is a single-stage video renderer.  It cannot overlap a game
    // simulation stage with render submission like a conventional engine, so
    // Reflex marker-based queue optimization is not applicable here.  Enabling
    // it made the driver wait on an uninitialised (zero) internal fence after
    // the first DLSS-G Present, after which the swap-chain returned
    // DXGI_ERROR_INVALID_CALL and remained black.
    reflex.useMarkersToOptimize = false;
    const sl::Result reflex_result = slReflexSetOptions(reflex);

    sl::DLSSGOptions options{};
    options.mode = dynamic_mfg ? sl::DLSSGMode::eDynamic : sl::DLSSGMode::eOn;
    options.numFramesToGenerate = std::clamp(generated_frames, 1u, 5u);
    options.dynamicTargetFrameRate = static_cast<float>(dynamic_target_fps);
    options.onErrorCallback = StreamlineAPIError;
    options.numBackBuffers = 3;
    options.mvecDepthWidth = render_width;
    options.mvecDepthHeight = render_height;
    options.colorWidth = output_width;
    options.colorHeight = output_height;
    options.colorBufferFormat = static_cast<uint32_t>(DXGI_FORMAT_R8G8B8A8_UNORM);
    options.mvecBufferFormat = static_cast<uint32_t>(DXGI_FORMAT_R16G16_FLOAT);
    options.depthBufferFormat = static_cast<uint32_t>(DXGI_FORMAT_R32_FLOAT);
    options.hudLessBufferFormat = static_cast<uint32_t>(DXGI_FORMAT_R8G8B8A8_UNORM);
    sl::DLSSGState state{};
    const sl::Result capability_result = slDLSSGGetState(g_streamline_viewport, state, &options);
    const bool dynamic_supported = state.bIsDynamicMFGSupported == sl::Boolean::eTrue;
    if (capability_result != sl::Result::eOk)
    {
        Log("[streamline] DLSSG capability query failed: %d", static_cast<int>(capability_result));
        return false;
    }
    if (dynamic_mfg && !dynamic_supported)
    {
        Log("[streamline] Dynamic MFG target %u FPS requested but unsupported (max_generated=%u)",
            dynamic_target_fps, state.numFramesToGenerateMax);
        fprintf(stderr, "HOST_DLSSG_UNSUPPORTED dynamic=1 target_fps=%u max_generated=%u\n",
                dynamic_target_fps, state.numFramesToGenerateMax);
        return false;
    }
    if (!dynamic_mfg && options.numFramesToGenerate > state.numFramesToGenerateMax)
    {
        Log("[streamline] fixed MFG x%u requested but this system supports at most x%u",
            options.numFramesToGenerate + 1, state.numFramesToGenerateMax + 1);
        fprintf(stderr, "HOST_DLSSG_UNSUPPORTED requested_generated=%u max_generated=%u\n",
                options.numFramesToGenerate, state.numFramesToGenerateMax);
        return false;
    }
    // Keep FG off until the first complete game frame has valid constants,
    // depth, motion and HUD-less color.  Enabling it while the realtime guide
    // queue is still prebuffering lets the Streamline swapchain interpolate
    // the empty startup Presents, which produces a persistent black surface on
    // some drivers.
    const sl::Result options_result = slDLSSGSetOptions(g_streamline_viewport, options);
    const sl::Result state_result = slDLSSGGetState(g_streamline_viewport, state, &options);
    Log("[streamline] Reflex=%d DLSSG staged=%d state=%d mode=%s target_fps=%u status=%u min=%u max_generated=%u dynamic=%d vram_mb=%llu",
        static_cast<int>(reflex_result), static_cast<int>(options_result), static_cast<int>(state_result),
        dynamic_mfg ? "dynamic" : "fixed", dynamic_target_fps,
        static_cast<unsigned>(state.status), state.minWidthOrHeight, state.numFramesToGenerateMax,
        state.bIsDynamicMFGSupported == sl::Boolean::eTrue ? 1 : 0,
        static_cast<unsigned long long>(state.estimatedVRAMUsageInBytes / (1024 * 1024)));
    printf("HOST_DLSSG_READY mode=%s generated=%u multiplier=%u target_fps=%u max_generated=%u dynamic_supported=%u\n",
           dynamic_mfg ? "dynamic" : "fixed", options.numFramesToGenerate,
           options.numFramesToGenerate + 1, dynamic_target_fps, state.numFramesToGenerateMax,
           state.bIsDynamicMFGSupported == sl::Boolean::eTrue ? 1u : 0u);
    fflush(stdout);
    g_streamline_requested_options = options;
    g_streamline_fg_requested = reflex_result == sl::Result::eOk &&
                                options_result == sl::Result::eOk && state_result == sl::Result::eOk;
    g_streamline_fg_enabled = g_streamline_fg_requested;
    g_streamline_fg_activate_after_present = false;
    return g_streamline_fg_requested;
}

static bool ActivateStreamlineFrameGeneration()
{
    if (!g_streamline_fg_requested || g_streamline_fg_enabled || g_preview_paused) return false;
    const sl::Result options_result = slDLSSGSetOptions(g_streamline_viewport, g_streamline_requested_options);
    sl::DLSSGState state{};
    const sl::Result state_result = slDLSSGGetState(g_streamline_viewport, state, &g_streamline_requested_options);
    g_streamline_fg_enabled = options_result == sl::Result::eOk && state_result == sl::Result::eOk;
    g_streamline_fg_activate_after_present = !g_streamline_fg_enabled;
    Log("[streamline] activation options=%d state=%d enabled=%d status=%u",
        static_cast<int>(options_result), static_cast<int>(state_result),
        g_streamline_fg_enabled ? 1 : 0, static_cast<unsigned>(state.status));
    if (g_streamline_fg_enabled)
    {
        printf("HOST_DLSSG_ACTIVE mode=%s target_fps=%.0f\n",
               g_streamline_requested_options.mode == sl::DLSSGMode::eDynamic ? "dynamic" : "fixed",
               g_streamline_requested_options.dynamicTargetFrameRate);
        fflush(stdout);
    }
    return g_streamline_fg_enabled;
}

static void SuspendStreamlineFrameGeneration(const char *reason)
{
    if (!g_streamline_fg_requested) return;
    if (g_streamline_fg_enabled)
    {
        sl::DLSSGOptions disabled_options = g_streamline_requested_options;
        disabled_options.mode = sl::DLSSGMode::eOff;
        const sl::Result result = slDLSSGSetOptions(g_streamline_viewport, disabled_options);
        Log("[streamline] suspended for %s -> %d", reason, static_cast<int>(result));
        // SetOptions is consumed by the next Present.  Commit the off state
        // before changing window mode or holding a paused frame, as required by
        // the DLSS-G DXGI integration contract.
        if (result == sl::Result::eOk && h.swap != nullptr) h.swap->Present(1, 0);
    }
    g_streamline_fg_enabled = false;
    g_streamline_fg_activate_after_present = true;
    g_streamline_last_present_count = 1;
}

static bool PrepareStreamlineFrame(ID3D12Resource *hudless, ID3D12Resource *depth,
                                   ID3D12Resource *motion, UINT render_width, UINT render_height,
                                   UINT output_width, UINT output_height, bool reset,
                                   sl::FrameToken *&token)
{
    token = nullptr;
    if (!g_streamline_fg_requested || hudless == nullptr || depth == nullptr || motion == nullptr)
        return false;
    const uint32_t frame_index = static_cast<uint32_t>(g_streamline_frame_index++);
    if (slGetNewFrameToken(token, &frame_index) != sl::Result::eOk || token == nullptr) return false;

    slReflexSleep(*token);
    slPCLSetMarker(sl::PCLMarker::eSimulationStart, *token);
    slPCLSetMarker(sl::PCLMarker::eSimulationEnd, *token);
    slPCLSetMarker(sl::PCLMarker::eRenderSubmitStart, *token);
    slPCLSetMarker(sl::PCLMarker::eRenderSubmitEnd, *token);

    sl::Constants constants{};
    constants.cameraViewToClip = StreamlineIdentity();
    constants.clipToCameraView = StreamlineIdentity();
    constants.clipToLensClip = StreamlineIdentity();
    constants.clipToPrevClip = StreamlineIdentity();
    constants.prevClipToClip = StreamlineIdentity();
    constants.jitterOffset = sl::float2(0.0f, 0.0f);
    constants.mvecScale = sl::float2(1.0f / static_cast<float>(render_width),
                                    1.0f / static_cast<float>(render_height));
    constants.cameraPinholeOffset = sl::float2(0.0f, 0.0f);
    constants.cameraPos = sl::float3(0.0f, 0.0f, 0.0f);
    constants.cameraUp = sl::float3(0.0f, 1.0f, 0.0f);
    constants.cameraRight = sl::float3(1.0f, 0.0f, 0.0f);
    constants.cameraFwd = sl::float3(0.0f, 0.0f, 1.0f);
    constants.cameraNear = 0.1f;
    constants.cameraFar = 1000.0f;
    constants.cameraFOV = 1.57079632679f;
    constants.cameraAspectRatio = static_cast<float>(render_width) / static_cast<float>(render_height);
    constants.motionVectorsInvalidValue = 0.0f;
    constants.depthInverted = sl::Boolean::eTrue;
    constants.cameraMotionIncluded = sl::Boolean::eTrue;
    constants.motionVectors3D = sl::Boolean::eFalse;
    constants.reset = reset ? sl::Boolean::eTrue : sl::Boolean::eFalse;
    constants.orthographicProjection = sl::Boolean::eFalse;
    constants.motionVectorsDilated = sl::Boolean::eTrue;
    constants.motionVectorsJittered = sl::Boolean::eFalse;
    if (slSetConstants(constants, *token, g_streamline_viewport) != sl::Result::eOk) return false;

    sl::Extent render_extent{0, 0, render_width, render_height};
    sl::Extent output_extent{0, 0, output_width, output_height};
    sl::Resource depth_resource{sl::ResourceType::eTex2d, depth, nullptr, nullptr,
                                static_cast<uint32_t>(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)};
    sl::Resource motion_resource{sl::ResourceType::eTex2d, motion, nullptr, nullptr,
                                 static_cast<uint32_t>(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)};
    // Final color is intercepted from the proxy swap-chain automatically.  The
    // HUD-less input must stay a separate scene-color resource; aliasing it to
    // the proxy backbuffer makes DLSS-G sample its own off-screen presentation
    // surface and can yield an all-black generated surface on recent drivers.
    sl::Resource hudless_resource{sl::ResourceType::eTex2d, hudless, nullptr, nullptr,
                                  static_cast<uint32_t>(D3D12_RESOURCE_STATE_UNORDERED_ACCESS)};
    sl::ResourceTag tags[] = {
        sl::ResourceTag{&depth_resource, sl::kBufferTypeDepth, sl::ResourceLifecycle::eValidUntilPresent, &render_extent},
        sl::ResourceTag{&motion_resource, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilPresent, &render_extent},
        sl::ResourceTag{&hudless_resource, sl::kBufferTypeHUDLessColor, sl::ResourceLifecycle::eValidUntilPresent, &output_extent},
        // The resource pointer is intentionally null because SL intercepts the
        // final color itself.  Supplying the explicit full-frame extent avoids
        // the 310.7 runtime's zero-extent path on proxy swap-chains.
        sl::ResourceTag{nullptr, sl::kBufferTypeBackbuffer, sl::ResourceLifecycle::eValidUntilPresent, &output_extent},
    };
    return slSetTagForFrame(*token, g_streamline_viewport, tags, static_cast<uint32_t>(_countof(tags)), nullptr) ==
           sl::Result::eOk;
}

static bool PresentStreamlineFrame(sl::FrameToken *token)
{
    g_streamline_last_present_count = 1;
    if (token != nullptr) slPCLSetMarker(sl::PCLMarker::ePresentStart, *token);
    // The display-only player is paced to the source clock and targets a
    // compositor-backed window.  A tearing-style SyncInterval=0 caused the
    // DLSS-G async pacer to reject its second Present with
    // DXGI_ERROR_INVALID_CALL on the RTX 5080.  SyncInterval=1 is also the
    // correct contract for x2 generation from a 30-fps real-frame stream to a
    // 60-Hz presentation stream.
    const HRESULT present_result = h.swap->Present(1, 0);
    g_streamline_last_present_hresult = present_result;
    if (FAILED(present_result))
        Log("[streamline] Present failed 0x%08X", static_cast<unsigned>(present_result));
    if (g_d3d_debug_enabled) DumpD3DDebugMessages("Present");
    const HRESULT api_error = static_cast<HRESULT>(InterlockedExchange(&g_streamline_api_error, S_OK));
    if (FAILED(api_error)) Log("[streamline] asynchronous DXGI callback 0x%08X", static_cast<unsigned>(api_error));
    if (token != nullptr) slPCLSetMarker(sl::PCLMarker::ePresentEnd, *token);
    if (token != nullptr)
    {
        sl::DLSSGState state{};
        if (slDLSSGGetState(g_streamline_viewport, state, nullptr) == sl::Result::eOk)
        {
            g_streamline_last_present_count = std::max(1u, state.numFramesActuallyPresented);
            // This host reuses its color/depth/motion allocations every frame.
            // Serialize the next client submission behind DLSS-G's input-copy
            // completion fence; otherwise frame 0 succeeds and frame 1 races
            // those same resources, causing PresentBefore to return
            // DXGI_ERROR_INVALID_CALL and leaving the swap-chain black.
            if (state.inputsProcessingCompletionFence != nullptr &&
                state.lastPresentInputsProcessingCompletionFenceValue > 0 && h.fence_event != nullptr)
            {
                auto *inputs_fence = static_cast<ID3D12Fence *>(state.inputsProcessingCompletionFence);
                const UINT64 input_value = state.lastPresentInputsProcessingCompletionFenceValue;
                if (inputs_fence->GetCompletedValue() < input_value)
                {
                    const HRESULT event_result = inputs_fence->SetEventOnCompletion(input_value, h.fence_event);
                    if (FAILED(event_result) || WaitForSingleObject(h.fence_event, 1000) != WAIT_OBJECT_0)
                        Log("[streamline] input completion CPU wait failed value=%llu hr=0x%08X",
                            static_cast<unsigned long long>(input_value), static_cast<unsigned>(event_result));
                }
            }
            if (g_streamline_frame_index <= 4 || state.status != sl::DLSSGStatus::eOk)
                Log("[streamline] frame=%llu status=%u actually_presented=%u max_generated=%u input_fence=%p input_value=%llu",
                    static_cast<unsigned long long>(g_streamline_frame_index - 1),
                    static_cast<unsigned>(state.status), state.numFramesActuallyPresented,
                    state.numFramesToGenerateMax, state.inputsProcessingCompletionFence,
                    static_cast<unsigned long long>(state.lastPresentInputsProcessingCompletionFenceValue));
        }
    }
    return SUCCEEDED(present_result);
}

static void PumpPresent()
{
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    if (g_preview_mode && g_preview_direct && g_preview_fullscreen && !g_preview_paused &&
        g_preview_controls_visible &&
        g_preview_control_activity != 0 && GetTickCount64() - g_preview_control_activity > 5000)
        ShowPreviewControls(false);
    // The old ReShade feed host used empty Presents while its add-on warmed up.
    // A DLSS-G proxy swap-chain must never see those loading Presents: it can
    // clone an uninitialised fake backbuffer before options/constants/tags exist
    // and then keep presenting black even though later FG states report eOk.
    // GPU-direct preview is presented only by SubmitBatchPreview after the
    // complete real color/depth/motion frame has been submitted.
    if (g_preview_mode && g_preview_direct) return;
    if (h.swap == nullptr) return;

    // Paint the banner into the backbuffer (ReShade's overlay composites on top at Present).
    if (g_banner != nullptr && g_pump_list != nullptr && g_swap3 != nullptr)
    {
        ID3D12Resource *bb = nullptr;
        if (SUCCEEDED(g_swap3->GetBuffer(g_swap3->GetCurrentBackBufferIndex(), __uuidof(ID3D12Resource),
                                         reinterpret_cast<void **>(&bb))) && bb != nullptr)
        {
            if (SUCCEEDED(g_pump_alloc->Reset()) && SUCCEEDED(g_pump_list->Reset(g_pump_alloc, nullptr)))
            {
                D3D12_RESOURCE_BARRIER b = {};
                b.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
                b.Transition.pResource   = bb;
                b.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
                b.Transition.StateAfter  = D3D12_RESOURCE_STATE_COPY_DEST;
                b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
                g_pump_list->ResourceBarrier(1, &b);
                g_pump_list->CopyResource(bb, g_banner);
                b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
                b.Transition.StateAfter  = D3D12_RESOURCE_STATE_PRESENT;
                g_pump_list->ResourceBarrier(1, &b);
                g_pump_list->Close();
                ID3D12CommandList *lists[] = { g_pump_list };
                h.pump_queue->ExecuteCommandLists(1, lists);
                h.pump_queue->Signal(g_pump_fence, ++g_pump_val);
                if (g_pump_fence->GetCompletedValue() < g_pump_val && g_pump_ev != nullptr)
                {
                    g_pump_fence->SetEventOnCompletion(g_pump_val, g_pump_ev);
                    WaitForSingleObject(g_pump_ev, 100);
                }
            }
            bb->Release();
        }
    }
    h.swap->Present(0, 0);
}

static void PresentBatchRgb(const std::vector<uint8_t> &rgb, UINT width, UINT height)
{
    if (!g_preview_mode || width != g_preview_width || height != g_preview_height ||
        g_preview_upload == nullptr || g_pump_list == nullptr || g_swap3 == nullptr)
        return;

    BYTE *dst = nullptr;
    if (FAILED(g_preview_upload->Map(0, nullptr, reinterpret_cast<void **>(&dst)))) return;
    const size_t pixels = static_cast<size_t>(width) * height;
    #pragma omp parallel for if(pixels >= 1000000)
    for (int64_t pi = 0; pi < static_cast<int64_t>(pixels); ++pi)
    {
        const size_t p = static_cast<size_t>(pi);
        const UINT y = static_cast<UINT>(p / width);
        const UINT x = static_cast<UINT>(p - static_cast<size_t>(y) * width);
        BYTE *q = dst + static_cast<size_t>(y) * g_preview_pitch + static_cast<size_t>(x) * 4;
        q[0] = rgb[p * 3 + 0];
        q[1] = rgb[p * 3 + 1];
        q[2] = rgb[p * 3 + 2];
        q[3] = 255;
    }
    g_preview_upload->Unmap(0, nullptr);

    ID3D12Resource *bb = nullptr;
    if (FAILED(g_swap3->GetBuffer(g_swap3->GetCurrentBackBufferIndex(), __uuidof(ID3D12Resource),
                                  reinterpret_cast<void **>(&bb))) || bb == nullptr)
        return;
    if (FAILED(g_pump_alloc->Reset()) || FAILED(g_pump_list->Reset(g_pump_alloc, nullptr)))
    {
        bb->Release();
        return;
    }
    D3D12_RESOURCE_BARRIER b = {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = bb;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    g_pump_list->ResourceBarrier(1, &b);
    D3D12_TEXTURE_COPY_LOCATION src = {}, dst_tex = {};
    src.pResource = g_preview_upload;
    src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    src.PlacedFootprint.Footprint.Width = width;
    src.PlacedFootprint.Footprint.Height = height;
    src.PlacedFootprint.Footprint.Depth = 1;
    src.PlacedFootprint.Footprint.RowPitch = g_preview_pitch;
    dst_tex.pResource = bb;
    dst_tex.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    g_pump_list->CopyTextureRegion(&dst_tex, 0, 0, 0, &src, nullptr);
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
    g_pump_list->ResourceBarrier(1, &b);
    g_pump_list->Close();
    ID3D12CommandList *lists[] = { g_pump_list };
    h.pump_queue->ExecuteCommandLists(1, lists);
    const UINT64 v = ++g_pump_val;
    h.pump_queue->Signal(g_pump_fence, v);
    if (g_pump_fence->GetCompletedValue() < v && g_pump_ev != nullptr)
    {
        g_pump_fence->SetEventOnCompletion(v, g_pump_ev);
        WaitForSingleObject(g_pump_ev, 2000);
    }
    bb->Release();
    h.swap->Present(0, 0);
    g_preview_has_frame = true;
}

static bool InitDisguise()
{
    INITCOMMONCONTROLSEX common_controls = { sizeof(common_controls), ICC_BAR_CLASSES };
    InitCommonControlsEx(&common_controls);
    // ReShade is already loaded before Streamline so the neural-rendering add-on
    // can register its NGX hooks. Create the native DXGI factory through the
    // absolute System32 path: a portable build must not ship a renamed copy of
    // an OS DLL (which can mismatch another user's Windows build).
    wchar_t system_dir[MAX_PATH] = {};
    wchar_t system_dxgi[MAX_PATH] = {};
    wchar_t system_d3d12[MAX_PATH] = {};
    if (GetSystemDirectoryW(system_dir, static_cast<UINT>(_countof(system_dir))) == 0) return false;
    swprintf_s(system_dxgi, L"%ls\\dxgi.dll", system_dir);
    swprintf_s(system_d3d12, L"%ls\\d3d12.dll", system_dir);
    HMODULE dxgi = LoadLibraryW(system_dxgi);
    HMODULE d3d12 = LoadLibraryW(system_d3d12);
    auto create_device  = d3d12 ? reinterpret_cast<PFN_D3D12CreateDevice_>(GetProcAddress(d3d12, "D3D12CreateDevice")) : nullptr;
    auto create_factory = dxgi ? reinterpret_cast<PFN_CreateDXGIFactory2_>(GetProcAddress(dxgi, "CreateDXGIFactory2")) : nullptr;
    g_d3d12_serialize_root_signature = d3d12 ?
        reinterpret_cast<PFN_D3D12_SERIALIZE_ROOT_SIGNATURE_>(GetProcAddress(d3d12, "D3D12SerializeRootSignature")) : nullptr;
    if (create_device == nullptr || create_factory == nullptr || g_d3d12_serialize_root_signature == nullptr)
    { Log("[host] dxgi/d3d12 exports missing"); return false; }
    wchar_t debug_value[8] = {};
    if (GetEnvironmentVariableW(L"DLSS5_D3D_DEBUG", debug_value, static_cast<DWORD>(_countof(debug_value))) > 0)
    {
        auto get_debug = reinterpret_cast<PFN_D3D12_GET_DEBUG_INTERFACE>(GetProcAddress(d3d12, "D3D12GetDebugInterface"));
        ID3D12Debug *debug = nullptr;
        if (get_debug != nullptr && SUCCEEDED(get_debug(__uuidof(ID3D12Debug), reinterpret_cast<void **>(&debug))) && debug != nullptr)
        {
            debug->EnableDebugLayer();
            debug->Release();
            g_d3d_debug_enabled = true;
            Log("[d3d12-debug] debug layer enabled");
        }
    }

    wchar_t exe[MAX_PATH] = {};
    GetModuleFileNameW(dxgi, exe, MAX_PATH);
    Log("[host] dxgi.dll: %ls", exe);

    WNDCLASSW wc = {};
    wc.style          = CS_DBLCLKS;
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = L"dlss5feedhost";
    RegisterClassW(&wc);
    DWORD window_style = WS_OVERLAPPEDWINDOW;
    int window_x = CW_USEDEFAULT, window_y = CW_USEDEFAULT;
    int window_width = 960, window_height = 540;
    if (g_preview_mode && g_preview_direct)
    {
        // A display-only preview is a player, not a tuning utility. Present it
        // as a clean borderless viewport fitted to the usable desktop; Home
        // still opens the ReShade panel and Studio's Cancel/Esc still exits.
        RECT work = {};
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        const int available_width = std::max(320L, work.right - work.left);
        const int available_height = std::max(180L, work.bottom - work.top);
        const double fit = std::min(available_width / static_cast<double>(g_preview_width),
                                    available_height / static_cast<double>(g_preview_height));
        window_width = std::max(320, static_cast<int>(std::lround(g_preview_width * fit)));
        window_height = std::max(180, static_cast<int>(std::lround(g_preview_height * fit)));
        window_x = work.left + (available_width - window_width) / 2;
        window_y = work.top + (available_height - window_height) / 2;
        window_style = WS_POPUP;
        g_preview_windowed_rect = { window_x, window_y, window_x + window_width, window_y + window_height };
    }
    h.hwnd = CreateWindowExW(WS_EX_APPWINDOW, wc.lpszClassName,
                             L"DLSS 5 Neural Rendering Preview",
                             window_style, window_x, window_y, window_width, window_height,
                             nullptr, nullptr, wc.hInstance, nullptr);
    if (h.hwnd == nullptr) { Log("[host] window creation failed"); return false; }
    if (g_preview_mode && g_preview_direct) CreatePreviewControls(h.hwnd);
    if (g_show_window && !(g_preview_mode && g_preview_direct))
    {
        ShowWindow(h.hwnd, SW_SHOWNOACTIVATE);
    }

    HRESULT hr = S_OK;
    ID3D12Device *queue_device = nullptr;
    if (g_streamline_initialized)
    {
        // sl.interposer.lib is linked into this executable, therefore the
        // imported creation entry point returns the SL proxy.  Keep that proxy
        // only for hooked calls and use its native interface everywhere else.
        hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device),
                               reinterpret_cast<void **>(&g_streamline_device_proxy));
        if (SUCCEEDED(hr) && g_streamline_device_proxy != nullptr)
            slGetNativeInterface(g_streamline_device_proxy, reinterpret_cast<void **>(&h.dev));
        queue_device = g_streamline_device_proxy;
    }
    else
    {
        hr = create_device(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device),
                           reinterpret_cast<void **>(&h.dev));
        queue_device = h.dev;
    }
    if (FAILED(hr)) { Log("[host] D3D12CreateDevice failed 0x%08X", hr); return false; }
    if (h.dev == nullptr || queue_device == nullptr) { Log("[host] D3D12 device proxy/native split failed"); return false; }
    if (g_d3d_debug_enabled)
    {
        h.dev->QueryInterface(__uuidof(ID3D12InfoQueue), reinterpret_cast<void **>(&g_d3d_info_queue));
        DumpD3DDebugMessages("CreateDevice");
    }

    if (g_streamline_initialized)
    {
        const sl::Result set_device = slSetD3DDevice(h.dev);
        Log("[streamline] slSetD3DDevice -> %d", static_cast<int>(set_device));
        if (set_device != sl::Result::eOk) return false;
    }

    D3D12_COMMAND_QUEUE_DESC qd = {};
    qd.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
    // Use one host graphics queue for both rendering and presentation.  The
    // DLSS-G plugin creates its own asynchronous presentation queue.  Creating
    // two indistinguishable host graphics queues before the swap-chain made
    // the manual-hooking path associate the swap-chain with the wrong queue.
    ID3D12CommandQueue *queue_created = nullptr;
    HRESULT queue_hr = queue_device->CreateCommandQueue(
        &qd, __uuidof(ID3D12CommandQueue), reinterpret_cast<void **>(&queue_created));
    ID3D12CommandQueue *pump_created = queue_created;
    if (pump_created != nullptr) pump_created->AddRef();
    if (g_streamline_initialized)
    {
        g_streamline_pump_proxy = pump_created;
        g_streamline_queue_proxy = queue_created;
        if (pump_created != nullptr)
            slGetNativeInterface(pump_created, reinterpret_cast<void **>(&h.pump_queue));
        if (queue_created != nullptr)
            slGetNativeInterface(queue_created, reinterpret_cast<void **>(&h.queue));
    }
    else
    {
        h.pump_queue = pump_created;
        h.queue = queue_created;
    }
    if (h.pump_queue == nullptr || h.queue == nullptr) { Log("[host] queue creation failed"); return false; }

    IDXGIFactory2 *factory = nullptr;
    if (g_streamline_initialized)
        hr = CreateDXGIFactory2(0, __uuidof(IDXGIFactory2), reinterpret_cast<void **>(&factory));
    else
        hr = create_factory(0, __uuidof(IDXGIFactory2), reinterpret_cast<void **>(&factory));
    if (FAILED(hr)) { Log("[host] CreateDXGIFactory2 failed 0x%08X", hr); return false; }
    IDXGIFactory2 *swap_factory = factory;
    if (g_streamline_initialized)
    {
        g_streamline_factory_proxy = factory;
        swap_factory = g_streamline_factory_proxy;
    }

    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width            = g_preview_mode ? g_preview_width : 960;
    sd.Height           = g_preview_mode ? g_preview_height : 540;
    sd.Format           = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1;
    // DLSS-G samples the intercepted final color.  The reference Streamline
    // D3D12 swap-chain enables both usages; RT-only buffers make the plugin's
    // first Present fail with DXGI_ERROR_INVALID_CALL and leave a black surface.
    sd.BufferUsage      = DXGI_USAGE_SHADER_INPUT | DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount      = 3;
    sd.SwapEffect       = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.Flags            = 0;
    ID3D12CommandQueue *swap_queue = nullptr;
    if (g_streamline_initialized)
        swap_queue = g_preview_direct ? g_streamline_queue_proxy : g_streamline_pump_proxy;
    else
        swap_queue = g_preview_direct ? h.queue : h.pump_queue;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fullscreen_desc = {};
    fullscreen_desc.Windowed = TRUE;
    hr = swap_factory->CreateSwapChainForHwnd(swap_queue, h.hwnd, &sd, &fullscreen_desc, nullptr, &h.swap);
    if (!g_streamline_initialized) factory->Release();
    if (FAILED(hr)) { Log("[host] CreateSwapChainForHwnd failed 0x%08X", hr); return false; }
    if (g_streamline_initialized)
    {
        IDXGISwapChain1 *native_swap = nullptr;
        const sl::Result native_swap_result = slGetNativeInterface(
            h.swap, reinterpret_cast<void **>(&native_swap));
        Log("[streamline] native swap-chain -> %d (%p)",
            static_cast<int>(native_swap_result), native_swap);
        if (native_swap != nullptr) native_swap->Release();
    }
    Log("[host] disguise up: hidden window + D3D12 swapchain (ReShade should be attached now)");

    for (int i = 0; i < 60; ++i) PumpPresent();   // let ReShade + the DLSS 5 add-on settle

    // Ring + internal fence for our own submissions.
    for (int i = 0; i < Host::kFrames; ++i)
        h.dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator),
                                      reinterpret_cast<void **>(&h.alloc[i]));
    if (h.alloc[0] != nullptr)
        h.dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, h.alloc[0], nullptr,
                                 __uuidof(ID3D12GraphicsCommandList), reinterpret_cast<void **>(&h.list));
    if (h.list != nullptr) h.list->Close();
    h.dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), reinterpret_cast<void **>(&h.fence));
    h.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (h.list == nullptr || h.fence == nullptr) { Log("[host] list/fence creation failed"); return false; }

    if (g_preview_mode && g_preview_direct)
    {
        h.swap->QueryInterface(__uuidof(IDXGISwapChain3), reinterpret_cast<void **>(&g_swap3));
        // Let the DLSS-G proxy own flip-queue throttling.  Supplying the
        // waitable-object flag here disables Streamline's own throttler and is
        // not how NVIDIA's D3D12 sample creates its three-buffer swap-chain.
    }
    else if (g_preview_mode)
        InitPumpObjects();
    else if (g_show_window) InitBanner();
    return true;
}

static bool InitNgx()
{
    wchar_t data_path[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, data_path, MAX_PATH);
    if (wchar_t *s = wcsrchr(data_path, L'\\')) *(s + 1) = L'\0';

    NVSDK_NGX_Result r = NVSDK_NGX_D3D12_Init(0x1000000ULL, data_path, h.dev, nullptr, NVSDK_NGX_Version_API);
    Log("[host] NVSDK_NGX_D3D12_Init -> 0x%08X (%s)", r, NgxResultName(r));
    if (NVSDK_NGX_FAILED(r))
    {
        r = NVSDK_NGX_D3D12_Init_with_ProjectID("a0f57b54-1daf-4934-90ae-c4035c19df04", NVSDK_NGX_ENGINE_TYPE_CUSTOM,
                                                "1.0", data_path, h.dev, nullptr, NVSDK_NGX_Version_API);
        Log("[host] Init_with_ProjectID -> 0x%08X (%s)", r, NgxResultName(r));
    }
    if (NVSDK_NGX_FAILED(r)) return false;
    h.ngx_inited = true;

    NVSDK_NGX_Parameter *caps = nullptr;
    r = NVSDK_NGX_D3D12_GetCapabilityParameters(&caps);
    if (NVSDK_NGX_SUCCEED(r) && caps != nullptr)
    {
        int avail = 0;
        caps->Get(NVSDK_NGX_Parameter_SuperSampling_Available, &avail);
        Log("[host] SuperSampling.Available=%d", avail);
        if (!avail) return false;
    }
    r = NVSDK_NGX_D3D12_AllocateParameters(&h.params);
    if (NVSDK_NGX_FAILED(r) || h.params == nullptr) { Log("[host] AllocateParameters failed 0x%08X", r); return false; }
    return true;
}

static bool CreateFeature(UINT w, UINT h_, int flags, NVSDK_NGX_Result *out_r,
                          UINT target_w = 0, UINT target_h = 0)
{
    if (target_w == 0) target_w = w;
    if (target_h == 0) target_h = h_;
    const bool upscaling = target_w != w || target_h != h_;
    NVSDK_NGX_DLSS_Create_Params cp = {};
    cp.Feature.InWidth            = w;
    cp.Feature.InHeight           = h_;
    cp.Feature.InTargetWidth      = target_w;
    cp.Feature.InTargetHeight     = target_h;
    cp.Feature.InPerfQualityValue = upscaling ? NVSDK_NGX_PerfQuality_Value_MaxPerf
                                               : NVSDK_NGX_PerfQuality_Value_DLAA;
    cp.InFeatureCreateFlags       = flags;
    cp.InEnableOutputSubrects     = false;

    if (!BeginCommands()) return false;
    DWORD ccode = 0;
    NVSDK_NGX_Result rf = SafeCreateDLSS(&cp, &ccode);
    if (out_r != nullptr) *out_r = rf;
    if (ccode != 0)
    {
        AbortCommands();
        // NGX may have partially written *OutHandle before the fault; never trust it.
        h.feature = nullptr;
        Log("[host] CreateFeature raised 0x%08X (caught; nothing submitted)", ccode);
        return false;
    }
    const UINT64 v = EndCommands();
    if (!WaitFenceValue(h.fence, v, 4000)) { Log("[host] feature create did not complete"); return false; }
    if (NVSDK_NGX_FAILED(rf) || h.feature == nullptr)
    { Log("[host] CreateFeature failed 0x%08X (%s)", rf, NgxResultName(rf)); h.feature = nullptr; return false; }
    Log("[host] feature ready: render=%ux%u target=%ux%u mode=%s flags=%d",
        w, h_, target_w, target_h, upscaling ? "DLSS MaxPerf" : "DLAA", flags);
    return true;
}

// A crashed CreateFeature can leave NGX's own internal state broken (seen in BioShock
// Remastered: the add-on faulted once during a resolution/HDR change, and every following
// create failed too, with the SEH catching a different exception each time -- NGX was
// never going to recover on its own). Reset NGX itself as a last resort so the feed can
// come back without the user having to restart the game.
static bool ReinitNgx()
{
    Log("[host] NGX looks corrupted after repeated failures; reinitializing");
    if (h.params != nullptr) { NVSDK_NGX_D3D12_DestroyParameters(h.params); h.params = nullptr; }
    if (h.ngx_inited) { NVSDK_NGX_D3D12_Shutdown1(h.dev); h.ngx_inited = false; }
    h.feature = nullptr;
    return InitNgx();
}

static bool Evaluate(ID3D12Resource *color, ID3D12Resource *output, ID3D12Resource *depth, ID3D12Resource *mv,
                     UINT w, UINT h_, int reset, float mvsx, float mvsy,
                     ID3D12Resource *bias_current_color = nullptr)
{
    if (!BeginCommands()) return false;

    NVSDK_NGX_D3D12_DLSS_Eval_Params ep = {};
    ep.Feature.pInColor  = color;
    ep.Feature.pInOutput = output;
    ep.pInDepth          = depth;
    ep.pInMotionVectors  = mv;
    ep.pInBiasCurrentColorMask = bias_current_color;
    ep.InRenderSubrectDimensions.Width  = w;
    ep.InRenderSubrectDimensions.Height = h_;
    ep.InReset           = reset;
    ep.InMVScaleX        = mvsx;
    ep.InMVScaleY        = mvsy;
    ep.InPreExposure     = 1.0f;
    ep.InExposureScale   = 1.0f;

    DWORD ecode = 0;
    NVSDK_NGX_Result re = SafeEvaluateDLSS(&ep, &ecode);
    if (ecode != 0) { AbortCommands(); Log("[host] evaluate raised 0x%08X (caught; nothing submitted)", ecode); return false; }
    EndCommands();
    if (NVSDK_NGX_FAILED(re)) { Log("[host] evaluate failed 0x%08X (%s)", re, NgxResultName(re)); return false; }
    return true;
}

// ---------------------------------------------------------------------------
// --test: prove the whole stack with no game attached
// ---------------------------------------------------------------------------

static ID3D12Resource *MakeTex(UINT w, UINT h_, DXGI_FORMAT fmt, bool uav)
{
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC rd = {};
    rd.Dimension        = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width            = w;
    rd.Height           = h_;
    rd.DepthOrArraySize = 1;
    rd.MipLevels        = 1;
    rd.Format           = fmt;
    rd.SampleDesc.Count = 1;
    rd.Layout           = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags            = uav ? D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS : D3D12_RESOURCE_FLAG_NONE;
    ID3D12Resource *t = nullptr;
    h.dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_COMMON, nullptr,
                                   __uuidof(ID3D12Resource), reinterpret_cast<void **>(&t));
    return t;
}

static int RunTest()
{
    const UINT W = 640, H = 360;
    Log("[host] --test: %ux%u synthetic DLAA", W, H);

    ID3D12Resource *color  = MakeTex(W, H, DXGI_FORMAT_R8G8B8A8_UNORM, false);
    ID3D12Resource *output = MakeTex(W, H, DXGI_FORMAT_R8G8B8A8_UNORM, true);
    ID3D12Resource *depth  = MakeTex(W, H, DXGI_FORMAT_R32_FLOAT, false);
    ID3D12Resource *mv     = MakeTex(W, H, DXGI_FORMAT_R16G16_FLOAT, false);
    if (!color || !output || !depth || !mv) { Log("[host] test texture creation failed"); return 1; }

    // Give the DLSS 5 add-on its hook-arming time, with the swapchain pumping.
    for (int i = 0; i < 120; ++i) { PumpPresent(); Sleep(8); }

    int flags = NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | NVSDK_NGX_DLSS_Feature_Flags_AutoExposure |
                NVSDK_NGX_DLSS_Feature_Flags_DepthInverted;
    NVSDK_NGX_Result rf = NVSDK_NGX_Result_Fail;
    if (!CreateFeature(W, H, flags, &rf)) return 1;

    int good = 0;
    for (int i = 0; i < 300; ++i)
    {
        PumpPresent();
        if (Evaluate(color, output, depth, mv, W, H, i == 0 ? 1 : 0, 1.0f, 1.0f)) ++good;
        else break;
        if (i == 180)   // the warm-up re-create, same medicine as in-game
        {
            Log("[host] warm-up: re-creating the feature once");
            NVSDK_NGX_Handle *old = h.feature;
            h.feature = nullptr;
            if (!CreateFeature(W, H, flags, &rf)) { h.feature = old; Log("[host] keeping the previous feature"); }
            else SafeReleaseFeature(old);
        }
    }
    Log("[host] --test finished: %d/300 evaluates succeeded", good);
    Log("[host] check the host's ReShade.log for 'feature 18 created' / 'evaluation succeeded'");
    return good >= 250 ? 0 : 1;
}

struct MotionFrameGeneration
{
    ID3D12Resource *previous = nullptr;
    ID3D12Resource *generated = nullptr;
    ID3D12RootSignature *root = nullptr;
    ID3D12PipelineState *pso = nullptr;
    ID3D12DescriptorHeap *heap = nullptr;
    UINT descriptor_size = 0;
    bool has_previous = false;
    bool generated_common = true;
};

static void Transition(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after);

static void ReleaseMotionFrameGeneration(MotionFrameGeneration &fg)
{
    if (fg.heap) fg.heap->Release();
    if (fg.pso) fg.pso->Release();
    if (fg.root) fg.root->Release();
    if (fg.generated) fg.generated->Release();
    if (fg.previous) fg.previous->Release();
    fg = {};
}

static bool InitMotionFrameGeneration(
    MotionFrameGeneration &fg, ID3D12Resource *current, ID3D12Resource *motion, ID3D12Resource *validity,
    UINT output_width, UINT output_height)
{
    static const char *shader = R"HLSL(
cbuffer Params : register(b0)
{
    float Alpha;
    float MotionFraction;
    uint OutputWidth;
    uint OutputHeight;
    uint InputWidth;
    uint InputHeight;
    float Padding0;
    float Padding1;
};
Texture2D<float4> PreviousFrame : register(t0);
Texture2D<float4> CurrentFrame : register(t1);
Texture2D<float2> Motion : register(t2);
Texture2D<float> Validity : register(t3);
RWTexture2D<float4> GeneratedFrame : register(u0);
SamplerState LinearClamp : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 dispatchId : SV_DispatchThreadID)
{
    if (dispatchId.x >= OutputWidth || dispatchId.y >= OutputHeight) return;
    float2 uv = (float2(dispatchId.xy) + 0.5) / float2(OutputWidth, OutputHeight);
    float2 mv = Motion.SampleLevel(LinearClamp, uv, 0);
    float confidence = Validity.SampleLevel(LinearClamp, uv, 0);
    float2 previousUv = uv + mv * (MotionFraction * confidence) / float2(InputWidth, InputHeight);
    float4 previous = PreviousFrame.SampleLevel(LinearClamp, previousUv, 0);
    float4 current = CurrentFrame.SampleLevel(LinearClamp, uv, 0);
    GeneratedFrame[dispatchId.xy] = lerp(previous, current, Alpha);
}
)HLSL";

    fg.previous = MakeTex(output_width, output_height, DXGI_FORMAT_R8G8B8A8_UNORM, false);
    fg.generated = MakeTex(output_width, output_height, DXGI_FORMAT_R8G8B8A8_UNORM, true);
    if (!fg.previous || !fg.generated) return false;

    ID3DBlob *bytecode = nullptr, *errors = nullptr;
    HRESULT hr = D3DCompile(shader, strlen(shader), "motion-frame-generation", nullptr, nullptr, "main", "cs_5_1",
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &bytecode, &errors);
    if (FAILED(hr))
    {
        if (errors) Log("[host] frame generation shader: %s", static_cast<const char *>(errors->GetBufferPointer()));
        if (errors) errors->Release();
        if (bytecode) bytecode->Release();
        return false;
    }
    if (errors) errors->Release();

    D3D12_DESCRIPTOR_RANGE ranges[2] = {};
    ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    ranges[0].NumDescriptors = 4;
    ranges[0].BaseShaderRegister = 0;
    ranges[0].OffsetInDescriptorsFromTableStart = 0;
    ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
    ranges[1].NumDescriptors = 1;
    ranges[1].BaseShaderRegister = 0;
    ranges[1].OffsetInDescriptorsFromTableStart = 0;
    D3D12_ROOT_PARAMETER parameters[3] = {};
    parameters[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameters[0].DescriptorTable.NumDescriptorRanges = 1;
    parameters[0].DescriptorTable.pDescriptorRanges = &ranges[0];
    parameters[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameters[1].DescriptorTable.NumDescriptorRanges = 1;
    parameters[1].DescriptorTable.pDescriptorRanges = &ranges[1];
    parameters[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    parameters[2].Constants.ShaderRegister = 0;
    parameters[2].Constants.Num32BitValues = 8;
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.ShaderRegister = 0;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    D3D12_ROOT_SIGNATURE_DESC signature = {};
    signature.NumParameters = _countof(parameters);
    signature.pParameters = parameters;
    signature.NumStaticSamplers = 1;
    signature.pStaticSamplers = &sampler;
    ID3DBlob *serialized = nullptr;
    hr = g_d3d12_serialize_root_signature(&signature, D3D_ROOT_SIGNATURE_VERSION_1, &serialized, &errors);
    if (FAILED(hr) || FAILED(h.dev->CreateRootSignature(0, serialized->GetBufferPointer(), serialized->GetBufferSize(),
                                                       __uuidof(ID3D12RootSignature), reinterpret_cast<void **>(&fg.root))))
    {
        if (serialized) serialized->Release();
        if (errors) errors->Release();
        bytecode->Release();
        return false;
    }
    serialized->Release();
    if (errors) errors->Release();

    D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline = {};
    pipeline.pRootSignature = fg.root;
    pipeline.CS = {bytecode->GetBufferPointer(), bytecode->GetBufferSize()};
    hr = h.dev->CreateComputePipelineState(&pipeline, __uuidof(ID3D12PipelineState), reinterpret_cast<void **>(&fg.pso));
    bytecode->Release();
    if (FAILED(hr)) return false;

    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {};
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    heap_desc.NumDescriptors = 5;
    heap_desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    if (FAILED(h.dev->CreateDescriptorHeap(&heap_desc, __uuidof(ID3D12DescriptorHeap), reinterpret_cast<void **>(&fg.heap))))
        return false;
    fg.descriptor_size = h.dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    D3D12_CPU_DESCRIPTOR_HANDLE cpu = fg.heap->GetCPUDescriptorHandleForHeapStart();
    auto make_srv = [&](ID3D12Resource *resource, DXGI_FORMAT format)
    {
        D3D12_SHADER_RESOURCE_VIEW_DESC desc = {};
        desc.Format = format;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        desc.Texture2D.MipLevels = 1;
        h.dev->CreateShaderResourceView(resource, &desc, cpu);
        cpu.ptr += fg.descriptor_size;
    };
    make_srv(fg.previous, DXGI_FORMAT_R8G8B8A8_UNORM);
    make_srv(current, DXGI_FORMAT_R8G8B8A8_UNORM);
    make_srv(motion, DXGI_FORMAT_R16G16_FLOAT);
    make_srv(validity, DXGI_FORMAT_R8_UNORM);
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav = {};
    uav.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    uav.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
    h.dev->CreateUnorderedAccessView(fg.generated, nullptr, &uav, cpu);
    return true;
}

static UINT64 CopyMotionFrameHistory(MotionFrameGeneration &fg, ID3D12Resource *current)
{
    if (!BeginCommands()) return 0;
    Transition(current, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    Transition(fg.previous, fg.has_previous ? D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE : D3D12_RESOURCE_STATE_COMMON,
               D3D12_RESOURCE_STATE_COPY_DEST);
    h.list->CopyResource(fg.previous, current);
    Transition(fg.previous, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(current, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    fg.has_previous = true;
    return EndCommands();
}

static UINT64 GenerateMotionFrame(
    MotionFrameGeneration &fg, ID3D12Resource *current, UINT input_width, UINT input_height,
    UINT output_width, UINT output_height)
{
    if (!fg.has_previous || !BeginCommands()) return 0;
    Transition(current, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if (fg.generated_common)
    {
        Transition(fg.generated, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        fg.generated_common = false;
    }
    ID3D12DescriptorHeap *heaps[] = {fg.heap};
    h.list->SetDescriptorHeaps(1, heaps);
    h.list->SetComputeRootSignature(fg.root);
    h.list->SetPipelineState(fg.pso);
    D3D12_GPU_DESCRIPTOR_HANDLE gpu = fg.heap->GetGPUDescriptorHandleForHeapStart();
    h.list->SetComputeRootDescriptorTable(0, gpu);
    gpu.ptr += static_cast<UINT64>(4) * fg.descriptor_size;
    h.list->SetComputeRootDescriptorTable(1, gpu);
    struct Constants { float alpha, fraction; UINT output_width, output_height, input_width, input_height; float pad[2]; } constants =
        {0.5f, 0.5f, output_width, output_height, input_width, input_height, {0.0f, 0.0f}};
    h.list->SetComputeRoot32BitConstants(2, 8, &constants, 0);
    h.list->Dispatch((output_width + 7) / 8, (output_height + 7) / 8, 1);
    Transition(current, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    return EndCommands();
}

// ---------------------------------------------------------------------------
// Portable batch mode: RGB24 + automatically generated motion/depth guides -> RGB24.
// This deliberately drives a genuine D3D12 DLAA feature. The RenoDX add-on
// intercepts that feature and inserts the signed/private DLSSNR feature 18.
// ---------------------------------------------------------------------------

class RgbInput
{
public:
    RgbInput(const fs::path &path, size_t expected_bytes = 0)
    {
        const std::string text = path.generic_string();
        static constexpr const char *prefix = "shm://";
        if (text.rfind(prefix, 0) == 0)
        {
            const std::string utf8_name = text.substr(strlen(prefix));
            if (utf8_name.empty()) throw std::runtime_error("empty shared RGB mapping name");
            const int wide_count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_name.c_str(),
                                                        static_cast<int>(utf8_name.size()), nullptr, 0);
            if (wide_count <= 0) throw std::runtime_error("invalid shared RGB mapping name");
            std::wstring name = L"Local\\";
            const size_t prefix_size = name.size();
            name.resize(prefix_size + static_cast<size_t>(wide_count));
            MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_name.c_str(),
                                static_cast<int>(utf8_name.size()), name.data() + prefix_size, wide_count);
            mapping_ = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
            if (mapping_ == nullptr) throw std::runtime_error("cannot open shared RGB mapping");
            mapped_ = static_cast<const uint8_t *>(MapViewOfFile(mapping_, FILE_MAP_READ, 0, 0, expected_bytes));
            if (mapped_ == nullptr)
            {
                CloseHandle(mapping_);
                mapping_ = nullptr;
                throw std::runtime_error("cannot map shared RGB frames");
            }
            if (expected_bytes != 0)
            {
                size_ = expected_bytes;
            }
            else
            {
                MEMORY_BASIC_INFORMATION region = {};
                if (VirtualQuery(mapped_, &region, sizeof(region)) == 0)
                {
                    UnmapViewOfFile(mapped_);
                    mapped_ = nullptr;
                    CloseHandle(mapping_);
                    mapping_ = nullptr;
                    throw std::runtime_error("cannot query shared mapping size");
                }
                size_ = region.RegionSize;
            }
        }
        else
        {
            file_.open(path, std::ios::binary);
            if (!file_) throw std::runtime_error("cannot open batch RGB24 input");
        }
    }

    ~RgbInput()
    {
        if (mapped_ != nullptr) UnmapViewOfFile(mapped_);
        if (mapping_ != nullptr) CloseHandle(mapping_);
    }

    bool ReadExact(void *destination, size_t bytes)
    {
        if (mapped_ != nullptr)
        {
            if (position_ > size_ || bytes > size_ - position_) return false;
            memcpy(destination, mapped_ + position_, bytes);
            position_ += bytes;
            return true;
        }
        file_.read(static_cast<char *>(destination), static_cast<std::streamsize>(bytes));
        return file_.gcount() == static_cast<std::streamsize>(bytes);
    }

    bool Shared() const { return mapped_ != nullptr; }

private:
    std::ifstream file_;
    HANDLE mapping_ = nullptr;
    const uint8_t *mapped_ = nullptr;
    size_t size_ = 0;
    size_t position_ = 0;
};

class MotionSidecar
{
public:
    MotionSidecar(const fs::path &path, const BatchOptions &o) : in_(path)
    {
        if (!in_.ReadExact(&header_, sizeof(header_))) throw std::runtime_error("truncated motion sidecar header");
        const bool v1 = memcmp(header_.magic, kMotionMagicV1.data(), 8) == 0;
        v2_ = memcmp(header_.magic, kMotionMagicV2.data(), 8) == 0;
        v3_ = memcmp(header_.magic, kMotionMagicV3.data(), 8) == 0;
        if ((!v1 && !v2_ && !v3_) || header_.width != o.width || header_.height != o.height ||
            header_.frames != o.frames || header_.record_bytes != sizeof(MotionRecord) ||
            header_.flags != 1 || header_.tile == 0 ||
            header_.tiles_x != (o.width + header_.tile - 1) / header_.tile ||
            header_.tiles_y != (o.height + header_.tile - 1) / header_.tile)
            throw std::runtime_error("motion sidecar ABI/geometry mismatch");
        records_.resize(static_cast<size_t>(header_.tiles_x) * header_.tiles_y);
    }

    bool ReadCompact(std::vector<uint16_t> &premultiplied_flow, std::vector<uint8_t> &confidence)
    {
        const size_t bytes = records_.size() * sizeof(MotionRecord);
        if (!in_.ReadExact(records_.data(), bytes)) throw std::runtime_error("truncated motion sidecar");
        bool reset = true;
        for (const MotionRecord &record : records_)
            if (record.valid) { reset = false; break; }
        const size_t grid_pixels = records_.size();
        premultiplied_flow.resize(grid_pixels * 2);
        confidence.resize(grid_pixels);
        #pragma omp parallel for if(grid_pixels >= 262144) schedule(static)
        for (int64_t signed_i = 0; signed_i < static_cast<int64_t>(grid_pixels); ++signed_i)
        {
            const size_t i = static_cast<size_t>(signed_i);
            const MotionRecord &r = records_[i];
            if (v3_)
            {
                premultiplied_flow[i * 2 + 0] = r.valid ? r.x : 0;
                premultiplied_flow[i * 2 + 1] = r.valid ? r.y : 0;
                confidence[i] = r.valid ? r.confidence : 0;
                continue;
            }
            float flow_x = 0.0f, flow_y = 0.0f;
            if (r.valid && v2_)
            {
                flow_x = DirectX::PackedVector::XMConvertHalfToFloat(r.x);
                flow_y = DirectX::PackedVector::XMConvertHalfToFloat(r.y);
            }
            else if (r.valid)
            {
                int16_t sx = 0, sy = 0;
                memcpy(&sx, &r.x, sizeof(sx));
                memcpy(&sy, &r.y, sizeof(sy));
                flow_x = static_cast<float>(sx);
                flow_y = static_cast<float>(sy);
            }
            const float normalized_confidence = r.valid ? static_cast<float>(r.confidence) / 255.0f : 0.0f;
            premultiplied_flow[i * 2 + 0] = DirectX::PackedVector::XMConvertFloatToHalf(flow_x * normalized_confidence);
            premultiplied_flow[i * 2 + 1] = DirectX::PackedVector::XMConvertFloatToHalf(flow_y * normalized_confidence);
            confidence[i] = r.valid ? r.confidence : 0;
        }
        return reset;
    }

    uint32_t Tile() const { return header_.tile; }
    uint32_t TilesX() const { return header_.tiles_x; }
    uint32_t TilesY() const { return header_.tiles_y; }

private:
    RgbInput in_;
    MotionHeader header_ = {};
    std::vector<MotionRecord> records_;
    bool v2_ = false;
    bool v3_ = false;
};

class DepthSidecar
{
public:
    DepthSidecar(const fs::path &path, const BatchOptions &o) : in_(path)
    {
        if (!in_.ReadExact(&header_, sizeof(header_))) throw std::runtime_error("truncated depth sidecar header");
        tile_ = header_.flags >> 8;
        if (tile_ == 0) tile_ = 1;
        tiles_x_ = (o.width + tile_ - 1) / tile_;
        tiles_y_ = (o.height + tile_ - 1) / tile_;
        if (memcmp(header_.magic, kDepthMagic.data(), 8) != 0 ||
            header_.width != o.width || header_.height != o.height || header_.frames != o.frames ||
            header_.record_bytes != sizeof(uint16_t) || (header_.flags & 0xffu) != 1 || tile_ > 16)
            throw std::runtime_error("depth sidecar ABI/geometry mismatch");
        encoded_.resize(static_cast<size_t>(tiles_x_) * tiles_y_);
    }

    void ReadCompact(std::vector<uint16_t> &encoded)
    {
        const size_t bytes = encoded_.size() * sizeof(uint16_t);
        if (!in_.ReadExact(encoded_.data(), bytes)) throw std::runtime_error("truncated depth sidecar");
        encoded = encoded_;
    }

    uint32_t Tile() const { return tile_; }
    uint32_t TilesX() const { return tiles_x_; }
    uint32_t TilesY() const { return tiles_y_; }

private:
    RgbInput in_;
    DepthHeader header_ = {};
    std::vector<uint16_t> encoded_;
    uint32_t tile_ = 1, tiles_x_ = 0, tiles_y_ = 0;
};

struct LinearTransfer
{
    ID3D12Resource *buffer = nullptr;
    uint8_t *persistent_map = nullptr;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = {};
    UINT rows = 0;
    UINT64 row_size = 0;
    UINT64 total = 0;
};

static LinearTransfer MakeTransfer(ID3D12Resource *texture, D3D12_HEAP_TYPE heap_type)
{
    LinearTransfer t;
    const D3D12_RESOURCE_DESC td = texture->GetDesc();
    h.dev->GetCopyableFootprints(&td, 0, 1, 0, &t.footprint, &t.rows, &t.row_size, &t.total);
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = heap_type;
    D3D12_RESOURCE_DESC bd = {};
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    bd.Width = t.total;
    bd.Height = 1;
    bd.DepthOrArraySize = 1;
    bd.MipLevels = 1;
    bd.Format = DXGI_FORMAT_UNKNOWN;
    bd.SampleDesc.Count = 1;
    bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    const D3D12_RESOURCE_STATES state = heap_type == D3D12_HEAP_TYPE_UPLOAD
        ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COPY_DEST;
    const HRESULT hr = h.dev->CreateCommittedResource(
        &hp, D3D12_HEAP_FLAG_NONE, &bd, state, nullptr, __uuidof(ID3D12Resource),
        reinterpret_cast<void **>(&t.buffer));
    if (FAILED(hr) || t.buffer == nullptr) throw std::runtime_error("transfer buffer allocation failed");
    if (heap_type == D3D12_HEAP_TYPE_UPLOAD)
    {
        const D3D12_RANGE no_read = {0, 0};
        if (FAILED(t.buffer->Map(0, &no_read, reinterpret_cast<void **>(&t.persistent_map))) ||
            t.persistent_map == nullptr)
            throw std::runtime_error("persistent upload mapping failed");
    }
    return t;
}

static void Transition(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    if (before == after) return;
    D3D12_RESOURCE_BARRIER b = {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = resource;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    h.list->ResourceBarrier(1, &b);
}

static void FillUpload(LinearTransfer &t, const void *source, size_t source_row_bytes, UINT rows)
{
    if (rows != t.rows || source_row_bytes > t.footprint.Footprint.RowPitch)
        throw std::runtime_error("upload footprint mismatch");
    uint8_t *mapped = t.persistent_map;
    if (mapped == nullptr) throw std::runtime_error("upload buffer is not persistently mapped");
    const uint8_t *src = static_cast<const uint8_t *>(source);
    uint8_t *dst = mapped + t.footprint.Offset;
    #pragma omp parallel for schedule(static)
    for (int64_t yi = 0; yi < static_cast<int64_t>(rows); ++yi)
    {
        const UINT y = static_cast<UINT>(yi);
        memcpy(dst + static_cast<size_t>(y) * t.footprint.Footprint.RowPitch,
               src + static_cast<size_t>(y) * source_row_bytes, source_row_bytes);
    }
}

static void CopyUploadToTexture(LinearTransfer &upload, ID3D12Resource *texture)
{
    D3D12_TEXTURE_COPY_LOCATION src = {}, dst = {};
    src.pResource = upload.buffer;
    src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.PlacedFootprint = upload.footprint;
    dst.pResource = texture;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst.SubresourceIndex = 0;
    h.list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
}

struct RawUpload
{
    ID3D12Resource *buffer = nullptr;
    uint8_t *persistent_map = nullptr;
    UINT64 size = 0;
};

static RawUpload MakeRawUpload(UINT64 requested_size)
{
    RawUpload upload;
    // One padded DWORD lets the shader issue a single Load2 for an unaligned
    // RGB24 triplet at the final pixel without a bounds-dependent slow path.
    upload.size = (requested_size + 7u) & ~3ull;
    D3D12_HEAP_PROPERTIES hp = {};
    hp.Type = D3D12_HEAP_TYPE_UPLOAD;
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = upload.size;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(h.dev->CreateCommittedResource(
            &hp, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
            __uuidof(ID3D12Resource), reinterpret_cast<void **>(&upload.buffer))) || upload.buffer == nullptr)
        throw std::runtime_error("raw RGB upload allocation failed");
    const D3D12_RANGE no_read = {0, 0};
    if (FAILED(upload.buffer->Map(0, &no_read, reinterpret_cast<void **>(&upload.persistent_map))) ||
        upload.persistent_map == nullptr)
        throw std::runtime_error("raw RGB upload mapping failed");
    return upload;
}

struct GpuInputExpander
{
    ID3D12Resource *flow_grid = nullptr;
    ID3D12Resource *confidence_grid = nullptr;
    ID3D12Resource *depth_grid = nullptr;
    ID3D12RootSignature *root = nullptr;
    ID3D12PipelineState *pso = nullptr;
    ID3D12DescriptorHeap *heap = nullptr;
    UINT descriptor_size = 0;
    UINT width = 0, height = 0, tiles_x = 0, tiles_y = 0, tile = 1;
    bool grid_common = true;
};

static void ReleaseGpuInputExpander(GpuInputExpander &expander)
{
    if (expander.heap) expander.heap->Release();
    if (expander.pso) expander.pso->Release();
    if (expander.root) expander.root->Release();
    if (expander.depth_grid) expander.depth_grid->Release();
    if (expander.confidence_grid) expander.confidence_grid->Release();
    if (expander.flow_grid) expander.flow_grid->Release();
    expander = {};
}

static bool InitGpuInputExpander(
    GpuInputExpander &expander, RawUpload *rgb_uploads, int pipeline_slots,
    ID3D12Resource *color, ID3D12Resource *motion, ID3D12Resource *bias, ID3D12Resource *depth,
    UINT width, UINT height, UINT tiles_x, UINT tiles_y, UINT tile)
{
    static const char *shader = R"HLSL(
cbuffer Params : register(b0)
{
    uint OutputWidth;
    uint OutputHeight;
    uint GridWidth;
    uint GridHeight;
    uint Tile;
    uint RgbWidth;
    uint RgbHeight;
    uint Padding0;
};
ByteAddressBuffer PackedRgb : register(t0);
Texture2D<float2> PremultipliedMotion : register(t1);
Texture2D<float> Confidence : register(t2);
Texture2D<float> CompactDepth : register(t3);
RWTexture2D<float4> ColorOut : register(u0);
RWTexture2D<float2> MotionOut : register(u1);
RWTexture2D<float> BiasOut : register(u2);
RWTexture2D<float> DepthOut : register(u3);
SamplerState LinearClamp : register(s0);

float3 LoadRgb(int2 pixel)
{
    pixel = clamp(pixel, int2(0, 0), int2(RgbWidth - 1u, RgbHeight - 1u));
    uint address = (uint(pixel.y) * RgbWidth + uint(pixel.x)) * 3u;
    uint shift = (address & 3u) * 8u;
    uint2 words = PackedRgb.Load2(address & ~3u);
    // Reassemble the three unaligned bytes once. The previous form performed
    // three independent raw-buffer loads for each of 16 cubic taps.
    uint packed = shift == 0u ? words.x : ((words.x >> shift) | (words.y << (32u - shift)));
    return float3(packed & 255u, (packed >> 8u) & 255u, (packed >> 16u) & 255u) / 255.0;
}

float CubicWeight(float value)
{
    // Catmull-Rom cubic: sharp enough for a DLSS input while avoiding the
    // CPU Lanczos resize and its full-resolution memory round trip.
    float x = abs(value);
    if (x <= 1.0) return 1.5 * x * x * x - 2.5 * x * x + 1.0;
    if (x < 2.0) return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
    return 0.0;
}

float3 SampleRgbCubic(float2 position)
{
    int2 origin = int2(floor(position));
    float3 total = 0.0;
    float totalWeight = 0.0;
    [unroll] for (int y = -1; y <= 2; ++y)
    {
        float wy = CubicWeight(position.y - float(origin.y + y));
        [unroll] for (int x = -1; x <= 2; ++x)
        {
            float weight = wy * CubicWeight(position.x - float(origin.x + x));
            total += LoadRgb(origin + int2(x, y)) * weight;
            totalWeight += weight;
        }
    }
    return saturate(total / max(totalWeight, 1e-5));
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchId : SV_DispatchThreadID)
{
    if (dispatchId.x >= OutputWidth || dispatchId.y >= OutputHeight) return;
    float3 rgbColor;
    if (RgbWidth == OutputWidth && RgbHeight == OutputHeight)
    {
        rgbColor = LoadRgb(int2(dispatchId.xy));
    }
    else
    {
        float2 sourcePosition = (float2(dispatchId.xy) + 0.5) *
                                float2(RgbWidth, RgbHeight) /
                                float2(OutputWidth, OutputHeight) - 0.5;
        rgbColor = SampleRgbCubic(sourcePosition);
    }
    ColorOut[dispatchId.xy] = float4(rgbColor, 1.0);

    float2 gridUv = (float2(dispatchId.xy) + 0.5) /
                    (float2(GridWidth, GridHeight) * float(Tile));
    float confidence = Confidence.SampleLevel(LinearClamp, gridUv, 0);
    float2 weightedMotion = PremultipliedMotion.SampleLevel(LinearClamp, gridUv, 0);
    MotionOut[dispatchId.xy] = confidence > 1e-4 ? weightedMotion / confidence : 0.0;
    BiasOut[dispatchId.xy] = saturate(1.0 - confidence * 1.15);
    DepthOut[dispatchId.xy] = CompactDepth.SampleLevel(LinearClamp, gridUv, 0);
}
)HLSL";

    expander.width = width;
    expander.height = height;
    expander.tiles_x = tiles_x;
    expander.tiles_y = tiles_y;
    expander.tile = tile;
    expander.flow_grid = MakeTex(tiles_x, tiles_y, DXGI_FORMAT_R16G16_FLOAT, false);
    expander.confidence_grid = MakeTex(tiles_x, tiles_y, DXGI_FORMAT_R8_UNORM, false);
    expander.depth_grid = MakeTex(tiles_x, tiles_y, DXGI_FORMAT_R16_FLOAT, false);
    if (!expander.flow_grid || !expander.confidence_grid || !expander.depth_grid) return false;

    ID3DBlob *bytecode = nullptr, *errors = nullptr;
    HRESULT hr = D3DCompile(shader, strlen(shader), "gpu-input-expansion", nullptr, nullptr, "main", "cs_5_1",
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &bytecode, &errors);
    if (FAILED(hr))
    {
        if (errors) Log("[host] input expansion shader: %s", static_cast<const char *>(errors->GetBufferPointer()));
        if (errors) errors->Release();
        if (bytecode) bytecode->Release();
        return false;
    }
    if (errors) errors->Release();

    D3D12_DESCRIPTOR_RANGE ranges[2] = {};
    ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    ranges[0].NumDescriptors = 4;
    ranges[0].BaseShaderRegister = 0;
    ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
    ranges[1].NumDescriptors = 4;
    ranges[1].BaseShaderRegister = 0;
    D3D12_ROOT_PARAMETER parameters[3] = {};
    parameters[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameters[0].DescriptorTable.NumDescriptorRanges = 1;
    parameters[0].DescriptorTable.pDescriptorRanges = &ranges[0];
    parameters[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameters[1].DescriptorTable.NumDescriptorRanges = 1;
    parameters[1].DescriptorTable.pDescriptorRanges = &ranges[1];
    parameters[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    parameters[2].Constants.ShaderRegister = 0;
    parameters[2].Constants.Num32BitValues = 8;
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.ShaderRegister = 0;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    D3D12_ROOT_SIGNATURE_DESC signature = {};
    signature.NumParameters = _countof(parameters);
    signature.pParameters = parameters;
    signature.NumStaticSamplers = 1;
    signature.pStaticSamplers = &sampler;
    ID3DBlob *serialized = nullptr;
    hr = g_d3d12_serialize_root_signature(&signature, D3D_ROOT_SIGNATURE_VERSION_1, &serialized, &errors);
    if (FAILED(hr) || serialized == nullptr ||
        FAILED(h.dev->CreateRootSignature(0, serialized->GetBufferPointer(), serialized->GetBufferSize(),
                                          __uuidof(ID3D12RootSignature), reinterpret_cast<void **>(&expander.root))))
    {
        if (serialized) serialized->Release();
        if (errors) errors->Release();
        bytecode->Release();
        return false;
    }
    serialized->Release();
    if (errors) errors->Release();

    D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline = {};
    pipeline.pRootSignature = expander.root;
    pipeline.CS = {bytecode->GetBufferPointer(), bytecode->GetBufferSize()};
    hr = h.dev->CreateComputePipelineState(&pipeline, __uuidof(ID3D12PipelineState),
                                           reinterpret_cast<void **>(&expander.pso));
    bytecode->Release();
    if (FAILED(hr)) return false;

    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {};
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    heap_desc.NumDescriptors = static_cast<UINT>(pipeline_slots * 8);
    heap_desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    if (FAILED(h.dev->CreateDescriptorHeap(&heap_desc, __uuidof(ID3D12DescriptorHeap),
                                           reinterpret_cast<void **>(&expander.heap))))
        return false;
    expander.descriptor_size = h.dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    D3D12_CPU_DESCRIPTOR_HANDLE cpu = expander.heap->GetCPUDescriptorHandleForHeapStart();
    auto advance = [&]() { cpu.ptr += expander.descriptor_size; };
    for (int slot = 0; slot < pipeline_slots; ++slot)
    {
        D3D12_SHADER_RESOURCE_VIEW_DESC raw = {};
        raw.Format = DXGI_FORMAT_R32_TYPELESS;
        raw.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
        raw.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        raw.Buffer.NumElements = static_cast<UINT>(rgb_uploads[slot].size / 4);
        raw.Buffer.Flags = D3D12_BUFFER_SRV_FLAG_RAW;
        h.dev->CreateShaderResourceView(rgb_uploads[slot].buffer, &raw, cpu); advance();
        auto make_srv = [&](ID3D12Resource *resource, DXGI_FORMAT format)
        {
            D3D12_SHADER_RESOURCE_VIEW_DESC desc = {};
            desc.Format = format;
            desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
            desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            desc.Texture2D.MipLevels = 1;
            h.dev->CreateShaderResourceView(resource, &desc, cpu); advance();
        };
        make_srv(expander.flow_grid, DXGI_FORMAT_R16G16_FLOAT);
        make_srv(expander.confidence_grid, DXGI_FORMAT_R8_UNORM);
        make_srv(expander.depth_grid, DXGI_FORMAT_R16_FLOAT);
        auto make_uav = [&](ID3D12Resource *resource, DXGI_FORMAT format)
        {
            D3D12_UNORDERED_ACCESS_VIEW_DESC desc = {};
            desc.Format = format;
            desc.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
            h.dev->CreateUnorderedAccessView(resource, nullptr, &desc, cpu); advance();
        };
        make_uav(color, DXGI_FORMAT_R8G8B8A8_UNORM);
        make_uav(motion, DXGI_FORMAT_R16G16_FLOAT);
        make_uav(bias, DXGI_FORMAT_R8_UNORM);
        make_uav(depth, DXGI_FORMAT_R32_FLOAT);
    }
    return true;
}

static bool ExpandGpuInputs(
    GpuInputExpander &expander, int slot_index, ID3D12Resource *color, ID3D12Resource *motion,
    ID3D12Resource *bias, ID3D12Resource *depth, LinearTransfer &flow_upload,
    LinearTransfer &confidence_upload, LinearTransfer &depth_upload, RawUpload &rgb_upload,
    const std::vector<uint8_t> &rgb, const std::vector<uint16_t> &premultiplied_flow,
    const std::vector<uint8_t> &confidence, const std::vector<uint16_t> &compact_depth,
    UINT rgb_width, UINT rgb_height, bool outputs_common)
{
    const size_t rgb_bytes = static_cast<size_t>(rgb_width) * rgb_height * 3;
    if (rgb.size() != rgb_bytes || rgb_bytes > rgb_upload.size) return false;
    memcpy(rgb_upload.persistent_map, rgb.data(), rgb_bytes);
    if ((rgb_bytes & 3u) != 0) memset(rgb_upload.persistent_map + rgb_bytes, 0, 4 - (rgb_bytes & 3u));
    FillUpload(flow_upload, premultiplied_flow.data(), static_cast<size_t>(expander.tiles_x) * 4, expander.tiles_y);
    FillUpload(confidence_upload, confidence.data(), expander.tiles_x, expander.tiles_y);
    FillUpload(depth_upload, compact_depth.data(), static_cast<size_t>(expander.tiles_x) * 2, expander.tiles_y);
    if (!BeginCommands()) return false;
    const D3D12_RESOURCE_STATES grid_before = expander.grid_common ? D3D12_RESOURCE_STATE_COMMON
                                                                  : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    Transition(expander.flow_grid, grid_before, D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(expander.confidence_grid, grid_before, D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(expander.depth_grid, grid_before, D3D12_RESOURCE_STATE_COPY_DEST);
    CopyUploadToTexture(flow_upload, expander.flow_grid);
    CopyUploadToTexture(confidence_upload, expander.confidence_grid);
    CopyUploadToTexture(depth_upload, expander.depth_grid);
    Transition(expander.flow_grid, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(expander.confidence_grid, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(expander.depth_grid, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    expander.grid_common = false;

    const D3D12_RESOURCE_STATES output_before = outputs_common ? D3D12_RESOURCE_STATE_COMMON
                                                               : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    Transition(color, output_before, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Transition(motion, output_before, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Transition(bias, output_before, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Transition(depth, output_before, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    ID3D12DescriptorHeap *heaps[] = {expander.heap};
    h.list->SetDescriptorHeaps(1, heaps);
    h.list->SetComputeRootSignature(expander.root);
    h.list->SetPipelineState(expander.pso);
    D3D12_GPU_DESCRIPTOR_HANDLE gpu = expander.heap->GetGPUDescriptorHandleForHeapStart();
    gpu.ptr += static_cast<UINT64>(slot_index * 8) * expander.descriptor_size;
    h.list->SetComputeRootDescriptorTable(0, gpu);
    gpu.ptr += static_cast<UINT64>(4) * expander.descriptor_size;
    h.list->SetComputeRootDescriptorTable(1, gpu);
    const UINT constants[8] = {expander.width, expander.height, expander.tiles_x, expander.tiles_y,
                               expander.tile, rgb_width, rgb_height, 0};
    h.list->SetComputeRoot32BitConstants(2, 8, constants, 0);
    h.list->Dispatch((expander.width + 7) / 8, (expander.height + 7) / 8, 1);
    Transition(color, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(motion, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(bias, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(depth, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    EndCommands();
    return true;
}

static bool UploadBatchInputs(
    ID3D12Resource *color, ID3D12Resource *depth, ID3D12Resource *mv,
    ID3D12Resource *bias, ID3D12Resource *output,
    LinearTransfer &color_up, LinearTransfer &depth_up, LinearTransfer &mv_up, LinearTransfer &bias_up,
    const std::vector<uint8_t> &rgba, const std::vector<float> &depth_pixels,
    const std::vector<uint16_t> &motion_pixels, const std::vector<uint8_t> &bias_pixels,
    UINT width, UINT height, bool first)
{
    FillUpload(color_up, rgba.data(), static_cast<size_t>(width) * 4, height);
    FillUpload(depth_up, depth_pixels.data(), static_cast<size_t>(width) * sizeof(float), height);
    FillUpload(mv_up, motion_pixels.data(), static_cast<size_t>(width) * 2 * sizeof(uint16_t), height);
    FillUpload(bias_up, bias_pixels.data(), static_cast<size_t>(width), height);
    if (!BeginCommands()) return false;
    const D3D12_RESOURCE_STATES old_input = first ? D3D12_RESOURCE_STATE_COMMON
                                                   : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    Transition(color, old_input, D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(depth, old_input, D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(mv, old_input, D3D12_RESOURCE_STATE_COPY_DEST);
    Transition(bias, old_input, D3D12_RESOURCE_STATE_COPY_DEST);
    CopyUploadToTexture(color_up, color);
    CopyUploadToTexture(depth_up, depth);
    CopyUploadToTexture(mv_up, mv);
    CopyUploadToTexture(bias_up, bias);
    Transition(color, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(depth, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(mv, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(bias, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if (first) Transition(output, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    // The NGX queue is ordered.  Evaluation submitted immediately afterwards
    // cannot overtake these copies, so waiting here only serializes CPU and GPU.
    // Upload buffers are ring-buffered by the caller and are reused only after
    // the matching output fence has retired.
    EndCommands();
    return true;
}

static UINT64 SubmitBatchReadback(ID3D12Resource *output, LinearTransfer &readback)
{
    if (!BeginCommands()) return 0;
    Transition(output, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src = {}, dst = {};
    src.pResource = output;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.SubresourceIndex = 0;
    dst.pResource = readback.buffer;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint = readback.footprint;
    h.list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    Transition(output, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    return EndCommands();
}

// Display-only mode keeps the complete delivery path on the GPU.  The normal
// recording path must read RGB back for NVENC, but a live viewer can copy the
// Feature 18 output texture directly to the swapchain backbuffer.
static UINT64 CopyPreviewToSwapChain(ID3D12Resource *output, IDXGISwapChain3 *swap)
{
    if (output == nullptr || swap == nullptr) return 0;
    ID3D12Resource *bb = nullptr;
    if (FAILED(swap->GetBuffer(swap->GetCurrentBackBufferIndex(), __uuidof(ID3D12Resource),
                               reinterpret_cast<void **>(&bb))) || bb == nullptr)
        return 0;
    if (!BeginCommands()) { bb->Release(); return 0; }
    Transition(output, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    Transition(bb, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST);
    h.list->CopyResource(bb, output);
    Transition(bb, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT);
    Transition(output, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    const UINT64 fence = EndCommands();
    bb->Release();
    return fence;
}

static UINT64 SubmitBatchPreview(ID3D12Resource *output, ID3D12Resource *depth = nullptr,
                                 ID3D12Resource *motion = nullptr, UINT render_width = 0,
                                 UINT render_height = 0, bool reset = false)
{
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    if (!g_preview_direct || h.swap == nullptr || g_swap3 == nullptr) return 0;

    const UINT64 fence = CopyPreviewToSwapChain(output, g_swap3);
    if (fence == 0) return 0;
    sl::FrameToken *streamline_token = nullptr;
    const bool streamline_frame_ready = g_streamline_fg_requested &&
        PrepareStreamlineFrame(output, depth, motion, render_width, render_height,
                               g_preview_width, g_preview_height, reset, streamline_token);
    if (g_streamline_fg_enabled && !streamline_frame_ready)
        SuspendStreamlineFrameGeneration("invalid frame resources");
    const bool present_ok = streamline_frame_ready ? PresentStreamlineFrame(streamline_token)
                                                   : SUCCEEDED(h.swap->Present(0, 0));
    if (streamline_frame_ready && !present_ok)
    {
        fprintf(stderr,
                "HOST_DLSSG_FALLBACK reason=present_failed hresult=0x%08X backend=motion_gpu\n",
                static_cast<unsigned>(g_streamline_last_present_hresult));
        fflush(stderr);
    }
    // Never expose an empty/failed swap-chain. If DLSS-G rejects a present the
    // parent player stays hidden and restarts through the MotionGPU fallback,
    // instead of leaving a full-screen black window in front of the desktop.
    if (present_ok) RevealPreviewWindow();
    if (streamline_frame_ready && present_ok && g_streamline_fg_activate_after_present)
        ActivateStreamlineFrameGeneration();
    g_preview_has_frame = present_ok;
    return present_ok ? fence : 0;
}

static bool CollectBatchOutput(
    LinearTransfer &readback, std::vector<uint8_t> &rgb, UINT width, UINT height, UINT64 fence,
    double *wait_ms = nullptr, double *pack_ms = nullptr)
{
    const auto wait_begin = BatchClock::now();
    if (!WaitFenceValue(h.fence, fence, 30000)) return false;
    if (wait_ms != nullptr) *wait_ms += ElapsedMs(wait_begin);

    const auto pack_begin = BatchClock::now();
    uint8_t *mapped = nullptr;
    const D3D12_RANGE read = {0, static_cast<SIZE_T>(readback.total)};
    if (FAILED(readback.buffer->Map(0, &read, reinterpret_cast<void **>(&mapped))) || mapped == nullptr)
        return false;
    rgb.resize(static_cast<size_t>(width) * height * 3);
    const uint8_t *base = mapped + readback.footprint.Offset;
    #pragma omp parallel for schedule(static)
    for (int64_t yi = 0; yi < static_cast<int64_t>(height); ++yi)
    {
        const UINT y = static_cast<UINT>(yi);
        const uint8_t *row = base + static_cast<size_t>(y) * readback.footprint.Footprint.RowPitch;
        uint8_t *out = rgb.data() + static_cast<size_t>(y) * width * 3;
        for (UINT x = 0; x < width; ++x)
        {
            out[x * 3 + 0] = row[x * 4 + 0];
            out[x * 3 + 1] = row[x * 4 + 1];
            out[x * 3 + 2] = row[x * 4 + 2];
        }
    }
    const D3D12_RANGE none = {0, 0};
    readback.buffer->Unmap(0, &none);
    if (pack_ms != nullptr) *pack_ms += ElapsedMs(pack_begin);
    return true;
}

static void RgbToNv12(const std::vector<uint8_t> &rgb, std::vector<uint8_t> &nv12, UINT width, UINT height)
{
    const size_t y_bytes = static_cast<size_t>(width) * height;
    nv12.resize(y_bytes + y_bytes / 2);
    uint8_t *y_plane = nv12.data();
    uint8_t *uv_plane = y_plane + y_bytes;
    #pragma omp parallel for schedule(static)
    for (int64_t yi = 0; yi < static_cast<int64_t>(height); ++yi)
    {
        const UINT y = static_cast<UINT>(yi);
        const uint8_t *row = rgb.data() + static_cast<size_t>(y) * width * 3;
        uint8_t *out = y_plane + static_cast<size_t>(y) * width;
        for (UINT x = 0; x < width; ++x)
        {
            const int r = row[x * 3 + 0], g = row[x * 3 + 1], b = row[x * 3 + 2];
            out[x] = static_cast<uint8_t>(std::clamp(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16, 16, 235));
        }
    }
    #pragma omp parallel for schedule(static)
    for (int64_t uvi = 0; uvi < static_cast<int64_t>(height / 2); ++uvi)
    {
        const UINT y = static_cast<UINT>(uvi) * 2;
        uint8_t *out = uv_plane + static_cast<size_t>(uvi) * width;
        for (UINT x = 0; x < width; x += 2)
        {
            int r = 0, g = 0, b = 0;
            for (UINT dy = 0; dy < 2; ++dy)
                for (UINT dx = 0; dx < 2; ++dx)
                {
                    const size_t p = (static_cast<size_t>(y + dy) * width + x + dx) * 3;
                    r += rgb[p + 0]; g += rgb[p + 1]; b += rgb[p + 2];
                }
            r = (r + 2) >> 2; g = (g + 2) >> 2; b = (b + 2) >> 2;
            out[x + 0] = static_cast<uint8_t>(std::clamp(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128, 16, 240));
            out[x + 1] = static_cast<uint8_t>(std::clamp(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128, 16, 240));
        }
    }
}

static int RunBatch(const BatchOptions &o)
{
    try
    {
        // Realtime is a cooperative three-process pipeline: FFmpeg decode,
        // guide generation and this renderer must all advance while the
        // prepared-frame buffer is being consumed. HIGH priority here used to
        // starve the other two for an entire paced chunk at 1440p/4K, turning a
        // 30 ms decode into a 500-700 ms stall even though DLSS itself was fast.
        // Keep HIGH for offline throughput; live playback uses ABOVE_NORMAL so
        // all producer stages receive CPU time without lowering render quality.
        SetPriorityClass(GetCurrentProcess(), o.preview_only ? ABOVE_NORMAL_PRIORITY_CLASS
                                                             : HIGH_PRIORITY_CLASS);
        SetThreadPriority(GetCurrentThread(), o.preview_only ? THREAD_PRIORITY_NORMAL
                                                             : THREAD_PRIORITY_ABOVE_NORMAL);
        if ((!o.preview_only && o.output.empty() && o.encode_mp4.empty() && o.encode_chunks_dir.empty()) ||
            o.width == 0 || o.height == 0 || o.frames == 0 ||
            (!o.stream && (o.input.empty() || o.motion.empty() || o.depth.empty())))
            throw std::runtime_error("batch mode is missing an input/output/geometry argument");
        if (o.preview_only && (!o.stream || !o.preview))
            throw std::runtime_error("preview-only mode requires batch-stream preview");
        if (o.nvidia_frame_generation && (!o.preview_only || o.motion_frame_generation))
            throw std::runtime_error("NVIDIA DLSS-G requires preview-only mode and cannot be combined with MotionGPU");
        const UINT target_width = o.output_width == 0 ? o.width : o.output_width;
        const UINT target_height = o.output_height == 0 ? o.height : o.output_height;
        if (target_width < o.width || target_height < o.height)
            throw std::runtime_error("batch target dimensions must not be smaller than the render dimensions");
        std::ofstream output_file;
        FILE *encode_pipe = nullptr;
        PROCESS_INFORMATION encode_process = {};
        const bool chunk_encode_mode = o.stream && !o.encode_chunks_dir.empty();
        if (chunk_encode_mode)
        {
            fs::create_directories(o.encode_chunks_dir);
        }
        else if (!o.encode_mp4.empty())
        {
            if (o.codec != "h264" && o.codec != "h265")
                throw std::runtime_error("codec must be h264 or h265");
            if (o.quality > 51) throw std::runtime_error("quality must be between 0 and 51");
            const std::wstring encoder = o.codec == "h265" ? L"hevc_nvenc" : L"h264_nvenc";
            const std::wstring codec_tail = o.codec == "h265" ? L" -tag:v hvc1" : L"";
            const std::wstring command =
                L"ffmpeg -y -v error -f rawvideo -pixel_format nv12 -video_size " +
                std::to_wstring(target_width) + L"x" + std::to_wstring(target_height) +
                L" -framerate " + std::to_wstring(o.fps) +
                L" -i pipe:0 -frames:v " + std::to_wstring(o.frames) +
                L" -an -c:v " + encoder + L" -preset p1 -tune ll -rc constqp -qp " +
                std::to_wstring(o.quality) + codec_tail +
                L" -pix_fmt nv12 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv"
                L" -movflags +faststart \"" + o.encode_mp4.wstring() + L"\"";
            SECURITY_ATTRIBUTES sa = { sizeof(sa), nullptr, TRUE };
            HANDLE pipe_read = nullptr, pipe_write = nullptr;
            // _wpopen/CreatePipe defaults to a tiny anonymous-pipe buffer, which
            // throttles 4K RGB24 to a few FPS.  A multi-megabyte producer buffer
            // lets FFmpeg's converter/NVENC pipeline consume full frames in
            // parallel with DLSS instead of synchronizing on every 4 KiB write.
            if (!CreatePipe(&pipe_read, &pipe_write, &sa, 4u * 1024u * 1024u) ||
                !SetHandleInformation(pipe_write, HANDLE_FLAG_INHERIT, 0))
                throw std::runtime_error("cannot create the buffered NVENC pipe");
            HANDLE nul = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                     &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            STARTUPINFOW si = {};
            si.cb = sizeof(si);
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = pipe_read;
            si.hStdOutput = nul;
            si.hStdError = nul;
            std::vector<wchar_t> mutable_command(command.begin(), command.end());
            mutable_command.push_back(L'\0');
            const BOOL started = CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr, TRUE,
                                                CREATE_NO_WINDOW | CREATE_SUSPENDED | BELOW_NORMAL_PRIORITY_CLASS,
                                                nullptr, nullptr, &si, &encode_process);
            CloseHandle(pipe_read);
            if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
            if (!started)
            {
                CloseHandle(pipe_write);
                throw std::runtime_error("cannot start the direct NVENC encoder");
            }
            if (o.encoder_affinity_mask != 0)
                SetProcessAffinityMask(encode_process.hProcess, static_cast<DWORD_PTR>(o.encoder_affinity_mask));
            const int pipe_fd = _open_osfhandle(reinterpret_cast<intptr_t>(pipe_write), _O_BINARY | _O_WRONLY);
            encode_pipe = pipe_fd >= 0 ? _fdopen(pipe_fd, "wb") : nullptr;
            if (encode_pipe == nullptr)
            {
                if (pipe_fd >= 0) _close(pipe_fd); else CloseHandle(pipe_write);
                TerminateProcess(encode_process.hProcess, 1);
                throw std::runtime_error("cannot open the buffered NVENC pipe stream");
            }
            setvbuf(encode_pipe, nullptr, _IOFBF, 4u * 1024u * 1024u);
            ResumeThread(encode_process.hThread);
        }
        else if (!o.preview_only)
        {
            output_file.open(o.output, std::ios::binary | std::ios::trunc);
        }
        if (!o.preview_only && !chunk_encode_mode && encode_pipe == nullptr && !output_file)
            throw std::runtime_error("cannot open batch output");

        HANDLE chunk_ack_mapping = nullptr;
        volatile LONG64 *chunk_ack_counter = nullptr;
        if (o.stream && !o.chunk_ack_map.empty())
        {
            chunk_ack_mapping = OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE,
                                                  o.chunk_ack_map.c_str());
            if (chunk_ack_mapping == nullptr)
                throw std::runtime_error("cannot open the stream chunk acknowledgement mapping");
            chunk_ack_counter = static_cast<volatile LONG64 *>(
                MapViewOfFile(chunk_ack_mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(LONG64)));
            if (chunk_ack_counter == nullptr)
            {
                CloseHandle(chunk_ack_mapping);
                throw std::runtime_error("cannot map the stream chunk acknowledgement counter");
            }
        }

        std::unique_ptr<RgbInput> input;
        std::unique_ptr<MotionSidecar> motion_reader;
        std::unique_ptr<DepthSidecar> depth_reader;
        fs::path current_input, current_motion, current_depth;
        fs::path current_raw_output, current_video_output;
        uint32_t current_chunk_id = 0;
        uint32_t current_chunk_frames = 0;
        uint32_t current_rgb_width = o.width;
        uint32_t current_rgb_height = o.height;
        uint32_t chunk_frames_left = 0;
        double stream_wait_ms = 0.0;
        double stream_wait_max_ms = 0.0;
        double stream_underrun_max_ms = 0.0;
        uint32_t stream_wait_events = 0;
        uint32_t stream_underruns = 0;
        uint32_t stream_chunks_opened = 0;
        double last_stream_wait_ms = 0.0;
        bool last_stream_buffering_announced = false;
        double chunk_encode_ms = 0.0;
        double chunk_encode_wait_ms = 0.0;
        double pending_chunk_encode_ms = 0.0;
        std::exception_ptr chunk_encoder_error;
        std::jthread chunk_encoder_thread;
        auto run_encoder_process = [&](const std::wstring &command) -> DWORD
        {
            STARTUPINFOW startup = {};
            startup.cb = sizeof(startup);
            PROCESS_INFORMATION process = {};
            std::vector<wchar_t> mutable_command(command.begin(), command.end());
            mutable_command.push_back(L'\0');
            const DWORD creation_flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | BELOW_NORMAL_PRIORITY_CLASS;
            if (!CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr, FALSE,
                                creation_flags, nullptr, nullptr, &startup, &process))
                throw std::runtime_error("cannot start asynchronous NVENC encoder");
            if (o.encoder_affinity_mask != 0)
                SetProcessAffinityMask(process.hProcess, static_cast<DWORD_PTR>(o.encoder_affinity_mask));
            ResumeThread(process.hThread);
            const DWORD wait = WaitForSingleObject(process.hProcess, INFINITE);
            DWORD exit_code = 1;
            if (wait == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &exit_code);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            return exit_code;
        };
        auto join_chunk_encoder = [&]()
        {
            if (!chunk_encoder_thread.joinable()) return;
            const auto wait_begin = BatchClock::now();
            chunk_encoder_thread.join();
            chunk_encode_wait_ms += ElapsedMs(wait_begin);
            chunk_encode_ms += pending_chunk_encode_ms;
            if (chunk_encoder_error) std::rethrow_exception(chunk_encoder_error);
        };
        auto queue_chunk_encode = [&](const fs::path &raw_path, const fs::path &video_path,
                                      uint32_t frame_count)
        {
            // Keep one NVENC job in flight. The previous implementation called
            // _wsystem synchronously at every boundary, leaving Feature 18,
            // decode and guide generation idle for the whole encode. One
            // bounded worker overlaps the dedicated NVENC engine with the next
            // DLSS chunk without allowing unbounded processes or raw files.
            join_chunk_encoder();
            chunk_encoder_error = nullptr;
            pending_chunk_encode_ms = 0.0;
            const fs::path raw = raw_path;
            const fs::path video = video_path;
            const std::string codec = o.codec;
            const uint32_t quality = o.quality;
            const uint32_t fps = o.fps;
            const bool delete_raw = o.delete_chunks;
            chunk_encoder_thread = std::jthread(
                [&, raw, video, frame_count, codec, quality, fps, delete_raw]()
                {
                    const auto encode_begin = BatchClock::now();
                    try
                    {
                        const std::wstring encoder = codec == "h265" ? L"hevc_nvenc" : L"h264_nvenc";
                        const std::wstring codec_tail = codec == "h265" ? L" -tag:v hvc1" : L"";
                        const std::wstring encode_command =
                            L"ffmpeg -y -v error -f rawvideo -pixel_format rgb24 -video_size " +
                            std::to_wstring(target_width) + L"x" + std::to_wstring(target_height) +
                            L" -framerate " + std::to_wstring(fps) + L" -i \"" + raw.wstring() +
                            L"\" -frames:v " + std::to_wstring(frame_count) + L" -an -c:v " + encoder +
                            L" -preset p1 -tune ll -rc constqp -qp " + std::to_wstring(quality) + codec_tail +
                            L" -pix_fmt yuv420p -movflags +faststart \"" + video.wstring() + L"\"";
                        if (run_encoder_process(encode_command) != 0)
                            throw std::runtime_error("stream chunk NVENC encode failed");
                        if (delete_raw)
                        {
                            std::error_code ignored;
                            fs::remove(raw, ignored);
                        }
                    }
                    catch (...)
                    {
                        chunk_encoder_error = std::current_exception();
                    }
                    pending_chunk_encode_ms = ElapsedMs(encode_begin);
                });
        };
        auto open_chunk = [&](uint32_t id, uint32_t frames, const fs::path &rgb_path,
                              const fs::path &motion_path, const fs::path &depth_path,
                              uint32_t rgb_width, uint32_t rgb_height)
        {
            if (frames == 0) throw std::runtime_error("stream chunk has no frames");
            if (rgb_width == 0 || rgb_height == 0 || rgb_width > o.width || rgb_height > o.height)
                throw std::runtime_error("invalid compact RGB geometry");
            const uintmax_t expected_rgb = static_cast<uintmax_t>(rgb_width) * rgb_height * frames * 3;
            const bool shared_rgb = rgb_path.generic_string().rfind("shm://", 0) == 0;
            if (!shared_rgb && (!fs::is_regular_file(rgb_path) || fs::file_size(rgb_path) != expected_rgb))
                throw std::runtime_error("RGB24 input size mismatch");
            BatchOptions chunk_options = o;
            chunk_options.frames = frames;
            chunk_options.input = rgb_path;
            chunk_options.motion = motion_path;
            chunk_options.depth = depth_path;
            input = std::make_unique<RgbInput>(rgb_path, static_cast<size_t>(expected_rgb));
            motion_reader = std::make_unique<MotionSidecar>(motion_path, chunk_options);
            depth_reader = std::make_unique<DepthSidecar>(depth_path, chunk_options);
            current_chunk_id = id;
            current_chunk_frames = frames;
            current_rgb_width = rgb_width;
            current_rgb_height = rgb_height;
            chunk_frames_left = frames;
            current_input = rgb_path;
            current_motion = motion_path;
            current_depth = depth_path;
            if (chunk_encode_mode)
            {
                wchar_t name[64] = {};
                swprintf_s(name, L"chunk-%04u", id);
                current_raw_output = o.encode_chunks_dir / (std::wstring(name) + L".rgb");
                current_video_output = o.encode_chunks_dir / (std::wstring(name) + L".mp4");
                output_file.close();
                output_file.clear();
                output_file.open(current_raw_output, std::ios::binary | std::ios::trunc);
                if (!output_file) throw std::runtime_error("cannot open stream chunk output");
            }
        };
        std::deque<std::string> stream_command_queue;
        HANDLE stream_command_pipe = o.stream ? GetStdHandle(STD_INPUT_HANDLE) : INVALID_HANDLE_VALUE;
        std::array<char, 4096> stream_command_bytes = {};
        std::string stream_command_buffer;
        uint64_t stream_received_frames = 0;
        uint32_t stream_commands_received = 0;
        size_t stream_queue_peak = 0;
        if (o.stream && (stream_command_pipe == nullptr || stream_command_pipe == INVALID_HANDLE_VALUE))
            throw std::runtime_error("stream command pipe is unavailable");
        auto receive_stream_commands = [&]()
        {
            DWORD available = 0;
            if (!PeekNamedPipe(stream_command_pipe, nullptr, 0, nullptr, &available, nullptr))
                throw std::runtime_error("stream command pipe peek failed");
            if (available == 0) return;
            const DWORD requested = std::min<DWORD>(
                available, static_cast<DWORD>(stream_command_bytes.size()));
            DWORD byte_count = 0;
            if (!ReadFile(stream_command_pipe, stream_command_bytes.data(), requested, &byte_count, nullptr) ||
                byte_count == 0)
                throw std::runtime_error("stream command pipe closed early");
            stream_command_buffer.append(stream_command_bytes.data(), byte_count);
            for (;;)
            {
                const size_t newline = stream_command_buffer.find('\n');
                if (newline == std::string::npos) break;
                std::string incoming = stream_command_buffer.substr(0, newline);
                stream_command_buffer.erase(0, newline + 1);
                if (!incoming.empty() && incoming.back() == '\r') incoming.pop_back();
                std::string parse_line = incoming;
                const size_t command_start = parse_line.find("CHUNK");
                if (command_start != std::string::npos && command_start > 0)
                    parse_line.erase(0, command_start);
                std::istringstream command(parse_line);
                std::string tag, id_text, frames_text;
                std::getline(command, tag, '\t');
                std::getline(command, id_text, '\t');
                std::getline(command, frames_text, '\t');
                if (tag != "CHUNK" || frames_text.empty())
                    throw std::runtime_error("invalid stream chunk command");
                const uint32_t frames = static_cast<uint32_t>(strtoul(frames_text.c_str(), nullptr, 10));
                if (frames == 0 || stream_received_frames + frames > o.frames)
                    throw std::runtime_error("stream chunk frame total mismatch");
                stream_command_queue.push_back(std::move(incoming));
                stream_received_frames += frames;
                ++stream_commands_received;
                stream_queue_peak = std::max(stream_queue_peak, stream_command_queue.size());
            }
        };
        auto read_stream_chunk = [&]()
        {
            const auto stream_wait_begin = BatchClock::now();
            std::string line;
            last_stream_buffering_announced = false;
            for (;;)
            {
                receive_stream_commands();
                if (!stream_command_queue.empty())
                {
                    line = std::move(stream_command_queue.front());
                    stream_command_queue.pop_front();
                    break;
                }
                if (stream_received_frames >= o.frames)
                    throw std::runtime_error("stream command queue ended early");
                if (o.preview_only && stream_chunks_opened > 0 && !last_stream_buffering_announced &&
                    ElapsedMs(stream_wait_begin) > 20.0)
                {
                    char command[96] = {};
                    sprintf_s(command, "BUFFERING %.6f", CurrentPreviewSeconds());
                    WritePreviewControl(command);
                    last_stream_buffering_announced = true;
                    printf("HOST_BUFFERING_START media_seconds=%.6f\n", CurrentPreviewSeconds());
                    fflush(stdout);
                }
                PumpPresent();
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            const double waited_ms = ElapsedMs(stream_wait_begin);
            last_stream_wait_ms = waited_ms;
            stream_wait_ms += waited_ms;
            stream_wait_max_ms = std::max(stream_wait_max_ms, waited_ms);
            ++stream_wait_events;
            // Waiting for the very first chunk is intentional startup
            // buffering.  Any later wait longer than one scheduler quantum is
            // a visible buffer underrun and must be reported separately.
            if (o.preview_only && stream_chunks_opened > 0 && waited_ms > 8.0)
            {
                ++stream_underruns;
                stream_underrun_max_ms = std::max(stream_underrun_max_ms, waited_ms);
                Log("[host] REALTIME_BUFFER_UNDERRUN chunk=%u wait_ms=%.3f", stream_chunks_opened, waited_ms);
            }
            const size_t command_start = line.find("CHUNK");
            if (command_start != std::string::npos && command_start > 0)
                line.erase(0, command_start); // tolerate a UTF-8 BOM on redirected stdin
            std::istringstream command(line);
            std::string tag, id_text, frames_text, rgb_text, motion_text, depth_text;
            std::string rgb_width_text, rgb_height_text;
            std::getline(command, tag, '\t');
            std::getline(command, id_text, '\t');
            std::getline(command, frames_text, '\t');
            std::getline(command, rgb_text, '\t');
            std::getline(command, motion_text, '\t');
            std::getline(command, depth_text, '\t');
            std::getline(command, rgb_width_text, '\t');
            std::getline(command, rgb_height_text, '\t');
            if (tag != "CHUNK" || id_text.empty() || frames_text.empty() || rgb_text.empty() ||
                motion_text.empty() || depth_text.empty())
                throw std::runtime_error("invalid stream chunk command");
            open_chunk(static_cast<uint32_t>(strtoul(id_text.c_str(), nullptr, 10)),
                       static_cast<uint32_t>(strtoul(frames_text.c_str(), nullptr, 10)),
                       fs::u8path(rgb_text), fs::u8path(motion_text), fs::u8path(depth_text),
                       rgb_width_text.empty() ? o.width : static_cast<uint32_t>(strtoul(rgb_width_text.c_str(), nullptr, 10)),
                       rgb_height_text.empty() ? o.height : static_cast<uint32_t>(strtoul(rgb_height_text.c_str(), nullptr, 10)));
            ++stream_chunks_opened;
        };
        if (!o.stream) open_chunk(0, o.frames, o.input, o.motion, o.depth, o.width, o.height);

        Log("[host] --batch%s: render=%ux%u target=%ux%u, %u frame(s), output=%s, fast_start=%d, genuine D3D12 DLSS contract + inline NR",
            o.stream ? "-stream" : "", o.width, o.height, target_width, target_height, o.frames,
            o.preview_only ? "display-only" : "recording", o.fast_start ? 1 : 0);
        if (o.fast_start && g_renodx_lazy)
        {
            // The current add-on installs its NGX detours during InitNgx and
            // rescans on every present, so the legacy fixed 960 ms settle delay
            // is pure startup latency.  Keep two presents for lazy adoption.
            PumpPresent();
            PumpPresent();
        }
        else
        {
            for (int i = 0; i < 120; ++i) { PumpPresent(); Sleep(8); }
        }

        ID3D12Resource *color = MakeTex(o.width, o.height, DXGI_FORMAT_R8G8B8A8_UNORM, true);
        ID3D12Resource *output_tex = MakeTex(target_width, target_height, DXGI_FORMAT_R8G8B8A8_UNORM, true);
        ID3D12Resource *depth = MakeTex(o.width, o.height, DXGI_FORMAT_R32_FLOAT, true);
        ID3D12Resource *mv = MakeTex(o.width, o.height, DXGI_FORMAT_R16G16_FLOAT, true);
        ID3D12Resource *bias = MakeTex(o.width, o.height, DXGI_FORMAT_R8_UNORM, true);
        if (!color || !output_tex || !depth || !mv || !bias) throw std::runtime_error("batch texture allocation failed");
        MotionFrameGeneration frame_generation = {};
        if (o.preview_only && o.motion_frame_generation &&
            !InitMotionFrameGeneration(frame_generation, output_tex, mv, bias, target_width, target_height))
            throw std::runtime_error("motion-compensated GPU frame generation initialization failed");
        constexpr int kPipeline = 3;
        LinearTransfer color_up[kPipeline], depth_up[kPipeline], mv_up[kPipeline], bias_up[kPipeline], readback[kPipeline];
        LinearTransfer compact_flow_up[kPipeline], compact_confidence_up[kPipeline], compact_depth_up[kPipeline];
        RawUpload raw_rgb_up[kPipeline];
        for (int i = 0; i < kPipeline; ++i)
        {
            color_up[i] = MakeTransfer(color, D3D12_HEAP_TYPE_UPLOAD);
            depth_up[i] = MakeTransfer(depth, D3D12_HEAP_TYPE_UPLOAD);
            mv_up[i] = MakeTransfer(mv, D3D12_HEAP_TYPE_UPLOAD);
            bias_up[i] = MakeTransfer(bias, D3D12_HEAP_TYPE_UPLOAD);
            raw_rgb_up[i] = MakeRawUpload(static_cast<UINT64>(o.width) * o.height * 3);
            if (!o.preview_only) readback[i] = MakeTransfer(output_tex, D3D12_HEAP_TYPE_READBACK);
        }
        GpuInputExpander input_expander = {};
        bool input_expander_initialized = false;
        auto ensure_input_expander = [&]()
        {
            if (input_expander_initialized) return;
            if (!motion_reader || !depth_reader) throw std::runtime_error("guide sidecars are unavailable");
            if (motion_reader->Tile() != depth_reader->Tile() ||
                motion_reader->TilesX() != depth_reader->TilesX() ||
                motion_reader->TilesY() != depth_reader->TilesY())
                throw std::runtime_error("motion/depth compact-grid mismatch");
            if (!InitGpuInputExpander(input_expander, raw_rgb_up, kPipeline, color, mv, bias, depth,
                                      o.width, o.height, motion_reader->TilesX(), motion_reader->TilesY(),
                                      motion_reader->Tile()))
                throw std::runtime_error("GPU input expansion initialization failed");
            for (int i = 0; i < kPipeline; ++i)
            {
                compact_flow_up[i] = MakeTransfer(input_expander.flow_grid, D3D12_HEAP_TYPE_UPLOAD);
                compact_confidence_up[i] = MakeTransfer(input_expander.confidence_grid, D3D12_HEAP_TYPE_UPLOAD);
                compact_depth_up[i] = MakeTransfer(input_expander.depth_grid, D3D12_HEAP_TYPE_UPLOAD);
            }
            input_expander_initialized = true;
            Log("[host] GPU input expansion active: RGB24 + %ux%u compact motion/depth -> %ux%u",
                input_expander.tiles_x, input_expander.tiles_y, o.width, o.height);
        };

        const int flags = NVSDK_NGX_DLSS_Feature_Flags_MVLowRes |
                          NVSDK_NGX_DLSS_Feature_Flags_AutoExposure |
                          NVSDK_NGX_DLSS_Feature_Flags_DepthInverted;
        NVSDK_NGX_Result create_result = NVSDK_NGX_Result_Fail;
        if (!CreateFeature(o.width, o.height, flags, &create_result, target_width, target_height))
            throw std::runtime_error("genuine DLSS feature creation failed");
        if (o.nvidia_frame_generation &&
            !EnableStreamlineFrameGeneration(o.width, o.height, target_width, target_height,
                                             o.nvidia_dynamic_mfg,
                                             o.nvidia_generated_frames,
                                             o.nvidia_dynamic_target_fps))
            throw std::runtime_error("NVIDIA DLSS Frame Generation initialization failed; inspect sl.log");
        if (o.stream)
        {
            printf("HOST_STREAM_READY\n");
            fflush(stdout);
        }

        const size_t pixels = static_cast<size_t>(o.width) * o.height;
        struct PreparedBatchFrame
        {
            std::vector<uint8_t> rgb;
            std::vector<uint16_t> premultiplied_motion;
            std::vector<uint8_t> confidence;
            std::vector<uint16_t> compact_depth;
            double input_ms = 0.0;
            double guides_ms = 0.0;
            bool reset = false;
            std::exception_ptr error;
        } prepared[kPipeline];
        for (auto &slot : prepared)
        {
            slot.rgb.resize(pixels * 3);
        }
        std::vector<uint8_t> out_rgb[kPipeline];
        struct PendingOutput
        {
            UINT64 fence = 0;
            uint32_t frame = 0;
            bool active = false;
        } pending[kPipeline];
        double input_ms = 0.0, guides_ms = 0.0, upload_ms = 0.0;
        double evaluate_submit_ms = 0.0, readback_ms = 0.0, write_ms = 0.0;
        double readback_gpu_ms = 0.0, readback_pack_ms = 0.0;
        double prefetch_wait_ms = 0.0;
        double writer_wait_ms = 0.0;
        double pending_write_ms = 0.0;
        double warmup_ms = 0.0;
        double startup_warmup_ms = 0.0;
        double preview_pacing_ms = 0.0;
        BatchClock::time_point preview_start = {};
        BatchClock::time_point preview_first_present = {}, preview_last_present = {};
        uint64_t preview_presented = 0;
        uint32_t streamline_max_presented_per_render = 0;
        std::vector<uint8_t> encode_nv12;
        std::exception_ptr writer_error;
        std::jthread writer_thread;

        if (o.fast_start)
        {
            // Prime the lazily-created Feature 18 while the controller decodes
            // and builds the first real motion/depth chunk.  The real first
            // frame is evaluated with reset=1 afterwards, so this changes
            // latency without leaking synthetic history into the video.
            const auto startup_warmup_begin = BatchClock::now();
            std::vector<uint8_t> bootstrap_rgba(pixels * 4, 0);
            #pragma omp parallel for schedule(static)
            for (int64_t pi = 0; pi < static_cast<int64_t>(pixels); ++pi)
                bootstrap_rgba[static_cast<size_t>(pi) * 4 + 3] = 255;
            std::vector<float> bootstrap_depth(pixels, 0.5f);
            std::vector<uint16_t> bootstrap_motion(pixels * 2, 0);
            std::vector<uint8_t> bootstrap_bias(pixels, 0);
            if (!UploadBatchInputs(color, depth, mv, bias, output_tex,
                                   color_up[0], depth_up[0], mv_up[0], bias_up[0],
                                   bootstrap_rgba, bootstrap_depth, bootstrap_motion, bootstrap_bias,
                                   o.width, o.height, true) ||
                !Evaluate(color, output_tex, depth, mv, o.width, o.height, 1, 1.0f, 1.0f, bias) ||
                !WaitFenceValue(h.fence, h.fence_value, 30000))
                throw std::runtime_error("DLAA/NR startup warm-up failed");
            startup_warmup_ms = ElapsedMs(startup_warmup_begin);
            Log("[host] Feature 18 startup warm-up completed in %.3f ms (overlapped with first guide chunk)",
                startup_warmup_ms);
        }
        auto write_output = [&](const std::vector<uint8_t> &buffer)
        {
            if (encode_pipe != nullptr)
            {
                RgbToNv12(buffer, encode_nv12, target_width, target_height);
                const size_t written = fwrite(encode_nv12.data(), 1, encode_nv12.size(), encode_pipe);
                if (written != encode_nv12.size()) throw std::runtime_error("NVENC pipe write failed");
            }
            else
            {
                output_file.write(reinterpret_cast<const char *>(buffer.data()),
                                  static_cast<std::streamsize>(buffer.size()));
                if (!output_file) throw std::runtime_error("RGB24 output write failed");
            }
        };
        auto join_writer = [&]()
        {
            if (!writer_thread.joinable()) return;
            const auto wait_begin = BatchClock::now();
            writer_thread.join();
            writer_wait_ms += ElapsedMs(wait_begin);
            if (writer_error) std::rethrow_exception(writer_error);
            write_ms += pending_write_ms;
        };
        auto prepare_frame = [&](PreparedBatchFrame &slot)
        {
            slot.error = nullptr;
            try
            {
                auto phase_begin = BatchClock::now();
                if (!input || !motion_reader || !depth_reader)
                    throw std::runtime_error("batch chunk is not open");
                slot.rgb.resize(static_cast<size_t>(current_rgb_width) * current_rgb_height * 3);
                if (!input->ReadExact(slot.rgb.data(), slot.rgb.size()))
                    throw std::runtime_error("truncated RGB24 input");
                slot.input_ms = ElapsedMs(phase_begin);
                phase_begin = BatchClock::now();
                slot.reset = motion_reader->ReadCompact(slot.premultiplied_motion, slot.confidence);
                depth_reader->ReadCompact(slot.compact_depth);
                slot.guides_ms = ElapsedMs(phase_begin);
            }
            catch (...)
            {
                slot.error = std::current_exception();
            }
        };

        auto collect_output = [&](int slot_index)
        {
            PendingOutput &item = pending[slot_index];
            if (!item.active) return;
            auto phase_begin = BatchClock::now();
            if (o.preview_only)
            {
                const auto wait_begin = BatchClock::now();
                if (!WaitFenceValue(h.fence, item.fence, 30000))
                    throw std::runtime_error("GPU preview submission failed");
                readback_gpu_ms += ElapsedMs(wait_begin);
            }
            else if (!CollectBatchOutput(readback[slot_index], out_rgb[slot_index], target_width, target_height,
                                         item.fence, &readback_gpu_ms, &readback_pack_ms))
            {
                throw std::runtime_error("GPU output readback failed");
            }
            readback_ms += ElapsedMs(phase_begin);
            if (!o.preview_only) PresentBatchRgb(out_rgb[slot_index], target_width, target_height);

            if (o.preview_only)
            {
                // Nothing is encoded or written in the real-time profile.
            }
            else if (o.async_write)
            {
                // Packing the next completed frame can overlap the previous
                // NVENC pipe write; join only before publishing a new buffer.
                join_writer();
                writer_error = nullptr;
                pending_write_ms = 0.0;
                std::vector<uint8_t> &write_buffer = out_rgb[slot_index];
                writer_thread = std::jthread([&write_output, &write_buffer, &writer_error, &pending_write_ms]()
                {
                    const auto write_begin = BatchClock::now();
                    try
                    {
                        write_output(write_buffer);
                        pending_write_ms = ElapsedMs(write_begin);
                    }
                    catch (...)
                    {
                        writer_error = std::current_exception();
                    }
                });
            }
            else
            {
                phase_begin = BatchClock::now();
                write_output(out_rgb[slot_index]);
                write_ms += ElapsedMs(phase_begin);
            }
            if (!o.quiet_frames) Log("[host] batch frame %u/%u delivered", item.frame + 1, o.frames);
            item.active = false;
        };

        const auto batch_begin = BatchClock::now();
        for (uint32_t frame = 0; frame < o.frames; ++frame)
        {
            if (o.preview_only && g_preview_paused)
            {
                const auto pause_begin = BatchClock::now();
                while (g_preview_paused)
                {
                    if (o.stream) receive_stream_commands();
                    PumpPresent();
                    std::this_thread::sleep_for(std::chrono::milliseconds(8));
                }
                const auto pause_duration = BatchClock::now() - pause_begin;
                if (preview_start.time_since_epoch().count() != 0) preview_start += pause_duration;
                preview_pacing_ms += std::chrono::duration<double, std::milli>(pause_duration).count();
            }
            // Drain newly published chunk commands while the current chunk is
            // rendering.  Waiting until the boundary makes PeekNamedPipe race
            // the controller and turns ordinary Windows scheduling latency
            // into a visible stall even though several seconds are buffered.
            if (o.stream) receive_stream_commands();
            if (chunk_frames_left == 0)
            {
                if (!o.stream) throw std::runtime_error("batch input ended before the declared frame count");
                read_stream_chunk();
                if (o.preview_only && stream_chunks_opened > 1 && last_stream_wait_ms > 8.0 &&
                    preview_start.time_since_epoch().count() != 0)
                {
                    preview_start += std::chrono::duration_cast<BatchClock::duration>(
                        std::chrono::duration<double, std::milli>(last_stream_wait_ms));
                }
                if (o.preview_only && last_stream_buffering_announced)
                {
                    char command[96] = {};
                    sprintf_s(command, "BUFFER_READY %.6f", CurrentPreviewSeconds());
                    WritePreviewControl(command);
                    printf("HOST_BUFFERING_END media_seconds=%.6f wait_ms=%.3f\n",
                           CurrentPreviewSeconds(), last_stream_wait_ms);
                    fflush(stdout);
                }
                if (chunk_frames_left > o.frames - frame)
                    throw std::runtime_error("stream chunks exceed the declared frame count");
            }
            ensure_input_expander();
            const int slot_index = static_cast<int>(frame % kPipeline);
            PreparedBatchFrame &current = prepared[slot_index];
            prepare_frame(current);
            if (current.error) std::rethrow_exception(current.error);
            input_ms += current.input_ms;
            guides_ms += current.guides_ms;

            // Waiting only when a ring slot is about to be reused keeps up to
            // three complete DLSS frames in flight while CPU preparation runs.
            collect_output(slot_index);

            PumpPresent();

            auto phase_begin = BatchClock::now();
            if (!ExpandGpuInputs(input_expander, slot_index, color, mv, bias, depth,
                                 compact_flow_up[slot_index], compact_confidence_up[slot_index],
                                 compact_depth_up[slot_index], raw_rgb_up[slot_index],
                                 current.rgb, current.premultiplied_motion, current.confidence,
                                 current.compact_depth, current_rgb_width, current_rgb_height,
                                 frame == 0 && !o.fast_start))
                throw std::runtime_error("GPU compact-input expansion failed");
            upload_ms += ElapsedMs(phase_begin);
            const int reset = (frame == 0 || current.reset || o.reset_every_frame) ? 1 : 0;

            // Feature 18 is created lazily by the add-on on the first evaluate.
            // Prime it with the first real frame, discard that result, then reset
            // and evaluate the same frame for delivery.  This keeps initialization
            // out of the steady-state FPS metric and avoids an under-refined first
            // output frame without inventing synthetic guides.
            if (frame == 0 && !o.fast_start)
            {
                const auto warmup_begin = BatchClock::now();
                if (!Evaluate(color, output_tex, depth, mv, o.width, o.height, 1, 1.0f, 1.0f, bias))
                    throw std::runtime_error("DLAA/NR warm-up evaluate failed");
                if (o.preview_only)
                {
                    if (!WaitFenceValue(h.fence, h.fence_value, 30000))
                        throw std::runtime_error("DLAA/NR warm-up did not finish");
                }
                else
                {
                    const UINT64 warmup_fence = SubmitBatchReadback(output_tex, readback[slot_index]);
                    std::vector<uint8_t> warmup_rgb;
                    if (warmup_fence == 0 ||
                        !CollectBatchOutput(readback[slot_index], warmup_rgb, target_width, target_height, warmup_fence))
                        throw std::runtime_error("DLAA/NR warm-up readback failed");
                }
                warmup_ms = ElapsedMs(warmup_begin);
                Log("[host] Feature 18 warm-up completed in %.3f ms", warmup_ms);
            }

            phase_begin = BatchClock::now();
            if (!Evaluate(color, output_tex, depth, mv, o.width, o.height, reset, 1.0f, 1.0f, bias))
                throw std::runtime_error("DLAA/NR evaluate failed");
            evaluate_submit_ms += ElapsedMs(phase_begin);

            UINT64 readback_fence = 0;
            if (o.preview_only)
            {
                if (frame > 0 && o.motion_frame_generation)
                {
                    const auto pace_begin = BatchClock::now();
                    const auto generated_target = preview_start + std::chrono::duration_cast<BatchClock::duration>(
                        std::chrono::duration<double>((static_cast<double>(frame) - 0.5) / o.fps));
                    if (BatchClock::now() < generated_target) std::this_thread::sleep_until(generated_target);
                    preview_pacing_ms += ElapsedMs(pace_begin);
                    if (GenerateMotionFrame(frame_generation, output_tex, o.width, o.height, target_width, target_height) == 0 ||
                        SubmitBatchPreview(frame_generation.generated) == 0)
                        throw std::runtime_error("motion-compensated generated-frame submission failed");
                    preview_last_present = BatchClock::now();
                    ++preview_presented;
                }
                if (frame > 0 && o.fps > 0)
                {
                    const auto pace_begin = BatchClock::now();
                    const auto target = preview_start + std::chrono::duration_cast<BatchClock::duration>(
                        std::chrono::duration<double>(static_cast<double>(frame) / o.fps));
                    if (BatchClock::now() < target) std::this_thread::sleep_until(target);
                    preview_pacing_ms += ElapsedMs(pace_begin);
                }
                readback_fence = SubmitBatchPreview(output_tex, depth, mv, o.width, o.height, reset != 0);
                // Present() only queues the swap-chain work.  The first real
                // Feature 18 evaluation can still be compiling asynchronously
                // for several seconds, so do not start video/audio clocks until
                // that first GPU result is actually complete.  This is a single
                // startup wait; later frames remain pipelined through kPipeline.
                if (frame == 0 && readback_fence != 0 &&
                    !WaitFenceValue(h.fence, readback_fence, 30000))
                    throw std::runtime_error("first GPU preview frame did not complete");
                const auto presented_at = BatchClock::now();
                UpdatePreviewTimeline(frame);
                UpdatePreviewPerformance(g_streamline_fg_requested ? g_streamline_last_present_count : 1u);
                if (preview_presented == 0)
                {
                    // The first Evaluate/copy/Present may initialize shaders and
                    // swap-chain resources.  Starting the media clock before
                    // that work makes every later target timestamp artificially
                    // late, so playback races through the prebuffer to catch up.
                    // Anchor frame zero to its actual first presentation instead.
                    preview_start = presented_at;
                    preview_first_present = presented_at;
                    char command[96] = {};
                    sprintf_s(command, "PLAYING %.6f", CurrentPreviewSeconds());
                    WritePreviewControl(command);
                }
                preview_last_present = presented_at;
                preview_presented += g_streamline_fg_requested ? g_streamline_last_present_count : 1u;
                if (g_streamline_fg_requested)
                    streamline_max_presented_per_render = std::max(streamline_max_presented_per_render,
                                                                   g_streamline_last_present_count);
                if (o.motion_frame_generation && CopyMotionFrameHistory(frame_generation, output_tex) == 0)
                    throw std::runtime_error("frame-generation history update failed");
            }
            else
            {
                readback_fence = SubmitBatchReadback(output_tex, readback[slot_index]);
            }
            if (readback_fence == 0) throw std::runtime_error("GPU output readback submission failed");
            pending[slot_index].fence = readback_fence;
            pending[slot_index].frame = frame;
            pending[slot_index].active = true;

            --chunk_frames_left;
            if (o.stream && chunk_frames_left == 0)
            {
                input.reset();
                motion_reader.reset();
                depth_reader.reset();
                if (o.delete_chunks)
                {
                    std::error_code ignored;
                    if (current_input.generic_string().rfind("shm://", 0) != 0) fs::remove(current_input, ignored);
                    if (current_motion.generic_string().rfind("shm://", 0) != 0) fs::remove(current_motion, ignored);
                    if (current_depth.generic_string().rfind("shm://", 0) != 0) fs::remove(current_depth, ignored);
                }
                // Every byte from the chunk has already been copied into the
                // per-slot upload ring. Acknowledging now lets the controller
                // replenish the realtime queue while D3D12 finishes in flight.
                // collect_output/BeginCommands still fence each slot before it
                // is reused, so this removes a chunk-wide drain without changing
                // resource lifetime or rendered pixels.
                if (chunk_encode_mode)
                {
                    const uint32_t pending_begin = frame + 1 > kPipeline ? frame + 1 - kPipeline : 0;
                    for (uint32_t pending_frame = pending_begin; pending_frame <= frame; ++pending_frame)
                        collect_output(static_cast<int>(pending_frame % kPipeline));
                    join_writer();
                    output_file.flush();
                    output_file.close();
                    queue_chunk_encode(current_raw_output, current_video_output, current_chunk_frames);
                }
                if (chunk_ack_counter != nullptr)
                {
                    InterlockedIncrement64(chunk_ack_counter);
                }
                else
                {
                    printf("HOST_CHUNK_SUBMITTED %u %u\n", current_chunk_id, frame + 1);
                    fflush(stdout);
                }
            }
        }

        const uint32_t drain_begin = o.frames > kPipeline ? o.frames - kPipeline : 0;
        for (uint32_t frame = drain_begin; frame < o.frames; ++frame)
            collect_output(static_cast<int>(frame % kPipeline));
        join_writer();
        join_chunk_encoder();
        if (encode_pipe != nullptr)
        {
            fflush(encode_pipe);
            fclose(encode_pipe);
            encode_pipe = nullptr;
            if (WaitForSingleObject(encode_process.hProcess, 30000) != WAIT_OBJECT_0)
                throw std::runtime_error("direct NVENC encoder did not finish");
            DWORD encoder_exit = 1;
            GetExitCodeProcess(encode_process.hProcess, &encoder_exit);
            CloseHandle(encode_process.hThread);
            CloseHandle(encode_process.hProcess);
            if (encoder_exit != 0) throw std::runtime_error("direct NVENC encode failed");
        }
        else
        {
            if (output_file.is_open()) output_file.flush();
        }
        const double wall_total_ms = ElapsedMs(batch_begin);
        const double recording_pipeline_ms = std::max(
            0.0, wall_total_ms - warmup_ms - stream_wait_ms - preview_pacing_ms);
        const double total_ms = std::max(0.0, recording_pipeline_ms - chunk_encode_wait_ms);
        const double chunk_encode_overlap_ms = std::max(0.0, chunk_encode_ms - chunk_encode_wait_ms);
        const double preview_present_fps = preview_presented > 1
            ? 1000.0 * static_cast<double>(preview_presented - 1) /
              std::chrono::duration<double, std::milli>(preview_last_present - preview_first_present).count()
            : 0.0;
        if (o.timings)
        {
            const double frames = static_cast<double>(o.frames);
            Log("[host] DLSS5_BATCH_TIMING frames=%u pipeline=%d prefetch=%d async_write=%d total_ms=%.3f wall_total_ms=%.3f recording_pipeline_ms=%.3f warmup_ms=%.3f startup_warmup_ms=%.3f stream_wait_ms=%.3f stream_wait_max_ms=%.3f stream_wait_events=%u stream_commands_received=%u stream_queue_peak=%zu buffer_underruns=%u buffer_underrun_max_ms=%.3f chunk_encode_ms=%.3f chunk_encode_wait_ms=%.3f chunk_encode_overlap_ms=%.3f preview_pacing_ms=%.3f preview_present_fps=%.3f per_frame_ms=%.3f input_ms=%.3f guides_ms=%.3f prefetch_wait_ms=%.3f writer_wait_ms=%.3f upload_ms=%.3f submit_ms=%.3f readback_ms=%.3f readback_wait_ms=%.3f readback_pack_ms=%.3f write_ms=%.3f",
                o.frames, kPipeline, o.prefetch ? 1 : 0, o.async_write ? 1 : 0, total_ms, wall_total_ms, recording_pipeline_ms, warmup_ms, startup_warmup_ms, stream_wait_ms, stream_wait_max_ms, stream_wait_events, stream_commands_received, stream_queue_peak, stream_underruns, stream_underrun_max_ms, chunk_encode_ms, chunk_encode_wait_ms, chunk_encode_overlap_ms, preview_pacing_ms, preview_present_fps, total_ms / frames,
                input_ms / frames, guides_ms / frames, prefetch_wait_ms / frames,
                writer_wait_ms / frames, upload_ms / frames,
                evaluate_submit_ms / frames, readback_ms / frames,
                readback_gpu_ms / frames, readback_pack_ms / frames,
                write_ms / frames);
        }
        if (o.nvidia_frame_generation)
        {
            const uint64_t generated = preview_presented > o.frames ? preview_presented - o.frames : 0;
            const double actual_multiplier = o.frames > 0
                ? static_cast<double>(preview_presented) / static_cast<double>(o.frames) : 0.0;
            printf("HOST_DLSSG_STATS real_frames=%u presented=%llu generated=%llu actual_multiplier=%.4f max_per_render=%u\n",
                   o.frames, static_cast<unsigned long long>(preview_presented),
                   static_cast<unsigned long long>(generated), actual_multiplier,
                   streamline_max_presented_per_render);
            fflush(stdout);
            Log("[streamline] aggregate real=%u presented=%llu generated=%llu multiplier=%.4f max_per_render=%u",
                o.frames, static_cast<unsigned long long>(preview_presented),
                static_cast<unsigned long long>(generated), actual_multiplier,
                streamline_max_presented_per_render);
        }

        for (int i = 0; i < kPipeline; ++i)
        {
            if (color_up[i].persistent_map != nullptr) color_up[i].buffer->Unmap(0, nullptr);
            if (depth_up[i].persistent_map != nullptr) depth_up[i].buffer->Unmap(0, nullptr);
            if (mv_up[i].persistent_map != nullptr) mv_up[i].buffer->Unmap(0, nullptr);
            if (bias_up[i].persistent_map != nullptr) bias_up[i].buffer->Unmap(0, nullptr);
            if (compact_flow_up[i].persistent_map != nullptr) compact_flow_up[i].buffer->Unmap(0, nullptr);
            if (compact_confidence_up[i].persistent_map != nullptr) compact_confidence_up[i].buffer->Unmap(0, nullptr);
            if (compact_depth_up[i].persistent_map != nullptr) compact_depth_up[i].buffer->Unmap(0, nullptr);
            if (raw_rgb_up[i].persistent_map != nullptr) raw_rgb_up[i].buffer->Unmap(0, nullptr);
            color_up[i].buffer->Release();
            depth_up[i].buffer->Release();
            mv_up[i].buffer->Release();
            bias_up[i].buffer->Release();
            if (compact_flow_up[i].buffer != nullptr) compact_flow_up[i].buffer->Release();
            if (compact_confidence_up[i].buffer != nullptr) compact_confidence_up[i].buffer->Release();
            if (compact_depth_up[i].buffer != nullptr) compact_depth_up[i].buffer->Release();
            raw_rgb_up[i].buffer->Release();
            if (readback[i].buffer != nullptr) readback[i].buffer->Release();
        }
        ReleaseGpuInputExpander(input_expander);
        color->Release();
        output_tex->Release();
        depth->Release();
        mv->Release();
        bias->Release();
        ReleaseMotionFrameGeneration(frame_generation);
        const fs::path delivered_output = o.preview_only ? fs::path(L"<display>") :
            (chunk_encode_mode ? o.encode_chunks_dir : (o.encode_mp4.empty() ? o.output : o.encode_mp4));
        Log("[host] DLSS5_BATCH_OK frames=%u render=%ux%u target=%ux%u output=%ls",
            o.frames, o.width, o.height, target_width, target_height, delivered_output.c_str());
        if (o.stream)
        {
        if (chunk_ack_counter != nullptr)
        {
            UnmapViewOfFile(const_cast<LONG64 *>(chunk_ack_counter));
            chunk_ack_counter = nullptr;
        }
        if (chunk_ack_mapping != nullptr)
        {
            CloseHandle(chunk_ack_mapping);
            chunk_ack_mapping = nullptr;
        }
        printf("HOST_STREAM_DONE %u\n", o.frames);
            fflush(stdout);
        }
        return 0;
    }
    catch (const std::exception &e)
    {
        Log("[host] batch failed: %s", e.what());
        return 1;
    }
}

// ---------------------------------------------------------------------------
// Serve mode: the real pipe server for a 32-bit game
// ---------------------------------------------------------------------------

static bool ReadFull(HANDLE pipe, void *buf, DWORD len)
{
    DWORD got = 0;
    return ReadFile(pipe, buf, len, &got, nullptr) && got == len;
}

static int Serve(DWORD game_pid)
{
    char name[128];
    sprintf_s(name, FEED_PIPE_FMT, static_cast<unsigned long>(game_pid));
    HANDLE pipe = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                   1, 1024, 1024, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) { Log("[host] CreateNamedPipe failed %lu", GetLastError()); return 1; }
    Log("[host] serving on %s", name);
    if (!ConnectNamedPipe(pipe, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED)
    { Log("[host] ConnectNamedPipe failed %lu", GetLastError()); return 1; }

    FeedHello hello = {};
    if (!ReadFull(pipe, &hello, sizeof(hello)) || hello.magic != FEED_IPC_MAGIC)
    { Log("[host] bad hello"); return 1; }
    FeedHelloAck ack = { FEED_IPC_MAGIC, FEED_IPC_VERSION };
    DWORD put = 0;
    WriteFile(pipe, &ack, sizeof(ack), &put, nullptr);
    Log("[host] game pid %u connected (protocol v%u)", hello.pid, hello.version);

    HANDLE hgame = OpenProcess(PROCESS_DUP_HANDLE, FALSE, hello.pid);
    if (hgame == nullptr) { Log("[host] OpenProcess failed %lu", GetLastError()); return 1; }

    // Shared fences live for the whole session.
    HANDLE hin = nullptr, hout = nullptr;
    h.dev->CreateFence(0, D3D12_FENCE_FLAG_SHARED, __uuidof(ID3D12Fence), reinterpret_cast<void **>(&h.fence_in));
    h.dev->CreateFence(0, D3D12_FENCE_FLAG_SHARED, __uuidof(ID3D12Fence), reinterpret_cast<void **>(&h.fence_out));
    if (h.fence_in == nullptr || h.fence_out == nullptr ||
        FAILED(h.dev->CreateSharedHandle(h.fence_in, nullptr, GENERIC_ALL, nullptr, &hin)) ||
        FAILED(h.dev->CreateSharedHandle(h.fence_out, nullptr, GENERIC_ALL, nullptr, &hout)))
    { Log("[host] shared fence creation failed"); return 1; }

    HANDLE game_in = nullptr, game_out = nullptr;
    DuplicateHandle(GetCurrentProcess(), hin, hgame, &game_in, 0, FALSE, DUPLICATE_SAME_ACCESS);
    DuplicateHandle(GetCurrentProcess(), hout, hgame, &game_out, 0, FALSE, DUPLICATE_SAME_ACCESS);

    int flags_active = 0;
    bool transport_only = false;
    float mvsx = 1.0f, mvsy = 1.0f;
    // The DLSS 5 add-on arms its NGX hooks ~150 ms after NGX init; the first create must
    // not race that (a 15 ms miss latched STANDBY in Blacklist), so hold it briefly.
    UINT64 hold_until = GetTickCount64() + 800;
    UINT64 evaluated  = 0;
    bool   warm_done  = g_renodx_lazy;   // v45+ adopts missed creates on its own
    int    build_fails = 0;

    for (;;)
    {
        // Peek the next message type by size: Build (big) vs FrameMsg (small).
        // The pipe is byte-mode from a single writer, so read the smaller header
        // first and decide -- FeedFrameMsg and FeedBuild share no prefix, so the
        // client precedes every message with a 1-byte tag instead.
        //
        // A plain blocking ReadFile here starves the message pump (and Present)
        // whenever the game stops feeding frames -- paused, loading, a menu -- and
        // Windows shows the host window as "Not Responding". Poll instead, so the
        // window (and its ReShade overlay) stays alive and clickable at all times.
        BYTE tag = 0;
        bool tag_read = false;
        for (;;)
        {
            DWORD avail = 0;
            if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &avail, nullptr)) break;   // pipe broken
            if (avail > 0) { tag_read = ReadFull(pipe, &tag, 1); break; }
            PumpPresent();
            Sleep(8);
        }
        if (!tag_read) { Log("[host] pipe closed by the game"); break; }

        if (tag == 'B')
        {
            FeedBuild b = {};
            if (!ReadFull(pipe, &b, sizeof(b))) break;
            Log("[host] build: %ux%u color=%u output=%u hdr=%d inverted=%d", b.width, b.height,
                b.color_fmt, b.output_fmt, b.hdr, b.depth_inverted);

            // Tear down the old set.
            SafeReleaseFeature(h.feature);
            h.feature = nullptr;
            for (int i = 0; i < FEED_SLOTS; ++i)
                if (h.tex[i] != nullptr) { h.tex[i]->Release(); h.tex[i] = nullptr; }

            // Open the game's textures (duplicate the handles out of the game).
            bool ok = true;
            for (int i = 0; i < FEED_SLOTS && ok; ++i)
            {
                HANDLE local = nullptr;
                if (!DuplicateHandle(hgame, reinterpret_cast<HANDLE>(static_cast<uintptr_t>(b.tex[i])),
                                     GetCurrentProcess(), &local, 0, FALSE, DUPLICATE_SAME_ACCESS))
                { Log("[host] DuplicateHandle(tex %d) failed %lu", i, GetLastError()); ok = false; break; }
                HRESULT hr = h.dev->OpenSharedHandle(local, __uuidof(ID3D12Resource),
                                                     reinterpret_cast<void **>(&h.tex[i]));
                CloseHandle(local);
                if (FAILED(hr)) { Log("[host] OpenSharedHandle(tex %d) failed 0x%08X", i, hr); ok = false; }
            }

            NVSDK_NGX_Result rf = NVSDK_NGX_Result_Fail;
            if (ok)
            {
                h.width = b.width; h.height = b.height;
                h.color_fmt  = static_cast<DXGI_FORMAT>(b.color_fmt);
                h.output_fmt = static_cast<DXGI_FORMAT>(b.output_fmt);
                mvsx = b.mv_scale_x; mvsy = b.mv_scale_y;
                transport_only = b.transport != 0;
                flags_active = NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | NVSDK_NGX_DLSS_Feature_Flags_AutoExposure;
                if (b.depth_inverted) flags_active |= NVSDK_NGX_DLSS_Feature_Flags_DepthInverted;
                if (b.hdr)            flags_active |= NVSDK_NGX_DLSS_Feature_Flags_IsHDR;
                if (b.flags_override >= 0) flags_active = b.flags_override;

                if (transport_only)
                {
                    rf = static_cast<NVSDK_NGX_Result>(1);   // no NGX in the loop at all
                    Log("[host] transport-only mode: Color will be copied to Output, no evaluate");
                }
                else
                {
                    const UINT64 now = GetTickCount64();
                    if (now < hold_until) Sleep(static_cast<DWORD>(hold_until - now));  // hook-arming grace
                    ok = CreateFeature(b.width, b.height, flags_active, &rf);
                    hold_until = GetTickCount64() + 1000;   // next create not before +1 s

                    if (ok) build_fails = 0;
                    else if (++build_fails >= 2 && ReinitNgx())
                    {
                        Log("[host] retrying the create after an NGX reinit");
                        ok = CreateFeature(b.width, b.height, flags_active, &rf);
                        if (ok) build_fails = 0;
                    }
                }
            }

            evaluated = 0;
            warm_done = transport_only || g_renodx_lazy;   // no warm-up without NGX / with v45+

            FeedBuildAck back = {};
            back.ok         = ok ? 1 : 0;
            back.ngx_result = static_cast<uint32_t>(rf);
            back.fence_in   = reinterpret_cast<uint64_t>(game_in);
            back.fence_out  = reinterpret_cast<uint64_t>(game_out);
            WriteFile(pipe, &back, sizeof(back), &put, nullptr);
        }
        else if (tag == 'F')
        {
            FeedFrameMsg fm = {};
            if (!ReadFull(pipe, &fm, sizeof(fm))) break;
            if (h.feature == nullptr && !transport_only) { h.fence_out->Signal(fm.n); continue; }

            if (!WaitFenceValue(h.fence_in, fm.n, 2000))
            { Log("[host] frame %llu: in-fence never arrived", (unsigned long long)fm.n); h.fence_out->Signal(fm.n); continue; }
            h.queue->Wait(h.fence_in, fm.n);   // belt and braces on the GPU timeline

            bool done = false;
            if (transport_only)
            {
                if (BeginCommands())
                {
                    // Deliberately copy only the LEFT half: a split screen in the game is
                    // unambiguous visual proof that the host's output reaches the screen.
                    D3D12_TEXTURE_COPY_LOCATION src = {}, dst = {};
                    src.pResource = h.tex[FEED_COLOR];
                    src.Type      = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                    dst.pResource = h.tex[FEED_OUTPUT];
                    dst.Type      = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                    D3D12_BOX box = { 0, 0, 0, h.width / 2, h.height, 1 };
                    h.list->CopyTextureRegion(&dst, 0, 0, 0, &src, &box);
                    EndCommands();
                    done = true;
                }
            }
            else
                done = Evaluate(h.tex[FEED_COLOR], h.tex[FEED_OUTPUT], h.tex[FEED_DEPTH], h.tex[FEED_MV],
                                h.width, h.height, fm.reset ? 1 : 0, mvsx, mvsy);

            if (done)
            {
                h.queue->Signal(h.fence_out, fm.n);
                // One warm-up re-create per build: the DLSS 5 add-on misses the very first
                // create (STANDBY latch) when its hooks armed a moment too late.
                if (!warm_done && ++evaluated >= 180)
                {
                    warm_done = true;
                    Log("[host] warm-up: re-creating the feature once");
                    WaitFenceValue(h.fence, h.fence_value, 2000);
                    NVSDK_NGX_Handle *old = h.feature;
                    h.feature = nullptr;
                    NVSDK_NGX_Result rr = NVSDK_NGX_Result_Fail;
                    if (CreateFeature(h.width, h.height, flags_active, &rr)) SafeReleaseFeature(old);
                    else { h.feature = old; Log("[host] keeping the previous feature"); }
                }
            }
            else
                h.fence_out->Signal(fm.n);     // CPU-signal so the game never hangs on us

            if (fm.n <= 3 || (fm.n % 1800) == 0)
                Log("[host] frame %llu evaluated", (unsigned long long)fm.n);
            PumpPresent();
        }
        else
        {
            Log("[host] unknown tag 0x%02X", tag);
            break;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------

int main(int argc, char **argv)
{
    GetModuleFileNameA(nullptr, g_log_path, MAX_PATH);
    if (char *s = strrchr(g_log_path, '\\'))
        strcpy_s(s + 1, MAX_PATH - (s + 1 - g_log_path), "dlss5-video-host.log");
    { FILE *f = nullptr; if (fopen_s(&f, g_log_path, "w") == 0 && f) fclose(f); }

    Log("dlss5-video-host (built %s %s)", __DATE__, __TIME__);

    bool  test = false, hide = false;
    BatchOptions batch;
    DWORD pid = 0;
    for (int i = 1; i < argc; ++i)
    {
        if      (strcmp(argv[i], "--test") == 0) test = true;
        else if (strcmp(argv[i], "--batch") == 0) batch.enabled = true;
        else if (strcmp(argv[i], "--batch-stream") == 0) { batch.enabled = true; batch.stream = true; }
        else if (strcmp(argv[i], "--hide") == 0) hide = true;
        else if (strcmp(argv[i], "--input") == 0 && i + 1 < argc) batch.input = argv[++i];
        else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) batch.output = argv[++i];
        else if (strcmp(argv[i], "--encode-mp4") == 0 && i + 1 < argc) batch.encode_mp4 = argv[++i];
        else if (strcmp(argv[i], "--encode-chunks-dir") == 0 && i + 1 < argc) batch.encode_chunks_dir = argv[++i];
        else if (strcmp(argv[i], "--motion") == 0 && i + 1 < argc) batch.motion = argv[++i];
        else if (strcmp(argv[i], "--depth") == 0 && i + 1 < argc) batch.depth = argv[++i];
        else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) batch.width = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) batch.height = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--output-width") == 0 && i + 1 < argc) batch.output_width = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--output-height") == 0 && i + 1 < argc) batch.output_height = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) batch.frames = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) batch.fps = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--codec") == 0 && i + 1 < argc) batch.codec = argv[++i];
        else if (strcmp(argv[i], "--quality") == 0 && i + 1 < argc) batch.quality = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--reset-every-frame") == 0) batch.reset_every_frame = true;
        else if (strcmp(argv[i], "--timings") == 0) batch.timings = true;
        else if (strcmp(argv[i], "--quiet-frames") == 0) batch.quiet_frames = true;
        else if (strcmp(argv[i], "--no-prefetch") == 0) batch.prefetch = false;
        else if (strcmp(argv[i], "--sync-write") == 0) batch.async_write = false;
        else if (strcmp(argv[i], "--delete-chunks") == 0) batch.delete_chunks = true;
        else if (strcmp(argv[i], "--preview") == 0) batch.preview = true;
        else if (strcmp(argv[i], "--preview-only") == 0) { batch.preview = true; batch.preview_only = true; }
        else if (strcmp(argv[i], "--fast-start") == 0) batch.fast_start = true;
        else if (strcmp(argv[i], "--fullscreen") == 0) batch.fullscreen = true;
        else if (strcmp(argv[i], "--frame-generation-motion") == 0) batch.motion_frame_generation = true;
        else if (strcmp(argv[i], "--frame-generation-nvidia") == 0) batch.nvidia_frame_generation = true;
        else if (strcmp(argv[i], "--dlssg-dynamic") == 0) batch.nvidia_dynamic_mfg = true;
        else if (strcmp(argv[i], "--dlssg-generated-frames") == 0 && i + 1 < argc) batch.nvidia_generated_frames = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--dlssg-dynamic-target") == 0 && i + 1 < argc) batch.nvidia_dynamic_target_fps = static_cast<uint32_t>(strtoul(argv[++i], nullptr, 10));
        else if (strcmp(argv[i], "--control-file") == 0 && i + 1 < argc) batch.control_file = argv[++i];
        else if (strcmp(argv[i], "--telemetry-file") == 0 && i + 1 < argc) batch.telemetry_file = argv[++i];
        else if (strcmp(argv[i], "--chunk-ack-map") == 0 && i + 1 < argc) batch.chunk_ack_map = argv[++i];
        else if (strcmp(argv[i], "--encoder-affinity-mask") == 0 && i + 1 < argc) batch.encoder_affinity_mask = _strtoui64(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "--media-start-seconds") == 0 && i + 1 < argc) batch.media_start_seconds = strtod(argv[++i], nullptr);
        else if (strcmp(argv[i], "--media-duration-seconds") == 0 && i + 1 < argc) batch.media_duration_seconds = strtod(argv[++i], nullptr);
        else pid = static_cast<DWORD>(strtoul(argv[i], nullptr, 10));
    }
    if (!test && !batch.enabled && pid == 0)
    {
        Log("usage: dlss5-video-host --test | --batch [--input in.rgb24 --motion motion.bin --depth depth.bin | --batch-stream] (--output out.rgb24 | --encode-mp4 out.mp4 | --encode-chunks-dir dir | --preview-only) --width W --height H --frames N [--output-width OW --output-height OH] [--fps N] [--codec h264|h265] [--quality 0..51] [--reset-every-frame] [--timings] [--quiet-frames] [--delete-chunks] [--preview] [--fast-start] [--fullscreen] [--frame-generation-motion|--frame-generation-nvidia [--dlssg-generated-frames 1..5] [--dlssg-dynamic [--dlssg-dynamic-target FPS]]]] [--control-file path] [--telemetry-file path] [--chunk-ack-map name] [--encoder-affinity-mask N] [--media-start-seconds N]");
        return 1;
    }
    g_show_window = (!test && !batch.enabled && !hide) || batch.preview;
    g_preview_mode = batch.preview;
    g_preview_direct = batch.preview_only;
    g_preview_fullscreen = batch.fullscreen;
    g_preview_control_file = batch.control_file;
    g_preview_event_file = batch.control_file.empty() ? fs::path() : fs::path(batch.control_file.wstring() + L".events");
    g_preview_telemetry_file = batch.telemetry_file;
    g_preview_media_start_seconds = batch.media_start_seconds;
    g_preview_media_duration_seconds = batch.media_duration_seconds;
    g_preview_fps = std::max(1u, batch.fps);
    if (batch.preview)
    {
        g_preview_width = batch.output_width != 0 ? batch.output_width : batch.width;
        g_preview_height = batch.output_height != 0 ? batch.output_height : batch.height;
    }

    DetectRenodxAddon();   // must run BEFORE ReShade loads, so an EnableHooks write is read
    if (!LoadPortableReShade()) return 1;
    if (batch.nvidia_frame_generation)
    {
        // Register the neural-rendering add-on before Streamline loads NGX.
        if (!InitStreamline())
        {
            Log("[streamline] NVIDIA DLSS Frame Generation is unavailable");
            return 1;
        }
    }

    if (!InitDisguise()) return 1;
    if (!InitNgx()) { Log("[host] NGX unavailable"); return 1; }

    if (test) return RunTest();
    if (batch.enabled) return RunBatch(batch);
    return Serve(pid);
}
