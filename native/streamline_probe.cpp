#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <filesystem>

#include <sl.h>
#include <sl_dlss_g.h>
#include <sl_reflex.h>

int wmain()
{
    namespace fs = std::filesystem;
    wchar_t executable[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, executable, MAX_PATH);
    const fs::path root = fs::path(executable).parent_path();
    const wchar_t *plugin_paths[] = {root.c_str()};
    const sl::Feature features[] = {sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL};

    sl::Preferences preferences{};
    preferences.renderAPI = sl::RenderAPI::eD3D12;
    preferences.flags |= sl::PreferenceFlags::eUseManualHooking;
    preferences.featuresToLoad = features;
    preferences.numFeaturesToLoad = static_cast<uint32_t>(_countof(features));
    preferences.projectId = "a0f57b54-1daf-4934-90ae-c4035c19df04";
    preferences.engine = sl::EngineType::eCustom;
    preferences.engineVersion = "DLSS5 Video Studio V11";
    preferences.pathsToPlugins = plugin_paths;
    preferences.numPathsToPlugins = 1;
    preferences.pathToLogsAndData = root.c_str();
    preferences.logLevel = sl::LogLevel::eDefault;

    const sl::Result initialized = slInit(preferences);
    std::printf("STREAMLINE_INIT result=%d\n", static_cast<int>(initialized));
    if (initialized != sl::Result::eOk) return 2;

    IDXGIFactory4 *factory = nullptr;
    if (FAILED(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory))))
    {
        slShutdown();
        return 3;
    }
    IDXGIAdapter1 *adapter = nullptr;
    DXGI_ADAPTER_DESC1 description = {};
    for (UINT index = 0; factory->EnumAdapters1(index, &adapter) != DXGI_ERROR_NOT_FOUND; ++index)
    {
        adapter->GetDesc1(&description);
        if (description.VendorId == 0x10DE) break;
        adapter->Release();
        adapter = nullptr;
    }
    if (!adapter)
    {
        factory->Release();
        slShutdown();
        return 4;
    }

    sl::AdapterInfo adapter_info{};
    adapter_info.deviceLUID = reinterpret_cast<uint8_t *>(&description.AdapterLuid);
    adapter_info.deviceLUIDSizeInBytes = sizeof(description.AdapterLuid);
    const sl::Result dlssg = slIsFeatureSupported(sl::kFeatureDLSS_G, adapter_info);
    const sl::Result reflex = slIsFeatureSupported(sl::kFeatureReflex, adapter_info);
    sl::FeatureRequirements requirements{};
    const sl::Result requirement_result = slGetFeatureRequirements(sl::kFeatureDLSS_G, requirements);
    std::wprintf(L"STREAMLINE_GPU name=%ls vram_mb=%llu\n", description.Description,
                 static_cast<unsigned long long>(description.DedicatedVideoMemory / (1024 * 1024)));
    std::printf("STREAMLINE_SUPPORT dlssg=%d reflex=%d requirements=%d flags=%u\n",
                static_cast<int>(dlssg), static_cast<int>(reflex), static_cast<int>(requirement_result),
                static_cast<unsigned>(requirements.flags));

    adapter->Release();
    factory->Release();
    slShutdown();
    return dlssg == sl::Result::eOk && reflex == sl::Result::eOk ? 0 : 5;
}
