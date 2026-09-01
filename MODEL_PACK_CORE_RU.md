# DLSS5 Video Studio — Core Models V11

Это небольшой архив основных открытых моделей для уже подготовленной portable-папки V11.

## Установка

Распакуйте содержимое `DLSS5_VIDEO_STUDIO_CORE_MODELS_V11.zip` прямо в корень папки программы, рядом с `DLSS5 Video Studio.exe`. Не создавайте дополнительную вложенную папку.

После распаковки получится:

```text
models/
  depth_anything_v2_small.onnx
  depth/da3-small/
    config.json
    model.safetensors
    README.md
  motion/raft_small_C_T_V2-01064c6d.pth
```

Запустите `VERIFY_CORE_MODELS.cmd`. Успешный результат заканчивается строкой `CORE_MODEL_PACK_VERIFY_OK`.

## Что включено

- DA2 Small — основной быстрый realtime-профиль глубины;
- DA3 Small — качественная карта глубины для записи и настоящего DepthSBS/VR;
- RAFT Small C_T_V2 — точные нейронные векторы движения для экспертного режима.

В архив намеренно не входят FlashVSR, DLoRAL, DA3 Base, Video Depth Anything, NanoVSR и AnimeSR. Они либо весят много, либо дублируют основные профили, либо не нужны для запуска программы по умолчанию.

Архив не содержит саму программу, Python/CUDA runtime, FFmpeg, ReShade или NVIDIA DLL. Он дополняет готовую portable-папку V11. Лицензии моделей находятся в `licenses/model-pack`.
