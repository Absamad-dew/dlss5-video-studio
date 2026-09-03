#pragma once

// Explicit D3D12 input/output fencing, as documented by the NVENC programming
// guide. Only compressed bitstreams cross to the CPU; source pixels stay on GPU.
#include <ffnvcodec/nvEncodeAPI.h>

class D3D12NvEncoder
{
    struct Slot
    {
        ID3D12Resource *texture = nullptr;
        ID3D12Resource *bitstream = nullptr;
        ID3D12Fence *done = nullptr;
        NV_ENC_REGISTERED_PTR registered_input = nullptr;
        NV_ENC_REGISTERED_PTR registered_output = nullptr;
        NV_ENC_INPUT_PTR mapped_input = nullptr;
        NV_ENC_INPUT_PTR mapped_output = nullptr;
        NV_ENC_INPUT_RESOURCE_D3D12 input = {};
        NV_ENC_OUTPUT_RESOURCE_D3D12 output = {};
        uint64_t serial = 0;
        bool pending = false;
    };
    HMODULE module_ = nullptr;
    void *encoder_ = nullptr;
    NV_ENCODE_API_FUNCTION_LIST api_ = {};
    std::vector<Slot> slots_;
    NV_ENC_CONFIG config_ = {};
    UINT width_ = 0, height_ = 0;
    bool hevc_ = false, flushed_ = false;

    void Check(NVENCSTATUS status, const char *operation)
    {
        if (status == NV_ENC_SUCCESS) return;
        const char *detail = encoder_ && api_.nvEncGetLastErrorString
            ? api_.nvEncGetLastErrorString(encoder_) : nullptr;
        throw std::runtime_error(std::string("D3D12 NVENC ") + operation + " failed (" +
                                 std::to_string(static_cast<int>(status)) + "): " + (detail ? detail : ""));
    }
    static void CheckHr(HRESULT status, const char *operation)
    {
        if (FAILED(status)) throw std::runtime_error(std::string("D3D12 NVENC ") + operation +
                                                     " HRESULT=" + std::to_string(status));
    }
    template<class Vui> static void SetVideoColor(Vui &vui)
    {
        vui.videoSignalTypePresentFlag = 1;
        vui.colourDescriptionPresentFlag = 1;
        vui.videoFullRangeFlag = 0;
        vui.colourPrimaries = static_cast<NV_ENC_VUI_COLOR_PRIMARIES>(1);
        vui.transferCharacteristics = static_cast<NV_ENC_VUI_TRANSFER_CHARACTERISTIC>(1);
        vui.colourMatrix = static_cast<NV_ENC_VUI_MATRIX_COEFFS>(1);
    }

public:
    D3D12NvEncoder() = default;
    D3D12NvEncoder(const D3D12NvEncoder &) = delete;
    D3D12NvEncoder &operator=(const D3D12NvEncoder &) = delete;
    ~D3D12NvEncoder()
    {
        // On failure, destroy the session before releasing resources that the
        // driver may still own. Normal completion unregisters each idle slot.
        if (encoder_)
        {
            const bool idle = std::none_of(slots_.begin(), slots_.end(), [](const Slot &s) { return s.pending; });
            if (idle) for (auto &s : slots_)
            {
                if (s.mapped_input) api_.nvEncUnmapInputResource(encoder_, s.mapped_input);
                if (s.mapped_output) api_.nvEncUnmapInputResource(encoder_, s.mapped_output);
                if (s.registered_input) api_.nvEncUnregisterResource(encoder_, s.registered_input);
                if (s.registered_output) api_.nvEncUnregisterResource(encoder_, s.registered_output);
            }
            api_.nvEncDestroyEncoder(encoder_);
        }
        for (auto &s : slots_)
        {
            if (s.texture) s.texture->Release();
            if (s.bitstream) s.bitstream->Release();
            if (s.done) s.done->Release();
        }
        if (module_) FreeLibrary(module_);
    }

