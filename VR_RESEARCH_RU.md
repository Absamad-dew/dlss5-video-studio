# Исследование современного monocular-to-stereo для VR

Дата проверки: 2 сентября 2026.

## Что используется в рабочем конвейере V15

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

Эта комбинация переносит в практический локальный конвейер ключевые идеи современных методов — геометрически корректный warp, отдельное восстановление disocclusion и межкадровую согласованность — но не выдаёт эвристическое заполнение за diffusion-inpainting. Она запускается на RTX 4060 Laptop с 8 ГБ VRAM, масштабируется на RTX 5080 и не требует многогигабайтной генеративной модели для каждого кадра.

## Что показали лучшие современные аналоги

### Disney Research: Practical Deep Stereo

Работа WACV 2024 использует disparity-aware warping, раздельное foreground/background-композитирование, background-aware inpainting, временную информацию и интерактивные настройки. Именно поэтому V15 отдельно обрабатывает силуэты, дальний фон и раскрытые области, а не просто смещает весь кадр одним фильтром.

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

Работа CVPR 2026 предлагает Gradient-Aware Parallax Warping и sparse-token stereo inpainting; авторы заявляют 25 FPS для HD на A100 и ускорение 10,7×. Публичного официального inference-кода на момент проверки не найдено, поэтому в V15 реализована доступная часть принципа — gradient-aware parallax и раздельное восстановление дыр — без выдуманного пункта модели.

Источник: https://openaccess.thecvf.com/content/CVPR2026/papers/Huang_DreamStereo_Towards_Real-Time_Stereo_Inpainting_for_HD_Videos_CVPR_2026_paper.pdf

### StereoWorld

Работа CVPR 2026 объединяет геометрическую регуляризацию, генерацию второго глаза и пространственно-временную укладку длинных HD-видео. Это подтверждает, что следующий качественный скачок требует именно обученной stereo-video модели, а не увеличения силы обычного depth-warp.

Источник: https://openaccess.thecvf.com/content/CVPR2026/html/Xing_StereoWorld_Geometry-Aware_Monocular-to-Stereo_Video_Generation_CVPR_2026_paper.html

### DissolveStereo

Открытый проект исследует согласованное monocular-to-stereo video generation и остаётся кандидатом для отдельного экспериментального offline-backend после проверки лицензии, весов, VRAM и поведения на длинных роликах.

Источник: https://github.com/shijianjian/DissolveStereo

### Функции настольных аналогов

VisionDepth3D показывает важность preview, depth blending, SBS/VR180, scene detection и keyframes. V15 уже закрывает подробный контроль стереогеометрии, scene-cut reset, несколько компоновок и совместимый экспорт. Интерактивные keyframes и отдельный генеративный inpaint-backend остаются следующими крупными задачами, потому что требуют нового формата проекта и длительного model-runtime, а не ещё одного ползунка.

Источник: https://github.com/VisionDepth/VisionDepth3D/blob/Main-Stable/UserGuide.md

## Практический вывод

В рабочей сборке не создаются неработающие пункты меню для отсутствующих diffusion-весов. Максимальный доступный путь V15 — DA3 Large + Temporal LDI + Motion temporal + Full-SBS + независимый DLSS5 для каждого глаза. Cinematic использует Video Depth Small, Temporal LDI и один DLSS5-проход как более практичный баланс. Для скорости выбираются DA2 Small, Layered/Inverse, Half-SBS и при необходимости один опорный глаз.

Проверка на ноутбуке подтвердила оба DLSS5-пути. Восьмикадровый end-to-end тест прошёл декодирование, guide/depth, настоящий Feature 18, Temporal LDI, возврат звука, stereo metadata и обязательное декодирование первого кадра. Отдельный двухкадровый тест максимального режима зафиксировал три настоящих запуска Feature 18: до стерео, затем для левого и правого глаза; итоговый HEVC Main/yuv420p сохранил все кадры и успешно декодировался.
