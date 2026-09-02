# Исследование современного monocular-to-stereo для VR

Дата проверки: 2 сентября 2026.

## Что используется в рабочем конвейере V17

- Video Depth Anything Small (CVPR 2025 Highlight) — временно согласованная глубина для длинных видео.
- Depth Anything 3 Small/Base/Large — более точная пространственная геометрия; Large добавлен как максимальный офлайн-профиль.
- Confidence-aware motion sidecar — предыдущая depth-карта сначала переносится в текущий кадр по optical flow и только затем смешивается.
- CUDA Temporal LDI — 2–12 квантованных слоёв глубины, soft z-priority, отдельная дальняя пластина и sparse push-pull восстановление реально раскрывшихся областей.
- Gradient-aware depth separation — на силуэтах глубина разделяется на ближний/дальний слой вместо общего размытия волос, рук и контуров персонажа.
- Robust depth range — выбросы depth обрезаются по процентилям, а границы полезного диапазона стабилизируются во времени, поэтому объём меньше «дышит».
- Motion-guided disocclusion history — пригодный скрытый фон предыдущего кадра переносится по confidence-aware optical flow и используется только внутри новых дыр.
- Автоматическое сведение — нулевой параллакс может следовать за главным объектом либо устойчивым комфортным диапазоном; ручная плоскость тоже сохранена.
- Настраиваемые cinematic/comfort/linear кривые параллакса и мягкий comfort-limit.
- Явный настоящий DLSS5: обычный проход до стерео либо максимальный вариант с отдельным Feature 18 для каждого уже построенного глаза.
- Scene-adaptive stereo comfort: сила параллакса реагирует на 75-й процентиль движения и confidence motion-векторов, быстро защищает динамичную сцену и медленно возвращает полный объём. После монтажной склейки 3D входит плавно, а не прыгает вместе с новой плоскостью глубины.
- Общий быстрый транспорт: запись и VR используют pagefile-backed RGB mappings и пассивный ограниченный OpenMP-пул из realtime; CUDA stereo использует повторно применяемые pinned host buffers.
- Официальный M2SVid full-attention как необязательный offline-backend: он получает левый глаз, Temporal LDI reprojection и отдельную disocclusion-маску, а затем генеративно восстанавливает и уточняет правый глаз.
- Перекрывающиеся окна M2SVid до 25 кадров, единоразовая загрузка сети, FP16 до переноса в VRAM и нативный PyTorch 2 SDPA вместо обязательного xFormers на Windows.

Быстрый путь по-прежнему переносит в практический локальный конвейер геометрически корректный warp, отдельное восстановление disocclusion и межкадровую согласованность. Максимальный путь теперь честно включает обученную генеративную stereo-video модель; она включается отдельно, требует около 9 ГБ файлов M2SVid + OpenCLIP и предназначена для офлайн-экспорта.

## Что показали лучшие современные аналоги

### Disney Research: Practical Deep Stereo

Работа WACV 2024 использует disparity-aware warping, раздельное foreground/background-композитирование, background-aware inpainting, временную информацию и интерактивные настройки. Именно поэтому V17 отдельно обрабатывает силуэты, дальний фон и раскрытые области, а не просто смещает весь кадр одним фильтром.

Источник: https://studios.disneyresearch.com/2024/01/03/stereo-conversion/

## Исследованные максимальные варианты

### DepthCrafter

Официальная работа CVPR 2025 строит согласованные длинные depth-последовательности диффузионной моделью. В таблице официального репозитория DepthCrafter v1.0.1 указан результат около 465,84 мс на кадр при 1024×576. Это хороший кандидат для отдельного очень медленного offline-prepass, но не для текущей цели высокой скорости на ноутбуке.

Источник: https://github.com/Tencent/DepthCrafter

### StereoCrafter

Метод Tencent строит второй ракурс через depth splatting и diffusion inpainting на базе Stable Video Diffusion. Он потенциально лучше дорисовывает большие disocclusion-области, но значительно тяжелее текущего CUDA fill и требует отдельного многокадрового diffusion-прохода.

