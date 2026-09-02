# DLSS5 Video Studio — Main Models V19

`DLSS5_VIDEO_STUDIO_MAIN_MODELS_V19.zip` — автономный архив главных открытых моделей для уже подготовленной portable-папки.

Распакуйте содержимое прямо в корень программы рядом с `DLSS5 Video Studio.exe`, без дополнительной вложенной папки. Затем запустите `VERIFY_MAIN_MODELS.cmd`. Успешная проверка заканчивается строкой `MAIN_MODEL_PACK_VERIFY_OK`.

В архив входят:

- DA2 Small — быстрая карта глубины для realtime;
- DA3 Small — более точная depth-геометрия для записи и VR;
- TorchVision RAFT Small — нейронные motion vectors;
- MI-GAN ONNX — компактное локальное заполнение только остаточных областей после Temporal Atlas.

Архив не содержит программу, FFmpeg, Python/CUDA runtime, ReShade, NVIDIA DLL, FlashVSR, DLoRAL, DA3 Base/Large, Moebius или экспериментальный M2SVid. Он дополняет portable-сборку и раскладывает файлы сразу по тем путям, которые ожидает Studio.