    void Open(ID3D12Device *device, UINT width, UINT height, UINT fps, UINT quality, bool hevc, int count)
    {
        width_ = width; height_ = height; hevc_ = hevc;
        module_ = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module_) throw std::runtime_error("NVIDIA NVENC driver library is unavailable");
        using CreateInstance = NVENCSTATUS (NVENCAPI *)(NV_ENCODE_API_FUNCTION_LIST *);
        auto create = reinterpret_cast<CreateInstance>(GetProcAddress(module_, "NvEncodeAPICreateInstance"));
        if (!create) throw std::runtime_error("NvEncodeAPICreateInstance is unavailable");
        api_.version = NV_ENCODE_API_FUNCTION_LIST_VER;
        Check(create(&api_), "create API");
        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS session = {};
        session.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        session.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
        session.device = device;
        session.apiVersion = NVENCAPI_VERSION;
        Check(api_.nvEncOpenEncodeSessionEx(&session, &encoder_), "open session");

        const GUID codec = hevc ? NV_ENC_CODEC_HEVC_GUID : NV_ENC_CODEC_H264_GUID;
        NV_ENC_PRESET_CONFIG preset = {};
        preset.version = NV_ENC_PRESET_CONFIG_VER;
        preset.presetCfg.version = NV_ENC_CONFIG_VER;
        Check(api_.nvEncGetEncodePresetConfigEx(encoder_, codec, NV_ENC_PRESET_P1_GUID,
                                                NV_ENC_TUNING_INFO_LOW_LATENCY, &preset), "P1/LL preset");
        config_ = preset.presetCfg;
        config_.version = NV_ENC_CONFIG_VER;
        // Match FFmpeg 9's -preset p1 -tune ll -rc constqp -qp Q defaults.
        // Do not change GOP/B-frame policy to make this prototype appear faster.
        if (config_.frameIntervalP != 1) throw std::runtime_error("D3D12 NVENC requires the existing no-B P1/LL preset");
        config_.frameFieldMode = NV_ENC_PARAMS_FRAME_FIELD_MODE_FRAME;
        config_.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CONSTQP;
        config_.rcParams.multiPass = NV_ENC_MULTI_PASS_DISABLED;
        config_.rcParams.constQP.qpInterP = quality;
        config_.rcParams.constQP.qpIntra = std::min(51u, static_cast<UINT>(quality * 0.8 + 0.5));
        config_.rcParams.constQP.qpInterB = std::min(51u, static_cast<UINT>(quality * 1.25 + 1.25 + 0.5));
        config_.rcParams.averageBitRate = 2000000;
        config_.rcParams.vbvBufferSize = 4000000;
        if (hevc)
        {
            config_.profileGUID = NV_ENC_HEVC_PROFILE_MAIN_GUID;
            auto &c = config_.encodeCodecConfig.hevcConfig;
            c.chromaFormatIDC = 1;
            c.inputBitDepth = c.outputBitDepth = NV_ENC_BIT_DEPTH_8;
            c.disableSPSPPS = 0; c.repeatSPSPPS = 1; c.outputAUD = 0;
            c.idrPeriod = config_.gopLength;
            c.maxNumRefFramesInDPB = 0;
            c.sliceMode = 3; c.sliceModeData = 1;
            c.outputPictureTimingSEI = 1;
            c.level = NV_ENC_LEVEL_AUTOSELECT;
            c.tier = NV_ENC_TIER_HEVC_MAIN;
            c.numRefL0 = c.numRefL1 = NV_ENC_NUM_REF_FRAMES_AUTOSELECT;
            SetVideoColor(c.hevcVUIParameters);
        }
        else
        {
            config_.profileGUID = NV_ENC_H264_PROFILE_HIGH_GUID;
            auto &c = config_.encodeCodecConfig.h264Config;
            c.chromaFormatIDC = 1;
            c.inputBitDepth = c.outputBitDepth = NV_ENC_BIT_DEPTH_8;
            c.disableSPSPPS = 0; c.repeatSPSPPS = 1; c.outputAUD = 0;
            c.idrPeriod = config_.gopLength;
            c.maxNumRefFrames = 0;
            c.h264VUIParameters.bitstreamRestrictionFlag = config_.gopLength != 1;
            c.sliceMode = 3; c.sliceModeData = 1;
            c.outputPictureTimingSEI = 1;
            c.level = NV_ENC_LEVEL_AUTOSELECT;
            c.numRefL0 = c.numRefL1 = NV_ENC_NUM_REF_FRAMES_AUTOSELECT;
            SetVideoColor(c.h264VUIParameters);
        }
        NV_ENC_INITIALIZE_PARAMS init = {};
        init.version = NV_ENC_INITIALIZE_PARAMS_VER;
        init.encodeGUID = codec;
        init.presetGUID = NV_ENC_PRESET_P1_GUID;
        init.tuningInfo = NV_ENC_TUNING_INFO_LOW_LATENCY;
        init.encodeWidth = init.darWidth = init.maxEncodeWidth = width;
        init.encodeHeight = init.darHeight = init.maxEncodeHeight = height;
        init.frameRateNum = fps; init.frameRateDen = 1;
        init.bufferFormat = NV_ENC_BUFFER_FORMAT_NV12;
        init.enablePTD = 1;
        init.enableEncodeAsync = 0;
        init.encodeConfig = &config_;
        Check(api_.nvEncInitializeEncoder(encoder_, &init), "initialize");

