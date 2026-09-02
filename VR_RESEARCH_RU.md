# Исследование современного monocular-to-stereo для VR

Дата проверки: 2 сентября 2026.

## Что используется в рабочем конвейере V16

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

Эта комбинация переносит в практический локальный конвейер ключевые идеи современных методов — геометрически корректный warp, отдельное восстановление disocclusion и межкадровую согласованность — но не выдаёт эвристическое заполнение за diffusion-inpainting. Она запускается на RTX 4060 Laptop с 8 ГБ VRAM, масштабируется на RTX 5080 и не требует многогигабайтной генеративной модели для каждого кадра.

## Что показали лучшие современные аналоги

### Disney Research: Practical Deep Stereo

Работа WACV 2024 использует disparity-aware warping, раздельное foreground/background-композитирование, background-aware inpainting, временную информацию и интерактивные настройки. Именно поэтому V16 отдельно обрабатывает силуэты, дальний фон и раскрытые области, а не просто смещает весь кадр одним фильтром.

Источник: https://studios.disneyresearch.com/2024/01/03/stereo-conversion/

## Исследованные максимальные варианты

### DepthCrafter

Официальная работа CVPR 2025 строит согласованные длинные depth-последовательности диффузионной моделью. В таблице официального репозитория DepthCrafter v1.0.1 указан результат около 465,84 мс на кадр при 1024×576. Это хороший кандидат для отдельного очень медленного offline-prepass, но не для текущей цели высокой скорости на ноутбуке.

Источник: https://github.com/Tencent/DepthCrafter

### StereoCrafter

Метод Tencent строит второй ракурс через depth splatting и diffusion inpainting на базе Stable Video Diffusion. Он потенциально лучше дорисовывает большие disocclusion-области, но значительно тяжелее текущего CUDA fill и требует отдельного многокадрового diffusion-прохода.

Источник: https://github.com/TencentARC/StereoCrafter

### M2SVid

M2SVid (3DV 2026) объединяет inpainting и refinement второго ракурса в один шаг и заявляет существенное ускорение относительно прежних методов. Однако официальный checkpoint весит около 4,64 ГБ без Hi3D/OpenCLIP, а авторские тесты ориентированы на A100/H100 и 512×512. Для 8-гигабайтного ноутбука это пока экспериментальный offline-backend, а не надёжная встроенная модель.

Источник: https://github.com/google-research/m2svid

### StereoPilot

Открытый inference-пайплайн конца 2025 года использует diffusion-модель семейства Wan 2.1 и генерирует стереовидео как условную видеогенерацию. Официальная конфигурация ожидает блоки по 81 кадру, 832×480, 16 FPS и текстовый prompt. Это интересный максимальный offline-кандидат, но он слишком тяжёлый и ограниченный по формату для обязательного portable-backend.

Источник: https://github.com/KlingAIResearch/StereoPilot

### DreamStereo

Работа CVPR 2026 предлагает Gradient-Aware Parallax Warping и sparse-token stereo inpainting; авторы заявляют 25 FPS для HD на A100 и ускорение 10,7×. Публичного официального inference-кода на момент проверки не найдено, поэтому в V16 реализована доступная часть принципа — gradient-aware parallax и раздельное восстановление дыр — без выдуманного пункта модели.

Источник: https://openaccess.thecvf.com/content/CVPR2026/papers/Huang_DreamStereo_Towards_Real-Time_Stereo_Inpainting_for_HD_Videos_CVPR_2026_paper.pdf

### StereoWorld

Работа CVPR 2026 объединяет геометрическую регуляризацию, генерацию второго глаза и пространственно-временную укладку длинных HD-видео. Это подтверждает, что следующий качественный скачок требует именно обученной stereo-video модели, а не увеличения силы обычного depth-warp.

Источник: https://openaccess.thecvf.com/content/CVPR2026/html/Xing_StereoWorld_Geometry-Aware_Monocular-to-Stereo_Video_Generation_CVPR_2026_paper.html

### DissolveStereo

Открытый проект исследует согласованное monocular-to-stereo video generation и остаётся кандидатом для отдельного экспериментального offline-backend после проверки лицензии, весов, VRAM и поведения на длинных роликах.

Источник: https://github.com/shijianjian/DissolveStereo

### Функции настольных аналогов

VisionDepth3D показывает важность preview, depth blending, SBS/VR180, scene detection и keyframes. V16 уже закрывает подробный контроль стереогеометрии, scene-cut reset/ramp, несколько компоновок и совместимый экспорт. Интерактивные keyframes и отдельный генеративный inpaint-backend остаются следующими крупными задачами, потому что требуют нового формата проекта и длительного model-runtime, а не ещё одного ползунка.

Источник: https://github.com/VisionDepth/VisionDepth3D/blob/Main-Stable/UserGuide.md

## Что действительно даст следующий заметный скачок

### Генеративный второй глаз вместо только depth-warp

M2SVid уже опубликовал веса (20 марта 2026 года) и объединяет восстановление раскрытых областей с уточнением второго ракурса. DreamStereo показывает более быстрый sparse-token подход, а StereoWorld — длинный HD-пайплайн с геометрической регуляризацией. Это наиболее вероятный следующий качественный backend: Temporal LDI оставляет геометрию и быстрый preview, а генеративная модель включается только для маски disocclusion или в режиме Maximum. Полный diffusion на каждом пикселе каждого кадра сейчас бессмысленно отнимает VRAM и скорость.

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

В рабочей сборке не создаются неработающие пункты меню для отсутствующих diffusion-весов. Максимальный доступный путь V16 — DA3 Large + Temporal LDI + Motion temporal + Full-SBS + независимый DLSS5 для каждого глаза. Cinematic использует Video Depth Small, Temporal LDI и один DLSS5-проход как более практичный баланс. Для скорости выбираются DA2 Small, Layered/Inverse, Half-SBS и при необходимости один опорный глаз.

Проверка на ноутбуке подтвердила оба DLSS5-пути. Восьмикадровый end-to-end тест прошёл декодирование, guide/depth, настоящий Feature 18, Temporal LDI, возврат звука, stereo metadata и обязательное декодирование первого кадра. Отдельный двухкадровый тест максимального режима зафиксировал три настоящих запуска Feature 18: до стерео, затем для левого и правого глаза; итоговый HEVC Main/yuv420p сохранил все кадры и успешно декодировался.