Источник: https://github.com/TencentARC/StereoCrafter

### M2SVid

M2SVid (3DV 2026) объединяет inpainting и refinement второго ракурса в один шаг. Официальный full-attention checkpoint весит 4 978 220 327 байт, OpenCLIP ViT-H — ещё 3 944 692 325 байт; авторы тестировали 512×512 и окна до 25 кадров на A100/H100. В V17 он внедрён как явно необязательный offline-backend с автоматическими лимитами для 8/16/24+ ГБ VRAM, а не как realtime-фильтр.

Практическая проверка адаптера на RTX 4060 Laptop: цветной Full-SBS HEVC содержит все 6 из 6 кадров после двух перекрывающихся окон; установившаяся генеративная скорость на внутреннем разрешении 384 составила 0,50 кадр/с. Короткое холодное окно из двух кадров дало 0,24 кадр/с. Отдельно проверены фильтрация тренировочных LPIPS-весов, повторное использование загруженной сети и склейка перекрытий.

Источник: https://github.com/google-research/m2svid

### StereoPilot

Открытый inference-пайплайн конца 2025 года использует diffusion-модель семейства Wan 2.1 и генерирует стереовидео как условную видеогенерацию. Официальная конфигурация ожидает блоки по 81 кадру, 832×480, 16 FPS и текстовый prompt. Это интересный максимальный offline-кандидат, но он слишком тяжёлый и ограниченный по формату для обязательного portable-backend.

Источник: https://github.com/KlingAIResearch/StereoPilot

### DreamStereo

Работа CVPR 2026 предлагает Gradient-Aware Parallax Warping и sparse-token stereo inpainting; авторы заявляют 25 FPS для HD на A100 и ускорение 10,7×. Публичного официального inference-кода на момент проверки не найдено, поэтому в V17 реализована доступная часть принципа — gradient-aware parallax и раздельное восстановление дыр — без фиктивного пункта модели.

Источник: https://openaccess.thecvf.com/content/CVPR2026/papers/Huang_DreamStereo_Towards_Real-Time_Stereo_Inpainting_for_HD_Videos_CVPR_2026_paper.pdf

### StereoWorld

Работа CVPR 2026 объединяет геометрическую регуляризацию, генерацию второго глаза и пространственно-временную укладку длинных HD-видео. Официальный код теперь опубликован, но эталонный inference одновременно требует Wan 2.1 T2V 1.3B, T5/VAE, Stereo LoRA и VideoLLaMA3-7B для captioning. Вместе с текущей portable-сборкой это выходит за заданный бюджет диска и заметно тяжелее M2SVid, поэтому StereoWorld не показывается как якобы готовый backend.

Источники: https://github.com/ke-xing/StereoWorldCode, https://openaccess.thecvf.com/content/CVPR2026/html/Xing_StereoWorld_Geometry-Aware_Monocular-to-Stereo_Video_Generation_CVPR_2026_paper.html

### DissolveStereo

Открытый проект исследует согласованное monocular-to-stereo video generation и остаётся кандидатом для отдельного экспериментального offline-backend после проверки лицензии, весов, VRAM и поведения на длинных роликах.

Источник: https://github.com/shijianjian/DissolveStereo

### Функции настольных аналогов

VisionDepth3D показывает важность preview, depth blending, SBS/VR180, scene detection и keyframes. V17 закрывает подробный контроль стереогеометрии, scene-cut reset/ramp, несколько компоновок, совместимый экспорт и отдельный генеративный backend. Интерактивные keyframes остаются следующей крупной задачей, потому что требуют нового формата проекта.

Источник: https://github.com/VisionDepth/VisionDepth3D/blob/Main-Stable/UserGuide.md

## Что действительно даст следующий заметный скачок

### Генеративный второй глаз вместо только depth-warp