        slots_.resize(count);
        const UINT bitstream_bytes = width * height * 3u;
        for (auto &s : slots_)
        {
            D3D12_HEAP_PROPERTIES heap = {};
            heap.Type = D3D12_HEAP_TYPE_DEFAULT;
            D3D12_RESOURCE_DESC desc = {};
            desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
            desc.Width = width; desc.Height = height;
            desc.DepthOrArraySize = 1; desc.MipLevels = 1;
            desc.Format = DXGI_FORMAT_NV12; desc.SampleDesc.Count = 1;
            CheckHr(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
                D3D12_RESOURCE_STATE_COMMON, nullptr, __uuidof(ID3D12Resource),
                reinterpret_cast<void **>(&s.texture)), "input texture");
            heap.Type = D3D12_HEAP_TYPE_READBACK;
            desc = {};
            desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
            desc.Width = bitstream_bytes; desc.Height = 1;
            desc.DepthOrArraySize = 1; desc.MipLevels = 1;
            desc.SampleDesc.Count = 1; desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
            CheckHr(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
                D3D12_RESOURCE_STATE_COPY_DEST, nullptr, __uuidof(ID3D12Resource),
                reinterpret_cast<void **>(&s.bitstream)), "bitstream buffer");
            CheckHr(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence),
                                        reinterpret_cast<void **>(&s.done)), "output fence");
            NV_ENC_REGISTER_RESOURCE resource = {};
            resource.version = NV_ENC_REGISTER_RESOURCE_VER;
            resource.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
            resource.width = width; resource.height = height;
            resource.resourceToRegister = s.texture;
            resource.bufferFormat = NV_ENC_BUFFER_FORMAT_NV12;
            resource.bufferUsage = NV_ENC_INPUT_IMAGE;
            Check(api_.nvEncRegisterResource(encoder_, &resource), "register input");
            s.registered_input = resource.registeredResource;
            resource.resourceToRegister = s.bitstream;
            resource.registeredResource = nullptr;
            resource.width = bitstream_bytes; resource.height = 1;
            resource.bufferFormat = NV_ENC_BUFFER_FORMAT_U8;
            resource.bufferUsage = NV_ENC_OUTPUT_BITSTREAM;
            Check(api_.nvEncRegisterResource(encoder_, &resource), "register output");
            s.registered_output = resource.registeredResource;
        }
    }
    ID3D12Resource *Input(int slot) { return slots_.at(slot).texture; }
    const NV_ENC_CONFIG &Config() const { return config_; }

    void Submit(int slot, ID3D12Fence *ready, UINT64 value, uint32_t frame)
    {
        auto &s = slots_.at(slot);
        if (s.pending || flushed_) throw std::runtime_error("D3D12 NVENC input slot reused before completion");
        // SDK 12+ D3D12 structs require mapped handles (older programming-guide
        // prose still says registered handles). Follow the pinned API header.
        NV_ENC_MAP_INPUT_RESOURCE mapping = {};
        mapping.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        mapping.registeredResource = s.registered_input;
        Check(api_.nvEncMapInputResource(encoder_, &mapping), "map input");
        s.mapped_input = mapping.mappedResource;
        mapping = {};
        mapping.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        mapping.registeredResource = s.registered_output;
        Check(api_.nvEncMapInputResource(encoder_, &mapping), "map output");
        s.mapped_output = mapping.mappedResource;
        s.input = {}; s.output = {};
        s.input.version = NV_ENC_INPUT_RESOURCE_D3D12_VER;
        s.input.pInputBuffer = s.mapped_input;
        s.input.inputFencePoint.version = NV_ENC_FENCE_POINT_D3D12_VER;
        s.input.inputFencePoint.pFence = ready;
        s.input.inputFencePoint.waitValue = value;
        s.input.inputFencePoint.bWait = 1;
        s.output.version = NV_ENC_OUTPUT_RESOURCE_D3D12_VER;
        s.output.pOutputBuffer = s.mapped_output;
        s.output.outputFencePoint.version = NV_ENC_FENCE_POINT_D3D12_VER;
        s.output.outputFencePoint.pFence = s.done;
        s.output.outputFencePoint.signalValue = ++s.serial;
        s.output.outputFencePoint.bSignal = 1;
        NV_ENC_PIC_PARAMS pic = {};
        pic.version = NV_ENC_PIC_PARAMS_VER;
        pic.inputWidth = width_; pic.inputHeight = height_;
        pic.frameIdx = frame; pic.inputTimeStamp = frame; pic.inputDuration = 1;
        pic.inputBuffer = &s.input; pic.outputBitstream = &s.output;
        pic.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12;
        pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
        if (hevc_)
        {
            pic.codecPicParams.hevcPicParams.sliceMode = 3;
            pic.codecPicParams.hevcPicParams.sliceModeData = 1;
        }
        else
        {
            pic.codecPicParams.h264PicParams.sliceMode = 3;
            pic.codecPicParams.h264PicParams.sliceModeData = 1;
        }
        Check(api_.nvEncEncodePicture(encoder_, &pic), "submit picture");
        s.pending = true;
    }
    size_t Collect(int slot, FILE *sink)
    {
        auto &s = slots_.at(slot);
        if (!s.pending) return 0;
        NV_ENC_LOCK_BITSTREAM lock = {};
        lock.version = NV_ENC_LOCK_BITSTREAM_VER;
        lock.outputBitstream = &s.output;
        lock.doNotWait = 0;
        Check(api_.nvEncLockBitstream(encoder_, &lock), "lock bitstream");
        const size_t bytes = lock.bitstreamSizeInBytes;
        const size_t written = fwrite(lock.bitstreamBufferPtr, 1, bytes, sink);
        const NVENCSTATUS unlocked = api_.nvEncUnlockBitstream(encoder_, &s.output);
        Check(unlocked, "unlock bitstream");
        Check(api_.nvEncUnmapInputResource(encoder_, s.mapped_output), "unmap output");
        s.mapped_output = nullptr;
        Check(api_.nvEncUnmapInputResource(encoder_, s.mapped_input), "unmap input");
        s.mapped_input = nullptr;
        s.pending = false;
        if (written != bytes) throw std::runtime_error("D3D12 NVENC compressed stream write failed");
        return bytes;
    }
    void Flush()
    {
        if (flushed_) return;
        NV_ENC_PIC_PARAMS eos = {};
        eos.version = NV_ENC_PIC_PARAMS_VER;
        eos.encodePicFlags = NV_ENC_PIC_FLAG_EOS;
        Check(api_.nvEncEncodePicture(encoder_, &eos), "flush");
        flushed_ = true;
    }
};