Этот скачок реализован в V17: Temporal LDI остаётся геометрической основой и быстрым fallback, M2SVid полностью заменяет эвристическое заполнение внутри disocclusion и в режиме Hybrid лишь мягко уточняет видимые области. Full позволяет модели изменить весь правый глаз. DreamStereo остаётся перспективнее по скорости, но без официального inference-кода; StereoWorld доступен в исходниках, однако его штатный стек слишком велик для текущего portable-бюджета.

Источники: https://github.com/google-research/m2svid, https://openaccess.thecvf.com/content/CVPR2026/papers/Huang_DreamStereo_Towards_Real-Time_Stereo_Inpainting_for_HD_Videos_CVPR_2026_paper.pdf, https://openaccess.thecvf.com/content/CVPR2026/html/Xing_StereoWorld_Geometry-Aware_Monocular-to-Stereo_Video_Generation_CVPR_2026_paper.html

### Нативный spatial-контейнер вместо только SBS

Для Apple Vision Pro современный целевой формат — MV-HEVC: один видеотрек с отдельными слоями глаз и spatial metadata. Apple публикует официальный конвейер преобразования SBS в MV-HEVC и варианты 4320×4320, но encoder/API доступен в экосистеме Apple. Поэтому Windows-сборка пока честно выпускает совместимый SBS/OU, а MV-HEVC следует добавлять как отдельный проверяемый macOS/export-worker, не как фиктивный флаг metadata.

Источники: https://developer.apple.com/documentation/avfoundation/converting-side-by-side-3d-video-to-multiview-hevc-and-spatial-video, https://developer.apple.com/documentation/avfoundation/processing-spatial-video-with-a-custom-video-compositor

### Настоящий VR-плеер: head tracking и eye-tracked foveation

Для впечатляющего интерактивного режима нужен OpenXR-плеер, который использует depth/LDI как небольшой объём: поворот головы меняет проекцию, малое перемещение даёт контролируемый parallax, а eye tracking сохраняет максимальное качество в зоне взгляда. Foveated rendering должен выполняться во время показа через variable-rate shading; заранее «запекать» низкое качество по краям записанного видео нельзя, потому что положение взгляда неизвестно.

Источники: https://registry.khronos.org/OpenXR/specs/1.1-khr/pdf/xrspec.pdf, https://docs.unity.cn/Packages/com.unity.xr.openxr%401.14/manual/features/foveatedrendering.html

### Почему Gaussian Splatting не включён одной галочкой

DepthSplat требует несколько контекстных ракурсов, а Spacetime Gaussians строит динамическую сцену из multi-view последовательности. Они подходят для подготовленного 6DoF-контента, но одно обычное видео не содержит раскрытых поверхностей и истинной геометрии за объектами. Практичный путь — сначала добавить ограниченный head-box на Temporal LDI, затем отдельный offline reconstruction для источников с несколькими ракурсами; выдавать обычный depth-warp за полный 6DoF было бы неверно.

Источники: https://github.com/cvg/depthsplat, https://github.com/oppo-us-research/SpacetimeGaussians

## Практический вывод

Максимальный доступный путь V17 — DA3 Large + Motion temporal + Temporal LDI + M2SVid Full + Full-SBS + независимый настоящий DLSS5 для каждого глаза. Более бережный вариант M2SVid Hybrid сохраняет reprojection вне дыр и регулируется двумя отдельными коэффициентами. Без скачанных весов Studio автоматически оставляет проверенный Temporal LDI, поэтому отсутствующий многогигабайтный модуль не ломает обычный VR-экспорт.

Проверка на ноутбуке подтвердила оба DLSS5-пути. Восьмикадровый end-to-end тест прошёл декодирование, guide/depth, настоящий Feature 18, Temporal LDI, возврат звука, stereo metadata и обязательное декодирование первого кадра. Отдельный двухкадровый тест максимального режима зафиксировал три настоящих запуска Feature 18: до стерео, затем для левого и правого глаза; итоговый HEVC Main/yuv420p сохранил все кадры и успешно декодировался.
