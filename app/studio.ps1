Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = 'Stop'
$ScriptDirectory = if ($StudioScriptBase) { [string]$StudioScriptBase } else { [string]$PSScriptRoot }
$Root = [IO.Path]::GetFullPath((Join-Path $ScriptDirectory '..'))
$Runner = Join-Path $ScriptDirectory 'process-video.ps1'
$RealtimeRunner = Join-Path $ScriptDirectory 'realtime-player.ps1'
$Ffprobe = Join-Path $Root 'tools\ffprobe.exe'
$PresetStore = Join-Path $Root 'settings\presets.json'
$DLoRALCheckpoint = Join-Path $Root 'models\upscalers\dloral\model.pkl'
$Invariant = [Globalization.CultureInfo]::InvariantCulture

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DLSS5 Video Studio 12 · Realtime / Recording / VR" Width="1440" Height="940"
        MinWidth="1120" MinHeight="720" WindowStartupLocation="CenterScreen"
        Background="#090D14" Foreground="#DCE7F5" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="TextOptions.TextFormattingMode" Value="Display"/></Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#EAF4FF"/><Setter Property="Background" Value="#172233"/>
      <Setter Property="BorderBrush" Value="#334B6D"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="4"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#21334C"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#0C131E"/><Setter Property="Foreground" Value="#DCE7F5"/><Setter Property="BorderBrush" Value="#2B3D57"/><Setter Property="Padding" Value="8,6"/><Setter Property="Margin" Value="0,3,0,7"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Background" Value="#F4F7FB"/><Setter Property="Foreground" Value="#101722"/><Setter Property="BorderBrush" Value="#4A5F7C"/><Setter Property="Padding" Value="7,5"/><Setter Property="Margin" Value="0,3,0,7"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#C9D7E9"/><Setter Property="Margin" Value="0,7,18,7"/></Style>
    <Style TargetType="Slider"><Setter Property="Margin" Value="2,2,2,8"/></Style>
    <Style TargetType="GroupBox"><Setter Property="Foreground" Value="#9CB1CA"/><Setter Property="BorderBrush" Value="#2A3A52"/><Setter Property="Margin" Value="0,0,0,12"/><Setter Property="Padding" Value="10"/></Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="88"/><RowDefinition Height="*"/><RowDefinition Height="76"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#111824" BorderBrush="#26354D" BorderThickness="1" CornerRadius="14" Padding="18,10" Margin="0,0,0,12">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="DLSS5 VIDEO STUDIO" FontSize="24" FontWeight="SemiBold" Foreground="#F5F9FF"/><TextBlock Text="Постоянные Feature 18 и motion/depth · быстрые SSD-чанки · NVENC" Foreground="#7F91AA" Margin="0,3,0,0"/></StackPanel>
        <Border Grid.Column="1" Background="#102923" BorderBrush="#268C78" BorderThickness="1" CornerRadius="10" Padding="15,8" VerticalAlignment="Center"><TextBlock x:Name="RuntimeStatus" Text="● Persistent DLSS5 pipeline" Foreground="#6BE0C3"/></Border>
      </Grid>
    </Border>

    <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="515"/><ColumnDefinition Width="14"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="#101722" BorderBrush="#25344B" BorderThickness="1" CornerRadius="14" Padding="14">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
          <GroupBox Header="ВИДЕО">
            <StackPanel>
              <TextBlock Text="Видеофайл или ссылка на видео"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="45"/><ColumnDefinition Width="92"/></Grid.ColumnDefinitions><TextBox x:Name="InputBox"/><Button x:Name="BrowseInput" Grid.Column="1" Content="…" ToolTip="Выбрать локальный файл"/><Button x:Name="PasteInput" Grid.Column="2" Content="Вставить" ToolTip="Вставить ссылку из буфера обмена"/></Grid>
              <Border Background="#0B1722" BorderBrush="#28435D" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,1,0,8"><StackPanel>
                <TextBlock x:Name="SourceResolutionText" Text="Исходник: разрешение ещё не прочитано" FontSize="17" FontWeight="SemiBold" Foreground="#78D9FF"/>
                <TextBlock x:Name="VideoInfo" Text="Выберите MP4/MKV/MOV/WebM или вставьте ссылку VK Video" Foreground="#8EA1BA" TextWrapping="Wrap" Margin="0,4,0,0"/>
                <TextBlock x:Name="ExpectedTimeText" Text="Ожидаемое время появится после выбора видео" Foreground="#D7B36C" TextWrapping="Wrap" Margin="0,4,0,0"/>
              </StackPanel></Border>
              <StackPanel x:Name="RecordingPathPanel"><TextBlock Text="Папка для готовых записей"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="45"/></Grid.ColumnDefinitions><TextBox x:Name="OutputBox"/><Button x:Name="BrowseOutput" Grid.Column="1" Content="…"/></Grid></StackPanel>
            </StackPanel>
          </GroupBox>

          <TabControl x:Name="WorkspaceTabs" Height="112" Margin="0,0,0,12" Background="#0A1019" BorderBrush="#334B6D">
            <TabItem Header="▶  REALTIME" Tag="Realtime"><Border Background="#0D1822" Padding="14"><StackPanel><TextBlock Text="Живой GPU-вывод" FontSize="18" FontWeight="SemiBold" Foreground="#61D9FF"/><TextBlock Text="Буфер, перемотка, полноэкранный плеер, DLSS-G и отдельные настройки задержки." Foreground="#93A8C2" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border></TabItem>
            <TabItem Header="●  ЗАПИСЬ" Tag="Recording"><Border Background="#14170F" Padding="14"><StackPanel><TextBlock Text="Файл H.264 / H.265" FontSize="18" FontWeight="SemiBold" Foreground="#B7E36E"/><TextBlock Text="Локальное видео или ссылка; детальные motion/depth-параметры и автоматическое имя результата." Foreground="#A8B696" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border></TabItem>
            <TabItem Header="◉  VR / 3D" Tag="VR"><Border Background="#151224" Padding="14"><StackPanel><TextBlock Text="Отдельный VR-конвейер" FontSize="18" FontWeight="SemiBold" Foreground="#B59CFF"/><TextBlock Text="SBS/Over-Under, настоящие depth-ракурсы, параллакс, окклюзии и временная стабилизация." Foreground="#AEA3CE" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border></TabItem>
          </TabControl>

          <GroupBox x:Name="QuickGroup" Header="БЫСТРЫЙ ЗАПУСК">
            <StackPanel>
              <TextBlock Text="Сценарий"/><ComboBox x:Name="QuickScenarioCombo"><ComboBoxItem Content="Ноутбук · realtime 1080p · ~50 FPS" Tag="Laptop1080"/><ComboBoxItem Content="Ноутбук · realtime 1440p" Tag="Laptop1440"/><ComboBoxItem Content="RTX 5080 · realtime 4K" Tag="RTX5080_4K"/><ComboBoxItem Content="Качественная запись" Tag="QualityRecord"/><ComboBoxItem Content="Настоящий 3D VR · depth SBS" Tag="DepthVR"/></ComboBox>
              <CheckBox x:Name="ExpertCheck" Content="Показать экспертные настройки" IsChecked="False" Margin="0,7,0,0"/>
              <TextBlock x:Name="QuickScenarioInfo" Foreground="#7F91AA" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="VrGroup" Header="VR-ВЫВОД">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Режим просмотра"/><ComboBox x:Name="VrModeCombo"><ComboBoxItem Content="Обычное видео" Tag="Off"/><ComboBoxItem Content="3D VR · разные ракурсы из depth" Tag="DepthSBS"/><ComboBoxItem Content="VR-кинотеатр · плоский SBS" Tag="CinemaSBS"/><ComboBoxItem Content="Панорама 360° · equirectangular" Tag="Equirect360"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Компоновка для шлема"/><ComboBox x:Name="VrLayoutCombo"><ComboBoxItem Content="Half-SBS · та же ширина" Tag="HalfSBS"/><ComboBoxItem Content="Full-SBS · двойная ширина" Tag="FullSBS"/><ComboBoxItem Content="Half-OU · верх/низ" Tag="HalfOU"/><ComboBoxItem Content="Full-OU · двойная высота" Tag="FullOU"/></ComboBox></StackPanel>
              </Grid>
              <Expander Header="ТОНКАЯ НАСТРОЙКА DEPTH-СТЕРЕО" Foreground="#C1B4EE" Margin="2,4,2,9">
                <Border BorderBrush="#3A315B" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,7,0,0"><StackPanel>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Гамма глубины"/><TextBlock x:Name="VRDepthGammaValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRDepthGammaSlider" Minimum="0.25" Maximum="3" Value="1" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Заполнение раскрытых краёв"/><TextBlock x:Name="VROcclusionValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VROcclusionSlider" Minimum="0" Maximum="1" Value="0.65" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Смягчение границ depth"/><TextBlock x:Name="VREdgeValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VREdgeSlider" Minimum="0" Maximum="12" Value="2" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Временная стабилизация depth"/><TextBlock x:Name="VRTemporalValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRTemporalSlider" Minimum="0" Maximum="0.95" Value="0.55" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <CheckBox x:Name="VREyeSwapCheck" Content="Поменять левый и правый глаз"/>
                </StackPanel></Border>
              </Expander>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Модель глубины"/><ComboBox x:Name="DepthModelCombo"><ComboBoxItem Content="DA2 Small · realtime" Tag="DA2Small"/><ComboBoxItem Content="Video Depth Anything · стабильное видео" Tag="VideoDepthSmall"/><ComboBoxItem Content="Depth Anything 3 Small · качество" Tag="DA3Small"/><ComboBoxItem Content="Depth Anything 3 Base · максимум" Tag="DA3Base"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Сила 3D"/><TextBlock x:Name="VREyeValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="VREyeSlider" Minimum="0.1" Maximum="3" Value="1" TickFrequency="0.1" IsSnapToTickEnabled="True"/><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Плоскость фокуса"/><TextBlock x:Name="VRConvergenceValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="VRConvergenceSlider" Minimum="0.1" Maximum="0.9" Value="0.48" TickFrequency="0.02" IsSnapToTickEnabled="True"/></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Плавность вывода"/><TextBlock Text="Настраивается в realtime-плеере: GPU motion x2 работает после DLSS и не удваивает число нейропроходов." Foreground="#7F91AA" TextWrapping="Wrap"/></StackPanel>
                <StackPanel Grid.Column="2"><CheckBox x:Name="RealtimeAudioCheck" Content="Синхронный звук" IsChecked="True"/><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Громкость"/><TextBlock x:Name="RealtimeVolumeValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="RealtimeVolumeSlider" Minimum="0" Maximum="100" Value="80" TickFrequency="5" IsSnapToTickEnabled="True"/></StackPanel>
              </Grid>
              <Border Background="#111627" BorderBrush="#3A4770" BorderThickness="1" CornerRadius="8" Padding="9"><TextBlock x:Name="VrInfo" Foreground="#B5C3E7" TextWrapping="Wrap"/></Border>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="OutputGroup" Header="ВЫХОД">
            <StackPanel>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Разрешение обработки и вывода"/><ComboBox x:Name="ModeCombo"><ComboBoxItem Content="Как в оригинале" Tag="Source"/><ComboBoxItem Content="2160p / до 4K" Tag="2160p"/><ComboBoxItem Content="1440p" Tag="1440p"/><ComboBoxItem Content="1080p" Tag="1080p"/><ComboBoxItem Content="720p" Tag="720p"/><ComboBoxItem Content="540p · минимальная нагрузка" Tag="540p"/></ComboBox></StackPanel>
              <StackPanel Grid.Column="2"><TextBlock Text="Кодек"/><ComboBox x:Name="CodecCombo"><ComboBoxItem Content="H.265 / HEVC (рекомендуется)" Tag="H265"/><ComboBoxItem Content="H.264 / AVC" Tag="H264"/></ComboBox></StackPanel>
            </Grid>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Железо"/><ComboBox x:Name="HardwareCombo"><ComboBoxItem Content="Авто" Tag="Auto"/><ComboBoxItem Content="Ноутбук · RTX 4060 8 ГБ" Tag="Laptop8GB"/><ComboBoxItem Content="RTX 5080 16 ГБ" Tag="RTX5080"/></ComboBox></StackPanel>
              <StackPanel Grid.Column="2"><TextBlock Text="Внутреннее разрешение DLSS"/><ComboBox x:Name="RenderPresetCombo"><ComboBoxItem Content="Авто под железо" Tag="Auto"/><ComboBoxItem Content="Quality · 75%" Tag="Quality"/><ComboBoxItem Content="Balanced · 67%" Tag="Balanced"/><ComboBoxItem Content="Performance · 50%" Tag="Performance"/><ComboBoxItem Content="Native / DLAA · 100%" Tag="Native"/></ComboBox></StackPanel>
            </Grid>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Профиль скорости"/><ComboBox x:Name="PerformanceCombo"><ComboBoxItem Content="Качество · точные карты" Tag="Quality"/><ComboBoxItem Content="Баланс · точнее" Tag="Balanced"/><ComboBoxItem Content="Турбо-запись · максимум FPS" Tag="Turbo"/><ComboBoxItem Content="Реальное время · низкая задержка" Tag="Realtime"/></ComboBox></StackPanel>
               <StackPanel Grid.Column="2"><TextBlock Text="Живой вывод"/><CheckBox x:Name="LivePreviewCheck" Content="Показывать обработанные кадры" ToolTip="В профиле «Реальное время» включается обязательно, а запись файла полностью отключается."/></StackPanel>
            </Grid>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="65"/></Grid.ColumnDefinitions><TextBlock Text="Качество NVENC (меньше = лучше)"/><TextBlock x:Name="QualityValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
            <Slider x:Name="QualitySlider" Minimum="12" Maximum="32" TickFrequency="1" IsSnapToTickEnabled="True"/>
            <WrapPanel><CheckBox x:Name="ComparisonCheck" Content="Сравнение: оригинал слева" IsChecked="True"/><CheckBox x:Name="KeepTempCheck" Content="Сохранить временные файлы"/></WrapPanel>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="RealtimePanel" Header="REALTIME-ПЛЕЕР">
            <StackPanel>
              <CheckBox x:Name="RealtimeFullscreenCheck" Content="Запускать сразу на весь экран" IsChecked="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Профиль карт движения/глубины"/><ComboBox x:Name="RealtimeQualityCombo"><ComboBoxItem Content="Скорость" Tag="Fast"/><ComboBoxItem Content="Баланс" Tag="Balanced"/><ComboBoxItem Content="Качество" Tag="Quality"/><ComboBoxItem Content="Максимум" Tag="Max"/><ComboBoxItem Content="Вручную" Tag="Custom"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Качество сетевого потока"/><ComboBox x:Name="NetworkHeightCombo"><ComboBoxItem Content="До 720p" Tag="720"/><ComboBoxItem Content="До 1080p" Tag="1080"/><ComboBoxItem Content="До 1440p" Tag="1440"/><ComboBoxItem Content="До 2160p / 4K" Tag="2160"/></ComboBox></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Генерация кадров"/><ComboBox x:Name="FrameGenerationCombo"><ComboBoxItem Content="NVIDIA DLSS-G · x2 + Reflex" Tag="NvidiaDLSSG"/><ComboBoxItem Content="GPU motion · x2 · универсально" Tag="MotionGPU"/><ComboBoxItem Content="Выкл." Tag="Off"/><ComboBoxItem Content="Старый blend · совместимость" Tag="CompatibilityBlend"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Базовый/целевой FPS"/><ComboBox x:Name="RealtimeFpsCombo"><ComboBoxItem Content="Как в исходнике" Tag="Source"/><ComboBoxItem Content="x2 / до 60" Tag="Double"/><ComboBoxItem Content="Цель 60" Tag="60"/></ComboBox></StackPanel>
              </Grid>
              <TextBlock Text="Cookies для закрытых/возрастных ссылок"/><ComboBox x:Name="NetworkCookiesCombo"><ComboBoxItem Content="Не использовать · публичные видео" Tag="None"/><ComboBoxItem Content="Google Chrome" Tag="chrome"/><ComboBoxItem Content="Microsoft Edge" Tag="edge"/><ComboBoxItem Content="Mozilla Firefox" Tag="firefox"/></ComboBox>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions><TextBlock Text="Предварительная буферизация"/><TextBlock x:Name="RealtimeBufferValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="RealtimeBufferSlider" Minimum="3" Maximum="30" Value="5" TickFrequency="1" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions><TextBlock Text="Размер чанка (0 = авто под GPU)"/><TextBlock x:Name="RealtimeChunkValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="RealtimeChunkSlider" Minimum="0" Maximum="192" Value="0" TickFrequency="8" IsSnapToTickEnabled="True"/>
              <Border Background="#0B1722" BorderBrush="#28435D" BorderThickness="1" CornerRadius="8" Padding="9" Margin="0,0,0,7"><TextBlock x:Name="RealtimeQualityInfo" Foreground="#78D9FF" TextWrapping="Wrap"/></Border>
              <Expander Header="ТОНКАЯ НАСТРОЙКА REALTIME" Foreground="#B6C5D8" Margin="2,1,2,9">
                <Border BorderBrush="#27384F" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,7,0,0"><StackPanel>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Разрешение guide-карты"/><TextBlock x:Name="GuideWidthValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="GuideWidthSlider" Minimum="256" Maximum="768" Value="320" TickFrequency="64" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Полная глубина: каждые N кадров"/><TextBlock x:Name="DepthIntervalValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="DepthIntervalSlider" Minimum="1" Maximum="24" Value="24" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Минимальный интервал адаптивной глубины"/><TextBlock x:Name="DepthMinIntervalValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="DepthMinIntervalSlider" Minimum="1" Maximum="24" Value="12" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Порог уверенности motion"/><TextBlock x:Name="AdaptiveConfidenceValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="AdaptiveConfidenceSlider" Minimum="0" Maximum="1" Value="0.75" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Порог сильного движения"/><TextBlock x:Name="AdaptiveMotionValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="AdaptiveMotionSlider" Minimum="0" Maximum="30" Value="10" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Стабилизация глубины во времени"/><TextBlock x:Name="TemporalDepthValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="TemporalDepthSlider" Minimum="0" Maximum="0.9" Value="0.55" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Чувствительность смены сцены"/><TextBlock x:Name="SceneCutValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="SceneCutSlider" Minimum="0.03" Maximum="0.35" Value="0.12" TickFrequency="0.01" IsSnapToTickEnabled="True"/>
                  <TextBlock Text="Точность оптического потока"/><ComboBox x:Name="GuideMotionPresetCombo"><ComboBoxItem Content="Realtime · максимально быстро" Tag="realtime"/><ComboBoxItem Content="Balanced · точнее границы" Tag="balanced"/><ComboBoxItem Content="Quality · максимум вычислений" Tag="quality"/></ComboBox>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Motion backend"/><ComboBox x:Name="GuideMotionBackendCombo"><ComboBoxItem Content="DIS · быстрый CPU" Tag="dis"/><ComboBoxItem Content="RAFT-small · neural CUDA" Tag="raft"/></ComboBox></StackPanel>
                    <StackPanel Grid.Column="2"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Итерации RAFT"/><TextBlock x:Name="RaftUpdatesValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="RaftUpdatesSlider" Minimum="2" Maximum="10" Value="4" TickFrequency="1" IsSnapToTickEnabled="True"/></StackPanel>
                  </Grid>
                </StackPanel></Border>
              </Expander>
              <Border Background="#0C1622" BorderBrush="#263A51" BorderThickness="1" CornerRadius="8" Padding="9"><TextBlock Text="Управление в окне видео: Space — пауза; ←/→ — 10 с; Ctrl+←/→ — 60 с; Shift+←/→ или PageUp/PageDown — 5 мин; F11 или двойной клик — весь экран; F1/Tab — показать панель." Foreground="#9DB0C8" TextWrapping="Wrap"/></Border>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="RecordingPanel" Header="ЗАПИСЬ И ТОЧНЫЕ MOTION / DEPTH-КАРТЫ">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Качество видео по ссылке"/><ComboBox x:Name="RecordNetworkHeightCombo"><ComboBoxItem Content="До 720p" Tag="720"/><ComboBoxItem Content="До 1080p" Tag="1080"/><ComboBoxItem Content="До 1440p" Tag="1440"/><ComboBoxItem Content="До 2160p / 4K" Tag="2160"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Cookies браузера"/><ComboBox x:Name="RecordNetworkCookiesCombo"><ComboBoxItem Content="Не использовать" Tag="None"/><ComboBoxItem Content="Chrome" Tag="chrome"/><ComboBoxItem Content="Edge" Tag="edge"/><ComboBoxItem Content="Firefox" Tag="firefox"/></ComboBox></StackPanel>
              </Grid>
              <CheckBox x:Name="RecordFineGuideCheck" Content="Переопределить профиль и настроить карты вручную" IsChecked="False"/>
              <Expander x:Name="RecordFineGuideExpander" Header="ТОНКАЯ НАСТРОЙКА ЗАПИСИ / VR" Foreground="#B6C5D8" IsExpanded="False">
                <Border BorderBrush="#33452C" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,7,0,0"><StackPanel>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Разрешение guide-карты"/><TextBlock x:Name="RecordGuideWidthValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordGuideWidthSlider" Minimum="256" Maximum="1024" Value="480" TickFrequency="64" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Полная нейроглубина: каждые N кадров"/><TextBlock x:Name="RecordDepthIntervalValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordDepthIntervalSlider" Minimum="1" Maximum="48" Value="2" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Минимальный адаптивный интервал"/><TextBlock x:Name="RecordDepthMinValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordDepthMinSlider" Minimum="1" Maximum="48" Value="2" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Порог уверенности"/><TextBlock x:Name="RecordConfidenceValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordConfidenceSlider" Minimum="0" Maximum="1" Value="0.45" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Порог движения"/><TextBlock x:Name="RecordMotionValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordMotionSlider" Minimum="0" Maximum="40" Value="10" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Временное смешивание depth"/><TextBlock x:Name="RecordTemporalValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordTemporalSlider" Minimum="0" Maximum="0.95" Value="0.35" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="Порог смены сцены"/><TextBlock x:Name="RecordSceneValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordSceneSlider" Minimum="0.03" Maximum="0.35" Value="0.12" TickFrequency="0.01" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Motion preset"/><ComboBox x:Name="RecordMotionPresetCombo"><ComboBoxItem Content="Quality" Tag="quality"/><ComboBoxItem Content="Balanced" Tag="balanced"/><ComboBoxItem Content="Realtime" Tag="realtime"/></ComboBox></StackPanel>
                    <StackPanel Grid.Column="2"><TextBlock Text="Motion backend"/><ComboBox x:Name="RecordMotionBackendCombo"><ComboBoxItem Content="DIS · быстрее" Tag="dis"/><ComboBoxItem Content="RAFT-small · CUDA" Tag="raft"/></ComboBox></StackPanel>
                  </Grid>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Итерации RAFT"/><TextBlock x:Name="RecordRaftValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordRaftSlider" Minimum="2" Maximum="10" Value="4" TickFrequency="1" IsSnapToTickEnabled="True"/></StackPanel>
                    <StackPanel Grid.Column="2"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Кадров в чанке (0 = авто)"/><TextBlock x:Name="RecordChunkValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordChunkSlider" Minimum="0" Maximum="192" Value="0" TickFrequency="8" IsSnapToTickEnabled="True"/></StackPanel>
                  </Grid>
                </StackPanel></Border>
              </Expander>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="StageGroup" Header="ОЧЕРЕДНОСТЬ НЕЙРОННЫХ ПРОХОДОВ">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="94"/></Grid.ColumnDefinitions>
                <ListBox x:Name="StageList" Height="68" Background="#0C131E" Foreground="#DCE7F5" BorderBrush="#2B3D57" Padding="4"/>
                <StackPanel Grid.Column="1"><Button x:Name="StageUp" Content="▲ Выше"/><Button x:Name="StageDown" Content="▼ Ниже"/></StackPanel>
              </Grid>
              <TextBlock x:Name="StageOrderInfo" Text="VR-упаковка и кодек всегда выполняются после нейронных проходов." Foreground="#7F91AA" TextWrapping="Wrap" Margin="0,5,0,0"/>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="UpscalerGroup" Header="НЕЙРОННЫЙ ВИДЕО-АПСКЕЙЛ">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Модель"/><ComboBox x:Name="UpscalerCombo"><ComboBoxItem Content="Без внешней модели · только DLSS5" Tag="None"/><ComboBoxItem Content="NanoVSR · только быстрый preview" Tag="NanoVSR"/><ComboBoxItem Content="AnimeSR v2 · аниме temporal x4" Tag="AnimeSR"/><ComboBoxItem Content="FlashVSR v1.1 · diffusion" Tag="FlashVSR"/><ComboBoxItem Content="DLoRAL · максимум деталей" Tag="DLoRAL"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Вариант"/><ComboBox x:Name="UpscalerVariantCombo"><ComboBoxItem Content="Авто · адаптация VRAM" Tag="Auto"/><ComboBoxItem Content="Realtime · минимум вычислений" Tag="Realtime"/><ComboBoxItem Content="Balanced · быстрее" Tag="Balanced"/><ComboBoxItem Content="Quality · сильная детализация" Tag="Quality"/><ComboBoxItem Content="Max · стабильность" Tag="Max"/></ComboBox></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Сила восстановления модели"/><TextBlock x:Name="UpscalerStrengthValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#FFB65C"/></Grid>
              <Slider x:Name="UpscalerStrengthSlider" Minimum="0" Maximum="1" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Border Background="#16130C" BorderBrush="#5B4628" BorderThickness="1" CornerRadius="8" Padding="9"><TextBlock x:Name="UpscalerInfo" Foreground="#D5B77A" TextWrapping="Wrap"/></Border>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="NeuralGroup" Header="ПРЕСЕТ И НЕЙРОННЫЙ РЕНДЕРИНГ">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="90"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions><ComboBox x:Name="PresetBox" IsEditable="True"/><Button x:Name="SavePreset" Grid.Column="1" Content="Сохранить"/><Button x:Name="DeletePreset" Grid.Column="2" Content="Удалить"/></Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="NR Intensity"/><TextBlock x:Name="IntensityValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="IntensitySlider" Minimum="0" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Local Tone"/><TextBlock x:Name="ToneValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="ToneSlider" Minimum="0" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Local Structure · окружение"/><TextBlock x:Name="StructureValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="StructureSlider" Minimum="0" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Skin Structure · персонажи"/><TextBlock x:Name="SkinValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="SkinSlider" Minimum="-1" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="NR Preset"/><ComboBox x:Name="NrPresetCombo"><ComboBoxItem Content="Default" Tag="0"/><ComboBoxItem Content="Preset #1" Tag="1"/><ComboBoxItem Content="Preset #2" Tag="2"/><ComboBoxItem Content="Preset #3" Tag="3"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="NR Style"/><ComboBox x:Name="StyleCombo"><ComboBoxItem Content="Default" Tag="0"/><ComboBoxItem Content="Natural" Tag="1"/><ComboBoxItem Content="Cinematic" Tag="2"/></ComboBox></StackPanel>
              </Grid>
              <WrapPanel><CheckBox x:Name="AutoMaskCheck" Content="Automatic Mask"/><CheckBox x:Name="UpliftCheck" Content="Neural Uplift"/><CheckBox x:Name="UICorrectionCheck" Content="UI Correction"/></WrapPanel>
              <Border Background="#0C1622" BorderBrush="#263A51" BorderThickness="1" CornerRadius="8" Padding="9"><TextBlock x:Name="AggressionText" Foreground="#9DB0C8" TextWrapping="Wrap"/></Border>
            </StackPanel>
          </GroupBox>

          <Expander x:Name="AdvancedParams" Header="РАСШИРЕННЫЕ ПАРАМЕТРЫ" Foreground="#B6C5D8" Margin="2,0,2,12">
            <Border BorderBrush="#27384F" BorderThickness="1" CornerRadius="8" Padding="11" Margin="0,8,0,0"><StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Motion Scale X"/><TextBlock x:Name="MotionXValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="MotionXSlider" Minimum="0.5" Maximum="1.5" TickFrequency="0.01" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Motion Scale Y"/><TextBlock x:Name="MotionYValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="MotionYSlider" Minimum="0.5" Maximum="1.5" TickFrequency="0.01" IsSnapToTickEnabled="True"/>
              <TextBlock Text="Depth Convention"/><ComboBox x:Name="DepthCombo"><ComboBoxItem Content="Automatic" Tag="0"/><ComboBoxItem Content="Normal depth" Tag="1"/><ComboBoxItem Content="Inverted depth" Tag="2"/></ComboBox>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="HDR Transfer"/><TextBlock x:Name="TransferValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="TransferSlider" Minimum="0" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Color Strength"/><TextBlock x:Name="ColorValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="ColorSlider" Minimum="0" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions><TextBlock Text="Paper-White Scale"/><TextBlock x:Name="PaperValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="PaperSlider" Minimum="0.25" Maximum="4" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
            </StackPanel></Border>
          </Expander>

          <GroupBox x:Name="RangeGroup" Header="ДИАПАЗОН">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Старт, секунд"/><TextBox x:Name="StartBox" Text="0"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="Количество кадров"/><TextBox x:Name="FramesBox" Text="8"/></StackPanel></Grid>
              <CheckBox x:Name="FullVideoCheck" Content="Обработать всё видео от указанного старта"/>
              <TextBlock x:Name="RangeHint" Text="Для быстрого подбора настроек начните с 8–24 кадров." Foreground="#7F91AA" TextWrapping="Wrap"/>
            </StackPanel>
          </GroupBox>
        </StackPanel></ScrollViewer>
      </Border>

      <Border Grid.Column="2" Background="#101722" BorderBrush="#25344B" BorderThickness="1" CornerRadius="14" Padding="16">
        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="2,0,2,12"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="StatusText" Text="Готово к работе" FontSize="20" FontWeight="SemiBold"/><TextBlock x:Name="DetailText" Text="Выберите видео — motion и depth будут созданы автоматически" Foreground="#8091AA" Margin="0,4,0,0"/><WrapPanel Margin="0,5,0,0"><TextBlock x:Name="EtaText" Text="Осталось: —" Foreground="#FFD077" Margin="0,0,18,0"/><TextBlock x:Name="ElapsedText" Text="Прошло: 00:00" Foreground="#8295AD"/></WrapPanel></StackPanel><Border Grid.Column="1" Background="#151E32" BorderBrush="#374C77" BorderThickness="1" CornerRadius="9" Padding="14,8"><TextBlock x:Name="SpeedText" Text="— FPS" Foreground="#ABC9FF" FontSize="17" FontWeight="SemiBold"/></Border></Grid>
          <TabControl Grid.Row="1" Background="#080B10" BorderBrush="#27384F"><TabItem Header="ПРЕДПРОСМОТР"><Grid Background="#05070B"><MediaElement x:Name="Preview" LoadedBehavior="Manual" UnloadedBehavior="Manual" Stretch="Uniform"/><Border x:Name="Placeholder" Background="#0B111A" CornerRadius="8" HorizontalAlignment="Center" VerticalAlignment="Center" Padding="28,18"><StackPanel><TextBlock Text="▶" FontSize="42" HorizontalAlignment="Center" Foreground="#4D668B"/><TextBlock Text="Здесь появится готовое видео" Foreground="#7D8CA3" Margin="0,8,0,0"/></StackPanel></Border></Grid></TabItem><TabItem Header="ЖУРНАЛ"><TextBox x:Name="LogBox" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="#05070B" Foreground="#ADC4DF" BorderThickness="0"/></TabItem></TabControl>
          <StackPanel Grid.Row="2" Margin="0,12,0,0"><ProgressBar x:Name="Progress" Height="8" Minimum="0" Maximum="100" Foreground="#59D4FF" Background="#192334"/><Grid Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ProgressHint" Text="Все служебные карты создаются внутри программы" Foreground="#74839A" VerticalAlignment="Center"/><StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="PlayButton" Content="▶ / ❚❚" IsEnabled="False"/><Button x:Name="OpenVideo" Content="Открыть видео" IsEnabled="False"/><Button x:Name="OpenFolder" Content="Папка результата" IsEnabled="False"/></StackPanel></Grid></StackPanel>
        </Grid>
      </Border>
    </Grid>

    <Border Grid.Row="2" Background="#101722" BorderBrush="#25344B" BorderThickness="1" CornerRadius="14" Padding="8" Margin="0,10,0,0"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Esc — немедленная остановка всего дерева процессов. Частичный файл не считается готовым." Foreground="#8190A6" VerticalAlignment="Center" Margin="8,0"/><Button x:Name="CancelButton" Grid.Column="1" Content="■ ПРЕРВАТЬ СЕЙЧАС" IsEnabled="False" Background="#6B1F2C" BorderBrush="#E06270" Foreground="#FFFFFF" FontWeight="SemiBold" MinWidth="175"/><Button x:Name="RunButton" Grid.Column="2" Content="ЗАПУСТИТЬ" Background="#16637B" BorderBrush="#42BBD9" FontWeight="SemiBold" MinWidth="185"/></Grid></Border>
  </Grid>
</Window>
'@

$Reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($Reader)
$Names = @('RuntimeStatus','InputBox','BrowseInput','PasteInput','SourceResolutionText','VideoInfo','ExpectedTimeText','RecordingPathPanel','OutputBox','BrowseOutput','QuickScenarioCombo','ExpertCheck','QuickScenarioInfo','VrGroup','StageGroup','UpscalerGroup','NeuralGroup','AdvancedParams','HardwareCombo','RenderPresetCombo','DepthModelCombo','VREyeSlider','VREyeValue','VRConvergenceSlider','VRConvergenceValue','FrameGenerationCombo','ModeCombo','CodecCombo','PerformanceCombo','LivePreviewCheck','QualitySlider','QualityValue','ComparisonCheck','KeepTempCheck','VrModeCombo','VrLayoutCombo','VrInfo','RealtimePanel','RealtimeFullscreenCheck','RealtimeQualityCombo','RealtimeQualityInfo','NetworkHeightCombo','NetworkCookiesCombo','RealtimeFpsCombo','RealtimeAudioCheck','RealtimeVolumeSlider','RealtimeVolumeValue','RealtimeBufferSlider','RealtimeBufferValue','GuideWidthSlider','GuideWidthValue','DepthIntervalSlider','DepthIntervalValue','DepthMinIntervalSlider','DepthMinIntervalValue','AdaptiveConfidenceSlider','AdaptiveConfidenceValue','AdaptiveMotionSlider','AdaptiveMotionValue','TemporalDepthSlider','TemporalDepthValue','SceneCutSlider','SceneCutValue','GuideMotionPresetCombo','GuideMotionBackendCombo','RaftUpdatesSlider','RaftUpdatesValue','UpscalerCombo','UpscalerVariantCombo','UpscalerStrengthSlider','UpscalerStrengthValue','UpscalerInfo','StageList','StageUp','StageDown','StageOrderInfo','PresetBox','SavePreset','DeletePreset','IntensitySlider','IntensityValue','ToneSlider','ToneValue','StructureSlider','StructureValue','SkinSlider','SkinValue','NrPresetCombo','StyleCombo','AutoMaskCheck','UpliftCheck','UICorrectionCheck','AggressionText','MotionXSlider','MotionXValue','MotionYSlider','MotionYValue','DepthCombo','TransferSlider','TransferValue','ColorSlider','ColorValue','PaperSlider','PaperValue','StartBox','FramesBox','FullVideoCheck','RangeHint','StatusText','DetailText','EtaText','ElapsedText','SpeedText','Preview','Placeholder','LogBox','Progress','ProgressHint','PlayButton','OpenVideo','OpenFolder','CancelButton','RunButton')
foreach ($Name in $Names) { Set-Variable -Name $Name -Value $Window.FindName($Name) -Scope Script }
$AdditionalNames = @(
    'WorkspaceTabs','QuickGroup','OutputGroup','RecordingPanel','RangeGroup','RealtimeChunkSlider','RealtimeChunkValue',
    'RecordNetworkHeightCombo','RecordNetworkCookiesCombo','RecordFineGuideCheck','RecordFineGuideExpander',
    'RecordGuideWidthSlider','RecordGuideWidthValue','RecordDepthIntervalSlider','RecordDepthIntervalValue',
    'RecordDepthMinSlider','RecordDepthMinValue','RecordConfidenceSlider','RecordConfidenceValue',
    'RecordMotionSlider','RecordMotionValue','RecordTemporalSlider','RecordTemporalValue','RecordSceneSlider','RecordSceneValue',
    'RecordMotionPresetCombo','RecordMotionBackendCombo','RecordRaftSlider','RecordRaftValue','RecordChunkSlider','RecordChunkValue',
    'VRDepthGammaSlider','VRDepthGammaValue','VROcclusionSlider','VROcclusionValue','VREdgeSlider','VREdgeValue',
    'VRTemporalSlider','VRTemporalValue','VREyeSwapCheck'
)
foreach ($Name in $AdditionalNames) { Set-Variable -Name $Name -Value $Window.FindName($Name) -Scope Script }

$BuiltIn = [ordered]@{
    'Balanced · рекомендовано' = [ordered]@{ intensity=1.35; tone=1.15; structure=1.75; skin=1.25; preset=1; style=1; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
    'Natural · мягко' = [ordered]@{ intensity=1.05; tone=1.0; structure=1.0; skin=-1.0; preset=1; style=1; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
    'Strong · максимум' = [ordered]@{ intensity=2.0; tone=1.6; structure=2.0; skin=1.65; preset=1; style=1; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
    'Cinematic' = [ordered]@{ intensity=1.35; tone=1.35; structure=1.35; skin=1.0; preset=2; style=2; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
}
$RealtimeProfiles = [ordered]@{
    Fast = [ordered]@{ guide=256; interval=24; minimum=12; confidence=0.0; motion=0.0; temporal=0.85; scene=0.15; preset='realtime'; backend='dis'; updates=4; text='Максимум FPS: быстрый DIS-flow, depth 1/24 и сильная временная стабилизация. Для ноутбука и 50–60 FPS.' }
    Balanced = [ordered]@{ guide=320; interval=24; minimum=12; confidence=0.0; motion=0.0; temporal=0.85; scene=0.12; preset='realtime'; backend='raft'; updates=4; text='Рекомендуется: RAFT-small CUDA 4 итерации, depth 1/24 и перенос depth по нейросетевым векторам. Меньше плавания и около 50 FPS на ноутбуке при 540p.' }
    Quality = [ordered]@{ guide=480; interval=12; minimum=6; confidence=0.55; motion=15.0; temporal=0.68; scene=0.10; preset='balanced'; backend='raft'; updates=4; text='Точнее границы персонажей: RAFT 480 px и более частая depth. Нагрузка заметно выше; лучше снижать разрешение вывода.' }
    Max = [ordered]@{ guide=640; interval=4; minimum=2; confidence=0.50; motion=10.0; temporal=0.45; scene=0.08; preset='quality'; backend='raft'; updates=8; text='RAFT 8 итераций, guide 640 px и depth 1/4. Для RTX 5080 или коротких тестов, не профиль ноутбука.' }
}
$script:UserPresets = [ordered]@{}
$script:Process = $null
$script:Stdout = $null
$script:Stderr = $null
$script:Queue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:Result = $null
$script:LastError = $null
$script:Finalized = $false
$script:IsPlaying = $false
$script:LastOutputVideo = $null
$script:EphemeralConfig = $null
$script:EphemeralControl = $null
$script:WasRealtime = $false
$script:RecordPreviewChoice = $false
$script:RecordModeTag = 'Source'
$script:PipelineMutex = $null
$script:PipelineMutexHeld = $false
$script:StageOrder = [Collections.Generic.List[string]]::new()
$script:StageOrder.Add('VSR')
$script:StageOrder.Add('DLSS5')
$script:SourceInfo = $null
$script:Cancelled = $false
$script:RunStartedAt = $null
$script:LastProgressAt = $null
$script:LastEtaSeconds = $null
$script:ActiveWork = $null
$script:RunJournal = $null
$script:ApplyingRealtimeProfile = $false

function Tag($Combo) { if ($Combo.SelectedItem) { return [int]$Combo.SelectedItem.Tag }; return 0 }
function Select-Tag($Combo,[int]$Value) { foreach($Item in $Combo.Items){ if([int]$Item.Tag -eq $Value){$Combo.SelectedItem=$Item;break} } }
function F([double]$Value) { $Value.ToString('0.00',$Invariant) }
function Combo-Tag($Combo) { if ($Combo.SelectedItem) { return [string]$Combo.SelectedItem.Tag }; return '' }
function Select-StringTag($Combo,[string]$Value) { foreach($Item in $Combo.Items){ if([string]$Item.Tag -eq $Value){$Combo.SelectedItem=$Item;break} } }
function Format-Time([double]$Seconds) {
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) { return '—' }
    $Span = [TimeSpan]::FromSeconds([math]::Ceiling($Seconds))
    if ($Span.TotalHours -ge 1) { return $Span.ToString('hh\:mm\:ss') }
    return $Span.ToString('mm\:ss')
}
function Current-Settings { [ordered]@{ intensity=[double]$IntensitySlider.Value; tone=[double]$ToneSlider.Value; structure=[double]$StructureSlider.Value; skin=[double]$SkinSlider.Value; preset=(Tag $NrPresetCombo); style=(Tag $StyleCombo); automask=[bool]$AutoMaskCheck.IsChecked; uplift=[bool]$UpliftCheck.IsChecked; ui=[bool]$UICorrectionCheck.IsChecked; motionx=[double]$MotionXSlider.Value; motiony=[double]$MotionYSlider.Value; depth=(Tag $DepthCombo); transfer=[double]$TransferSlider.Value; color=[double]$ColorSlider.Value; paper=[double]$PaperSlider.Value } }
function Apply-Settings($S) { $IntensitySlider.Value=$S.intensity; $ToneSlider.Value=$S.tone; $StructureSlider.Value=$S.structure; $SkinSlider.Value=$S.skin; Select-Tag $NrPresetCombo $S.preset; Select-Tag $StyleCombo $S.style; $AutoMaskCheck.IsChecked=$S.automask; $UpliftCheck.IsChecked=$S.uplift; $UICorrectionCheck.IsChecked=$S.ui; $MotionXSlider.Value=$S.motionx; $MotionYSlider.Value=$S.motiony; Select-Tag $DepthCombo $S.depth; $TransferSlider.Value=$S.transfer; $ColorSlider.Value=$S.color; $PaperSlider.Value=$S.paper }
function Refresh-Labels {
    $IntensityValue.Text=F $IntensitySlider.Value; $ToneValue.Text=F $ToneSlider.Value; $StructureValue.Text=F $StructureSlider.Value; $SkinValue.Text=F $SkinSlider.Value
    $MotionXValue.Text=F $MotionXSlider.Value; $MotionYValue.Text=F $MotionYSlider.Value; $TransferValue.Text=F $TransferSlider.Value; $ColorValue.Text=F $ColorSlider.Value; $PaperValue.Text=F $PaperSlider.Value
    $QualityValue.Text=[string][int]$QualitySlider.Value; $UpscalerStrengthValue.Text=F $UpscalerStrengthSlider.Value; $RealtimeBufferValue.Text=([string][int]$RealtimeBufferSlider.Value)+' сек'
    $RealtimeChunkValue.Text=if([int]$RealtimeChunkSlider.Value-eq 0){'Авто'}else{[string][int]$RealtimeChunkSlider.Value}
    $RealtimeVolumeValue.Text=([string][int]$RealtimeVolumeSlider.Value)+'%';$RaftUpdatesValue.Text=[string][int]$RaftUpdatesSlider.Value
    $VREyeValue.Text=F $VREyeSlider.Value; $VRConvergenceValue.Text=F $VRConvergenceSlider.Value
    $GuideWidthValue.Text=([string][int]$GuideWidthSlider.Value)+' px'; $DepthIntervalValue.Text=[string][int]$DepthIntervalSlider.Value; $DepthMinIntervalValue.Text=[string][int]$DepthMinIntervalSlider.Value
    $AdaptiveConfidenceValue.Text=F $AdaptiveConfidenceSlider.Value; $AdaptiveMotionValue.Text=F $AdaptiveMotionSlider.Value; $TemporalDepthValue.Text=F $TemporalDepthSlider.Value; $SceneCutValue.Text=F $SceneCutSlider.Value
    $RecordGuideWidthValue.Text=([string][int]$RecordGuideWidthSlider.Value)+' px';$RecordDepthIntervalValue.Text=[string][int]$RecordDepthIntervalSlider.Value;$RecordDepthMinValue.Text=[string][int]$RecordDepthMinSlider.Value
    $RecordConfidenceValue.Text=F $RecordConfidenceSlider.Value;$RecordMotionValue.Text=F $RecordMotionSlider.Value;$RecordTemporalValue.Text=F $RecordTemporalSlider.Value;$RecordSceneValue.Text=F $RecordSceneSlider.Value
    $RecordRaftValue.Text=[string][int]$RecordRaftSlider.Value;$RecordChunkValue.Text=if([int]$RecordChunkSlider.Value-eq 0){'Авто'}else{[string][int]$RecordChunkSlider.Value}
    $VRDepthGammaValue.Text=F $VRDepthGammaSlider.Value;$VROcclusionValue.Text=F $VROcclusionSlider.Value;$VREdgeValue.Text=[string][int]$VREdgeSlider.Value;$VRTemporalValue.Text=F $VRTemporalSlider.Value
    if($IntensitySlider.Value -ge 1.8 -or $StructureSlider.Value -ge 1.9){$AggressionText.Text='Сильное влияние: возможна лишняя дорисовка и изменение лица.';$AggressionText.Foreground='#FF9A9A'}elseif($IntensitySlider.Value -le 1.1){$AggressionText.Text='Мягкое влияние: минимальный риск перерисовки.';$AggressionText.Foreground='#8DD8C5'}else{$AggressionText.Text='Выраженная детализация без максимального общего веса.';$AggressionText.Foreground='#A9BAD0'}
}
function Get-WorkspaceMode {
    if ($WorkspaceTabs -and $WorkspaceTabs.SelectedItem) { return [string]$WorkspaceTabs.SelectedItem.Tag }
    return 'Realtime'
}
function Update-ExpertUi {
    $Expert=[bool]$ExpertCheck.IsChecked
    foreach($Panel in @($StageGroup,$UpscalerGroup,$NeuralGroup,$AdvancedParams)){$Panel.Visibility=if($Expert){'Visible'}else{'Collapsed'}}
}
function Update-WorkspaceUi {
    $Workspace=Get-WorkspaceMode
    $Realtime=$Workspace-eq'Realtime'
    $Vr=$Workspace-eq'VR'
    $RealtimePanel.Visibility=if($Realtime){'Visible'}else{'Collapsed'}
    $RecordingPanel.Visibility=if($Realtime){'Collapsed'}else{'Visible'}
    $VrGroup.Visibility=if($Vr){'Visible'}else{'Collapsed'}
    $QuickGroup.Visibility=if($Realtime){'Visible'}else{'Collapsed'}
    $RecordingPathPanel.Visibility=if($Realtime){'Collapsed'}else{'Visible'}
    if($Realtime){
        Select-StringTag $PerformanceCombo 'Realtime'
        Select-StringTag $VrModeCombo 'Off'
    }else{
        if((Combo-Tag $PerformanceCombo)-eq'Realtime'){Select-StringTag $PerformanceCombo $(if($Vr){'Quality'}else{'Turbo'})}
        if($Vr -and (Combo-Tag $VrModeCombo)-eq'Off'){Select-StringTag $VrModeCombo 'DepthSBS'}
        if(-not $Vr){Select-StringTag $VrModeCombo 'Off'}
    }
    Update-ExpertUi;Update-ProfileUi;Update-VrUi;Update-Estimate
    $RuntimeStatus.Text=if($Realtime){'● REALTIME · GPU-direct'}elseif($Vr){'● VR / 3D · запись'}else{'● ЗАПИСЬ · H.264 / H.265'}
}
function Apply-QuickScenario {
    $Scenario=Combo-Tag $QuickScenarioCombo
    switch($Scenario){
        'Laptop1080' {
            $WorkspaceTabs.SelectedIndex=0
            Select-StringTag $HardwareCombo 'Laptop8GB';Select-StringTag $ModeCombo '1080p';Select-StringTag $RenderPresetCombo 'Auto'
            Select-StringTag $PerformanceCombo 'Realtime';Select-StringTag $UpscalerCombo 'None';Select-StringTag $FrameGenerationCombo 'MotionGPU';Select-StringTag $RealtimeFpsCombo 'Double';Select-StringTag $DepthModelCombo 'DA2Small';Apply-RealtimeProfile 'Fast'
            $QuickScenarioInfo.Text='1280×720 → DLSS 1080p; GPU motion x2 после DLSS. Цель на RTX 4060: около 50 FPS без записи.'
        }
        'Laptop1440' {
            $WorkspaceTabs.SelectedIndex=0
            Select-StringTag $HardwareCombo 'Laptop8GB';Select-StringTag $ModeCombo '1440p';Select-StringTag $RenderPresetCombo 'Auto'
            Select-StringTag $PerformanceCombo 'Realtime';Select-StringTag $UpscalerCombo 'None';Select-StringTag $FrameGenerationCombo 'MotionGPU';Select-StringTag $RealtimeFpsCombo 'Double';Select-StringTag $DepthModelCombo 'DA2Small';Apply-RealtimeProfile 'Fast'
            $QuickScenarioInfo.Text='1600×900 → DLSS 1440p; motion-generation x2. Качество выше, запас FPS ниже, чем у 1080p.'
        }
        'RTX5080_4K' {
            $WorkspaceTabs.SelectedIndex=0
            Select-StringTag $HardwareCombo 'RTX5080';Select-StringTag $ModeCombo '2160p';Select-StringTag $RenderPresetCombo 'Auto'
            Select-StringTag $PerformanceCombo 'Realtime';Select-StringTag $UpscalerCombo 'None';Select-StringTag $FrameGenerationCombo 'NvidiaDLSSG';Select-StringTag $RealtimeFpsCombo 'Source';Select-StringTag $DepthModelCombo 'DA2Small';Apply-RealtimeProfile 'Balanced'
            $QuickScenarioInfo.Text='2560×1440 → DLSS 4K; официальный NVIDIA DLSS-G x2 и Reflex через Streamline. Для RTX 5080.'
        }
        'QualityRecord' {
            $WorkspaceTabs.SelectedIndex=1
            Select-StringTag $HardwareCombo 'Auto';Select-StringTag $ModeCombo '2160p';Select-StringTag $RenderPresetCombo 'Native'
            Select-StringTag $PerformanceCombo 'Quality';Select-StringTag $FrameGenerationCombo 'Off';Select-StringTag $DepthModelCombo 'VideoDepthSmall';Select-StringTag $VrModeCombo 'Off'
            $QuickScenarioInfo.Text='Качественная запись H.265 с временно согласованной Video Depth Anything. Генерация кадров realtime не применяется.'
        }
        'DepthVR' {
            $WorkspaceTabs.SelectedIndex=2
            Select-StringTag $HardwareCombo 'Auto';Select-StringTag $ModeCombo '1440p';Select-StringTag $PerformanceCombo 'Quality';Select-StringTag $DepthModelCombo 'DA3Small';Select-StringTag $VrModeCombo 'DepthSBS';Select-StringTag $VrLayoutCombo 'FullSBS';Select-StringTag $FrameGenerationCombo 'Off'
            $QuickScenarioInfo.Text='Отдельные left/right ракурсы создаются CUDA depth-warp из DA3, затем добавляются VR stereo metadata. Это не дублирование плоского кадра.'
        }
    }
    Update-ExpertUi;Update-ProfileUi;Update-VrUi;Update-Estimate
}
function Update-RealtimeQualityInfo {
    $Tag=Combo-Tag $RealtimeQualityCombo
    if($Tag -eq 'Custom'){
        $RealtimeQualityInfo.Text="Ручной профиль · guide $([int]$GuideWidthSlider.Value) px · depth 1/$([int]$DepthIntervalSlider.Value) · $(Combo-Tag $GuideMotionBackendCombo) $([int]$RaftUpdatesSlider.Value) ит. Больше temporal стабилизирует depth; RAFT точнее DIS, но тяжелее."
    }elseif($RealtimeProfiles.Contains($Tag)){$RealtimeQualityInfo.Text=$RealtimeProfiles[$Tag].text}
}
function Apply-RealtimeProfile([string]$Name) {
    if(-not $RealtimeProfiles.Contains($Name)){Update-RealtimeQualityInfo;return}
    $P=$RealtimeProfiles[$Name];$script:ApplyingRealtimeProfile=$true
    try{
        $GuideWidthSlider.Value=$P.guide;$DepthIntervalSlider.Value=$P.interval;$DepthMinIntervalSlider.Value=$P.minimum
        $AdaptiveConfidenceSlider.Value=$P.confidence;$AdaptiveMotionSlider.Value=$P.motion;$TemporalDepthSlider.Value=$P.temporal;$SceneCutSlider.Value=$P.scene
        Select-StringTag $GuideMotionPresetCombo $P.preset
        Select-StringTag $GuideMotionBackendCombo $P.backend;$RaftUpdatesSlider.Value=$P.updates
    }finally{$script:ApplyingRealtimeProfile=$false}
    Refresh-Labels;Update-RealtimeQualityInfo;Update-Estimate
}
function Mark-RealtimeCustom {
    if($DepthMinIntervalSlider.Value -gt $DepthIntervalSlider.Value){
        $WasApplying=$script:ApplyingRealtimeProfile;$script:ApplyingRealtimeProfile=$true
        try{$DepthMinIntervalSlider.Value=$DepthIntervalSlider.Value}finally{$script:ApplyingRealtimeProfile=$WasApplying}
    }
    $RaftUpdatesSlider.IsEnabled=((Combo-Tag $GuideMotionBackendCombo)-eq'raft') -and ((Combo-Tag $PerformanceCombo)-eq'Realtime')
    if(-not $script:ApplyingRealtimeProfile -and $RealtimeQualityCombo.SelectedItem -and (Combo-Tag $RealtimeQualityCombo) -ne 'Custom'){
        Select-StringTag $RealtimeQualityCombo 'Custom'
    }
    Refresh-Labels;Update-RealtimeQualityInfo;Update-Estimate
}
function Load-Presets { if(Test-Path -LiteralPath $PresetStore){ try{$Data=Get-Content -Raw -LiteralPath $PresetStore|ConvertFrom-Json;foreach($Property in $Data.PSObject.Properties){$script:UserPresets[$Property.Name]=$Property.Value}}catch{} }; Refresh-Presets 'Balanced · рекомендовано' }
function Refresh-Presets([string]$Selected){$PresetBox.Items.Clear();foreach($K in $BuiltIn.Keys){[void]$PresetBox.Items.Add($K)};foreach($K in $script:UserPresets.Keys){[void]$PresetBox.Items.Add($K)};$PresetBox.SelectedItem=$Selected;if(-not $PresetBox.SelectedItem){$PresetBox.Text=$Selected}}
function Save-Presets { [IO.File]::WriteAllText($PresetStore,($script:UserPresets|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false))) }
function Add-Log([string]$Line){
    if($Line){
        $LogBox.AppendText($Line+[Environment]::NewLine);$LogBox.ScrollToEnd()
        if($script:RunJournal){
            try{[IO.File]::AppendAllText($script:RunJournal,$Line+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))}catch{}
        }
    }
}
function Remove-ActiveWorkSafely {
    if ([string]::IsNullOrWhiteSpace($script:ActiveWork) -or -not (Test-Path -LiteralPath $script:ActiveWork -PathType Container)) { $script:ActiveWork=$null; return }
    try {
        $Resolved=[IO.Path]::GetFullPath($script:ActiveWork)
        $Parent=[IO.Directory]::GetParent($Resolved)
        $GrandParent=if($Parent){$Parent.Parent}else{$null}
        if ([IO.Path]::GetFileName($Resolved) -notlike 'job-*' -or -not $Parent -or $Parent.Name -ne 'temp' -or -not $GrandParent -or $GrandParent.Name -ne 'DLSS5VideoStudio') {
            Add-Log ('STOP_CLEANUP_SKIPPED: unsafe path '+$Resolved); return
        }
        Remove-Item -LiteralPath $Resolved -Recurse -Force
        Add-Log ('STOP_CLEANUP_OK: '+$Resolved)
    } catch { Add-Log ('STOP_CLEANUP_WARNING: '+$_.Exception.Message) }
    $script:ActiveWork=$null
}
function Acquire-PipelineLock {
    $Mutex = New-Object Threading.Mutex($false,'Local\DLSS5VideoStudioPipelineV2')
    $Held = $false
    try { $Held = $Mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $Held = $true }
    if (-not $Held) {
        $Mutex.Dispose()
        throw 'Обработка уже запущена в другом окне DLSS5 Video Studio.'
    }
    $ExistingHost = @(Get-Process -Name 'dlss5-video-host' -ErrorAction SilentlyContinue)
    if ($ExistingHost.Count -gt 0) {
        try { $Mutex.ReleaseMutex() } catch {}
        $Mutex.Dispose()
        throw "Уже работает другой DLSS5-конвейер (PID $($ExistingHost[0].Id)). Остановите его или дождитесь завершения."
    }
    $script:PipelineMutex = $Mutex
    $script:PipelineMutexHeld = $true
}
function Release-PipelineLock {
    if ($script:PipelineMutexHeld -and $script:PipelineMutex) {
        try { $script:PipelineMutex.ReleaseMutex() } catch {}
        $script:PipelineMutexHeld = $false
        $script:PipelineMutex.Dispose()
        $script:PipelineMutex = $null
    }
}
function Get-Ini { $S=Current-Settings; $Upscale=0; @"
[ADDON]
AddonPath=.
DisabledAddons=
LoadFromDllMain=renodx-dlss5.addon64

[GENERAL]
EffectSearchPaths=.\reshade-shaders\Shaders\**\**
NoDebugInfo=1
NoEffectCache=0
PerformanceMode=0
TextureSearchPaths=.\reshade-shaders\Textures\**\**

[INSTALL]
BasePath=.

[PROXY]
EnableProxyLibrary=0
ProxyLibrary=

[RenoDX.DLSS5]
EnableHooks=2
NeuralUplift=$(if($S.uplift){1}else{0})
NRAutoMask=$(if($S.automask){1}else{0})
NRColorStrength=$(F $S.color)
NRDepthMode=$($S.depth)
NREnableUpscaling=$Upscale
NRIntensity=$(F $S.intensity)
NRLocalStructure=$(F $S.structure)
NRLocalTone=$(F $S.tone)
NRMVecScaleX=$(F $S.motionx)
NRMVecScaleY=$(F $S.motiony)
NRPaperWhiteScale=$(F $S.paper)
NRPreset=$($S.preset)
NRSkinStructure=$(F $S.skin)
NRStyle=$($S.style)
NRTransferStrength=$(F $S.transfer)
NRUICorrection=$(if($S.ui){1}else{0})
"@ }
function Parse-UiRate([string]$Rate) {
    if ($Rate -match '^(?<a>[0-9.]+)\/(?<b>[0-9.]+)$' -and [double]$Matches.b -gt 0) { return [double]$Matches.a / [double]$Matches.b }
    $Value = 0.0
    if ([double]::TryParse($Rate,[Globalization.NumberStyles]::Float,$Invariant,[ref]$Value)) { return $Value }
    return 0.0
}
function Get-EstimatedGeometry {
    if (-not $script:SourceInfo -or -not $ModeCombo.SelectedItem) { return $null }
    $W = [int]$script:SourceInfo.width; $H = [int]$script:SourceInfo.height
    switch (Combo-Tag $ModeCombo) {
        '2160p' { $MW=3840; $MH=2160; $Allow=$true }
        '1440p' { $MW=2560; $MH=1440; $Allow=$true }
        '1080p' { $MW=1920; $MH=1080; $Allow=$true }
        '720p' { $MW=1280; $MH=720; $Allow=$true }
        '540p' { $MW=960; $MH=540; $Allow=$true }
        default { $MW=3840; $MH=2160; $Allow=$false }
    }
    $Scale=[math]::Min($MW/[double]$W,$MH/[double]$H); if(-not $Allow){$Scale=[math]::Min(1.0,$Scale)}
    return @([int](2*[math]::Max(1,[math]::Floor(($W*$Scale)/2))),[int](2*[math]::Max(1,[math]::Floor(($H*$Scale)/2))))
}
function Get-PipelineOrder {
    if ((Combo-Tag $UpscalerCombo) -eq 'None') { return 'DLSSOnly' }
    if ($script:StageOrder.Count -ge 2 -and $script:StageOrder[0] -eq 'DLSS5') { return 'DLSSThenVSR' }
    return 'VSRThenDLSS'
}
function Refresh-StageList {
    if (-not $StageList) { return }
    $HasVsr = (Combo-Tag $UpscalerCombo) -ne 'None'
    if (-not $HasVsr) {
        $script:StageOrder.Clear(); $script:StageOrder.Add('DLSS5')
    } elseif (-not $script:StageOrder.Contains('VSR')) {
        $script:StageOrder.Clear(); $script:StageOrder.Add('VSR'); $script:StageOrder.Add('DLSS5')
    }
    $StageList.Items.Clear()
    $Index = 1
    foreach ($Id in $script:StageOrder) {
        $Label = if ($Id -eq 'VSR') { "$Index. VSR x4 · $($UpscalerCombo.SelectedItem.Content)" } else { "$Index. DLSS5 Feature 18 · neural rendering" }
        $Item = New-Object Windows.Controls.ListBoxItem
        $Item.Content = $Label; $Item.Tag = $Id
        [void]$StageList.Items.Add($Item); $Index++
    }
    $StageUp.IsEnabled = $HasVsr -and (Combo-Tag $PerformanceCombo) -ne 'Realtime'
    $StageDown.IsEnabled = $StageUp.IsEnabled
    $Order = Get-PipelineOrder
    $StageOrderInfo.Text = if ($Order -eq 'DLSSThenVSR') { 'DLSS5 сначала восстанавливает четвертное разрешение, затем выбранная VSR-модель делает финальный x4. Живой preview для этого порядка отключён.' } elseif ($Order -eq 'DLSSOnly') { 'Активен один DLSS5-проход. VR-упаковка и кодек выполняются после него.' } else { 'VSR сначала восстанавливает x4, затем DLSS5 улучшает движение, структуру и детали. VR-упаковка и кодек выполняются последними.' }
    Update-Estimate
}
function Move-Stage([int]$Delta) {
    if ($StageList.SelectedIndex -lt 0 -or $script:StageOrder.Count -lt 2) { return }
    $From=$StageList.SelectedIndex; $To=$From+$Delta
    if($To -lt 0 -or $To -ge $script:StageOrder.Count){return}
    $Value=$script:StageOrder[$From]; $script:StageOrder.RemoveAt($From); $script:StageOrder.Insert($To,$Value)
    Refresh-StageList; $StageList.SelectedIndex=$To
    if ((Get-PipelineOrder) -eq 'DLSSThenVSR') { $LivePreviewCheck.IsChecked=$false; $LivePreviewCheck.IsEnabled=$false } elseif ((Combo-Tag $PerformanceCombo) -ne 'Realtime') { $LivePreviewCheck.IsEnabled=$true }
}
function Update-VrUi {
    if (-not $VrModeCombo.SelectedItem) { return }
    $VrMode=Combo-Tag $VrModeCombo
    $VrLayoutCombo.IsEnabled = $VrMode -in @('CinemaSBS','DepthSBS') -and (Combo-Tag $PerformanceCombo) -ne 'Realtime'
    $DepthStereo=$VrMode-eq'DepthSBS'
    foreach($Control in @($VREyeSlider,$VRConvergenceSlider,$VRDepthGammaSlider,$VROcclusionSlider,$VREdgeSlider,$VRTemporalSlider,$VREyeSwapCheck)){$Control.IsEnabled=$DepthStereo}
    switch($VrMode){
        'DepthSBS' { $VrInfo.Text='Настоящий стереорежим: Video Depth/DA3 создаёт устойчивую карту, CUDA формирует разные ракурсы. Доступны SBS и Over-Under, перестановка глаз, гамма depth, заполнение раскрытых краёв и отдельная временная стабилизация.' }
        'CinemaSBS' { $VrInfo.Text='Два одинаковых ракурса left/right для VR-кинотеатра. Это комфортный просмотр плоского видео, а не выдуманная стереоглубина. Full-SBS сохраняет полное разрешение каждого глаза.' }
        'Equirect360' { $VrInfo.Text='Для уже снятого/сшитого панорамного исходника 2:1. Программа проверит геометрию и добавит стандартные spherical-video v2 метаданные.' }
        default { $VrInfo.Text='Обычный плоский файл без VR-компоновки и пространственных метаданных.' }
    }
    Update-Estimate
}
function Update-Estimate {
    if (-not $script:SourceInfo -or -not $ModeCombo.SelectedItem -or -not $UpscalerCombo.SelectedItem) { return }
    $Geometry=Get-EstimatedGeometry; if(-not $Geometry){return}
    $Fps=[double]$script:SourceInfo.fps; if($Fps -le 0){$Fps=30}
    $Start=0.0; [void][double]::TryParse($StartBox.Text,[Globalization.NumberStyles]::Float,$Invariant,[ref]$Start)
    $Frames=8
    $Realtime=(Combo-Tag $PerformanceCombo)-eq'Realtime'
    if($Realtime -or $FullVideoCheck.IsChecked){$Frames=[int][math]::Max(1,[math]::Floor(([double]$script:SourceInfo.duration-$Start)*$Fps))}else{[void][int]::TryParse($FramesBox.Text,[ref]$Frames);$Frames=[math]::Max(1,$Frames)}
    $Pixels=($Geometry[0]*$Geometry[1])/[double](1920*1080)
    $Model=Combo-Tag $UpscalerCombo
    switch($Model){
        'NanoVSR' {$BaseFps=1.6;$Startup=4}
        'AnimeSR' {$BaseFps=1.25;$Startup=5}
        'FlashVSR' {$BaseFps=0.085;$Startup=18}
        'DLoRAL' {$BaseFps=0.17;$Startup=18}
        default {$BaseFps=11.0;$Startup=2}
    }
    $Effective=$BaseFps/[math]::Max(0.22,$Pixels)
    if((Combo-Tag $PerformanceCombo)-eq 'Quality'){$Effective*=0.78}elseif((Combo-Tag $PerformanceCombo)-eq 'Turbo'){$Effective*=2.5}elseif((Combo-Tag $PerformanceCombo)-eq 'Realtime'){$Effective*=2.8}
    $Seconds=$Startup+$Frames/[math]::Max(0.01,$Effective)
    if((Get-PipelineOrder)-eq 'DLSSThenVSR'){$Seconds*=1.12}
    if((Combo-Tag $VrModeCombo)-ne 'Off'){$Seconds*=1.18}
    $VrSuffix=if((Combo-Tag $VrModeCombo)-in @('CinemaSBS','DepthSBS')){
        switch(Combo-Tag $VrLayoutCombo){'FullSBS'{' · VR-контейнер: '+($Geometry[0]*2)+'×'+$Geometry[1]}'FullOU'{' · VR-контейнер: '+$Geometry[0]+'×'+($Geometry[1]*2)}default{''}}
    }else{''}
    $ExpectedTimeText.Text=if($Realtime){"Realtime: $($Geometry[0])×$($Geometry[1]) · стартовый буфер $([int]$RealtimeBufferSlider.Value) сек · воспроизведение до конца файла."}else{"Ожидаемый выход: $($Geometry[0])×$($Geometry[1])$VrSuffix · оценка: ~$(Format-Time $Seconds); после первых чанков ETA уточнится."}
}
function Update-InputInfo {
    if($InputBox.Text -match '^https?://'){
        $script:SourceInfo=$null
        $SourceResolutionText.Text='Сетевой источник: параметры будут прочитаны при запуске'
        $VideoInfo.Text='VK Video и другие сайты через встроенный resolver · выбранный поток можно перематывать.'
        $ExpectedTimeText.Text='Ссылка будет проверена при запуске. Её можно смотреть в realtime или сразу записывать в H.264/H.265.'
        return
    }
    if(-not(Test-Path -LiteralPath $InputBox.Text -PathType Leaf)){
        $script:SourceInfo=$null;$SourceResolutionText.Text='Исходник: файл ещё не выбран';$VideoInfo.Text='Выберите файл или вставьте ссылку VK Video';return
    }
    try{
        $P=(& $Ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate,r_frame_rate,codec_name,nb_frames,pix_fmt,color_transfer -show_entries format=duration,size -of json $InputBox.Text)|ConvertFrom-Json
        $V=$P.streams[0]; $Duration=[double]$P.format.duration; $Fps=Parse-UiRate $(if($V.avg_frame_rate -and $V.avg_frame_rate-ne'0/0'){$V.avg_frame_rate}else{$V.r_frame_rate})
        $Frames=if($V.nb_frames){[long]$V.nb_frames}else{[long][math]::Floor($Duration*$Fps)}
        $script:SourceInfo=[pscustomobject]@{width=[int]$V.width;height=[int]$V.height;fps=$Fps;duration=$Duration;frames=$Frames;codec=[string]$V.codec_name;size=[long]$P.format.size}
        $Dur=[TimeSpan]::FromSeconds($Duration); $MiB=[math]::Round(([long]$P.format.size/1MB),1)
        $SourceResolutionText.Text="Исходник: $($V.width) × $($V.height)"
        $VideoInfo.Text=('{0:0.###} FPS · {1} · {2} · {3:N0} кадров · {4:N1} MiB' -f $Fps,$V.codec_name,$Dur.ToString('hh\:mm\:ss\.fff'),$Frames,$MiB)
        if([string]::IsNullOrWhiteSpace($OutputBox.Text)){$OutputBox.Text=Join-Path $Root 'output'}
        Update-Estimate
    }catch{
        $script:SourceInfo=$null; $SourceResolutionText.Text='Исходник: параметры не прочитаны';$VideoInfo.Text='Не удалось прочитать параметры видео.';$ExpectedTimeText.Text='Оценка времени недоступна.'
    }
}

function Get-AutomaticOutputPath {
    $Directory = if ([string]::IsNullOrWhiteSpace($OutputBox.Text)) { Join-Path $Root 'output' } else { [IO.Path]::GetFullPath($OutputBox.Text) }
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    if($InputBox.Text -match '^https?://'){
        $Uri=[Uri]$InputBox.Text
        $Tail=($Uri.AbsolutePath.TrimEnd('/') -split '/')[-1]
        if([string]::IsNullOrWhiteSpace($Tail)){$Tail='online-video'}
        $Base=($Uri.DnsSafeHost+'_'+$Tail)
    }else{$Base=[IO.Path]::GetFileNameWithoutExtension($InputBox.Text)}
    $Base=[regex]::Replace($Base,'[^\p{L}\p{Nd}._-]+','_').Trim('_','.')
    if([string]::IsNullOrWhiteSpace($Base)){$Base='video'}
    if ($Base.Length -gt 80) { $Base = $Base.Substring(0,80).TrimEnd() }
    $Mode = [string]$ModeCombo.SelectedItem.Tag
    $Profile = [string]$PerformanceCombo.SelectedItem.Tag
    $CodecTag = [string]$CodecCombo.SelectedItem.Tag
    $UpscalerTag = [string]$UpscalerCombo.SelectedItem.Tag
    $Order = Get-PipelineOrder
    $PipelineTag = if ($Order -eq 'DLSSOnly') { 'DLSS5' } elseif ($Order -eq 'DLSSThenVSR') { 'DLSS5_' + $UpscalerTag } else { $UpscalerTag + '_DLSS5' }
    $VrTag = switch (Combo-Tag $VrModeCombo) { 'DepthSBS' { '_3D-VR' } 'CinemaSBS' { '_VR-SBS' } 'Equirect360' { '_VR360' } default { '' } }
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $Candidate = Join-Path $Directory ("{0}_{1}{2}_{3}_{4}_{5}_{6}.mp4" -f $Base,$PipelineTag,$VrTag,$Mode,$Profile,$CodecTag,$Stamp)
    if (Test-Path -LiteralPath $Candidate) {
        $Candidate = Join-Path $Directory ("{0}_{1}{2}_{3}_{4}_{5}_{6}_{7}.mp4" -f $Base,$PipelineTag,$VrTag,$Mode,$Profile,$CodecTag,$Stamp,[Guid]::NewGuid().ToString('N').Substring(0,6))
    }
    return $Candidate
}

function Update-UpscalerUi {
    if (-not $UpscalerCombo.SelectedItem) { return }
    $Model = [string]$UpscalerCombo.SelectedItem.Tag
    $Enabled = $Model -ne 'None'
    $UpscalerVariantCombo.IsEnabled = $Enabled
    $UpscalerStrengthSlider.IsEnabled = $Enabled
    switch ($Model) {
        'NanoVSR' { $UpscalerInfo.Text = 'Только быстрый preview: на высоком разрешении эффект слабый, на плохом низком разрешении возможна потеря деталей. Для финала используйте AnimeSR, FlashVSR или DLoRAL.' }
        'AnimeSR' { $UpscalerInfo.Text = 'AnimeSR v2: рекуррентное восстановление контуров, текстур и фона. Лучший выбор для дунхуа и аниме.' }
        'FlashVSR' { $UpscalerInfo.Text = 'FlashVSR v1.1 Tiny-Long: настоящий одношаговый diffusion + Sparse-Sage. Auto/Balanced экономят attention; Quality даёт больше стабильности. Первая загрузка и компиляция может занять 10–30 секунд.' }
        'DLoRAL' {
            if (Test-Path -LiteralPath $DLoRALCheckpoint -PathType Leaf) {
                $UpscalerInfo.Text = 'DLoRAL: Dual-LoRA теперь сливается в UNet один раз. Auto на 8 ГБ использует быстрый consistency-stage; Quality/Max оставляют полный detail-stage. Модель загружается около 10–20 секунд до первого кадра.'
            } else {
                $UpscalerInfo.Text = 'DLoRAL подготовлен, но официальный checkpoint временно недоступен из-за квоты Google Drive. Запустите INSTALL_MODELS.cmd позже.'
            }
        }
        default { $UpscalerInfo.Text = 'Внешний x4-проход отключён: работают DLSS5, карты движения и глубины.' }
    }
    Refresh-StageList
    Update-Estimate
}

function Update-ProfileUi {
    $Realtime = $PerformanceCombo.SelectedItem -and [string]$PerformanceCombo.SelectedItem.Tag -eq 'Realtime'
    if ($Realtime -and -not $script:WasRealtime) {
        $script:RecordPreviewChoice = [bool]$LivePreviewCheck.IsChecked
        $script:RecordModeTag=Combo-Tag $ModeCombo
        if((Combo-Tag $ModeCombo)-eq'Source'){Select-StringTag $ModeCombo '720p'}
    }
    if (-not $Realtime -and $script:WasRealtime) {
        $LivePreviewCheck.IsChecked = $script:RecordPreviewChoice
        if($script:RecordModeTag){Select-StringTag $ModeCombo $script:RecordModeTag}
    }
    $OutputBox.IsEnabled = -not $Realtime
    $BrowseOutput.IsEnabled = -not $Realtime
    $CodecCombo.IsEnabled = -not $Realtime
    $QualitySlider.IsEnabled = -not $Realtime
    $ComparisonCheck.IsEnabled = -not $Realtime
    $KeepTempCheck.IsEnabled = -not $Realtime
    $VrModeCombo.IsEnabled = -not $Realtime
    $RealtimePanel.IsEnabled = $Realtime
    $RealtimePanel.Opacity = if ($Realtime) { 1.0 } else { 0.48 }
    $RealtimeFullscreenCheck.IsEnabled = $Realtime
    $RealtimeBufferSlider.IsEnabled = $Realtime
    $RealtimeQualityCombo.IsEnabled = $Realtime
    $NetworkHeightCombo.IsEnabled = $Realtime
    $NetworkCookiesCombo.IsEnabled = $Realtime
    $RealtimeFpsCombo.IsEnabled=$Realtime;$RealtimeAudioCheck.IsEnabled=$Realtime;$RealtimeVolumeSlider.IsEnabled=$Realtime
    $FrameGenerationCombo.IsEnabled=$Realtime;$RenderPresetCombo.IsEnabled=$Realtime
    foreach($Control in @($GuideWidthSlider,$DepthIntervalSlider,$DepthMinIntervalSlider,$AdaptiveConfidenceSlider,$AdaptiveMotionSlider,$TemporalDepthSlider,$SceneCutSlider,$GuideMotionPresetCombo,$GuideMotionBackendCombo)){$Control.IsEnabled=$Realtime}
    $RaftUpdatesSlider.IsEnabled=$Realtime -and (Combo-Tag $GuideMotionBackendCombo)-eq'raft'
    $FullVideoCheck.IsEnabled = -not $Realtime
    $FramesBox.IsEnabled = (-not $Realtime) -and (-not [bool]$FullVideoCheck.IsChecked)
    if ($Realtime) {
        $VrModeCombo.SelectedIndex = 0
        if ((Combo-Tag $UpscalerCombo) -ne 'None' -and (Get-PipelineOrder) -eq 'DLSSThenVSR') {
            $script:StageOrder.Clear(); $script:StageOrder.Add('VSR'); $script:StageOrder.Add('DLSS5')
        }
        $LivePreviewCheck.IsChecked = $true
        $LivePreviewCheck.IsEnabled = $false
        $ComparisonCheck.IsChecked = $false
        $RunButton.Content = 'ЗАПУСТИТЬ ПРОСМОТР'
        $RuntimeStatus.Text = '● GPU-direct display · без записи'
        $ProgressHint.Text = 'Кадры DLSS выводятся прямо на экран; видеофайл не создаётся.'
        $RangeHint.Text = 'В realtime количество кадров не требуется: воспроизведение идёт от указанного старта до конца видео.'
    } else {
        $LivePreviewCheck.IsEnabled = (Get-PipelineOrder) -ne 'DLSSThenVSR'
        $RunButton.Content = 'ЗАПУСТИТЬ ЗАПИСЬ'
        $RuntimeStatus.Text = '● Persistent DLSS5 pipeline'
        $ProgressHint.Text = 'Имя готового видео будет сформировано автоматически.'
        $RangeHint.Text = 'Для быстрого подбора настроек начните с 8–24 кадров.'
    }
    $script:WasRealtime = $Realtime
    Refresh-StageList
    Update-VrUi
    Update-Estimate
}

function Update-RecordFineUi {
    $Enabled=[bool]$RecordFineGuideCheck.IsChecked
    $RecordFineGuideExpander.IsEnabled=$Enabled
    $RecordFineGuideExpander.Opacity=if($Enabled){1.0}else{0.48}
    if($Enabled){$RecordFineGuideExpander.IsExpanded=$true}
    $RecordRaftSlider.IsEnabled=$Enabled -and (Combo-Tag $RecordMotionBackendCombo)-eq'raft'
}

foreach($S in @($IntensitySlider,$ToneSlider,$StructureSlider,$SkinSlider,$MotionXSlider,$MotionYSlider,$TransferSlider,$ColorSlider,$PaperSlider,$QualitySlider,$UpscalerStrengthSlider,$VREyeSlider,$VRConvergenceSlider,$VRDepthGammaSlider,$VROcclusionSlider,$VREdgeSlider,$VRTemporalSlider,$RecordGuideWidthSlider,$RecordDepthIntervalSlider,$RecordDepthMinSlider,$RecordConfidenceSlider,$RecordMotionSlider,$RecordTemporalSlider,$RecordSceneSlider,$RecordRaftSlider,$RecordChunkSlider)){$S.Add_ValueChanged({Refresh-Labels})}
$RealtimeBufferSlider.Add_ValueChanged({Refresh-Labels;Update-Estimate})
$RealtimeChunkSlider.Add_ValueChanged({Refresh-Labels})
$RealtimeQualityCombo.Add_SelectionChanged({$Tag=Combo-Tag $RealtimeQualityCombo;if($Tag-ne'Custom'){Apply-RealtimeProfile $Tag}else{Update-RealtimeQualityInfo}})
foreach($S in @($GuideWidthSlider,$DepthIntervalSlider,$DepthMinIntervalSlider,$AdaptiveConfidenceSlider,$AdaptiveMotionSlider,$TemporalDepthSlider,$SceneCutSlider,$RaftUpdatesSlider)){$S.Add_ValueChanged({Mark-RealtimeCustom})}
$GuideMotionPresetCombo.Add_SelectionChanged({Mark-RealtimeCustom})
$GuideMotionBackendCombo.Add_SelectionChanged({Mark-RealtimeCustom})
$RealtimeFpsCombo.Add_SelectionChanged({Update-Estimate})
$FrameGenerationCombo.Add_SelectionChanged({Update-Estimate})
$DepthModelCombo.Add_SelectionChanged({Update-Estimate})
$RenderPresetCombo.Add_SelectionChanged({Update-Estimate})
$HardwareCombo.Add_SelectionChanged({Update-Estimate})
$ExpertCheck.Add_Click({Update-ExpertUi})
$WorkspaceTabs.Add_SelectionChanged({Update-WorkspaceUi})
$RecordFineGuideCheck.Add_Click({Update-RecordFineUi;Update-Estimate})
$RecordMotionBackendCombo.Add_SelectionChanged({Update-RecordFineUi})
$QuickScenarioCombo.Add_SelectionChanged({if($QuickScenarioCombo.SelectedItem){Apply-QuickScenario}})
$RealtimeVolumeSlider.Add_ValueChanged({Refresh-Labels})
$PresetBox.Add_SelectionChanged({$N=[string]$PresetBox.SelectedItem;if($BuiltIn.Contains($N)){Apply-Settings $BuiltIn[$N]}elseif($script:UserPresets.Contains($N)){Apply-Settings $script:UserPresets[$N]};Refresh-Labels})
$SavePreset.Add_Click({$N=$PresetBox.Text.Trim();if(-not$N){$N='Мой пресет '+(Get-Date -Format 'HHmmss')};if($BuiltIn.Contains($N)){[Windows.MessageBox]::Show('Введите другое имя: встроенный пресет не перезаписывается.','DLSS5 Video Studio')|Out-Null;return};$script:UserPresets[$N]=Current-Settings;Save-Presets;Refresh-Presets $N})
$DeletePreset.Add_Click({$N=$PresetBox.Text.Trim();if($script:UserPresets.Contains($N)){$script:UserPresets.Remove($N);Save-Presets;Refresh-Presets 'Balanced · рекомендовано'}})
$BrowseInput.Add_Click({$D=New-Object Microsoft.Win32.OpenFileDialog;$D.Filter='Video files|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.m4v;*.ts|All files|*.*';if($D.ShowDialog($Window)){$InputBox.Text=$D.FileName;Update-InputInfo}})
$PasteInput.Add_Click({try{$Text=[Windows.Clipboard]::GetText().Trim();if($Text){$InputBox.Text=$Text;Update-InputInfo}}catch{[Windows.MessageBox]::Show('Не удалось прочитать буфер обмена.','DLSS5 Video Studio')|Out-Null}})
$BrowseOutput.Add_Click({$D=New-Object System.Windows.Forms.FolderBrowserDialog;$D.Description='Выберите папку для автоматически названных записей';if(Test-Path -LiteralPath $OutputBox.Text -PathType Container){$D.SelectedPath=$OutputBox.Text};if($D.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$OutputBox.Text=$D.SelectedPath};$D.Dispose()})
$InputBox.Add_LostFocus({Update-InputInfo})
$PerformanceCombo.Add_SelectionChanged({Update-ProfileUi})
$UpscalerCombo.Add_SelectionChanged({Update-UpscalerUi})
$ModeCombo.Add_SelectionChanged({Update-Estimate})
$CodecCombo.Add_SelectionChanged({Update-Estimate})
$UpscalerVariantCombo.Add_SelectionChanged({Update-Estimate})
$VrModeCombo.Add_SelectionChanged({Update-VrUi})
$VrLayoutCombo.Add_SelectionChanged({Update-Estimate})
$VREyeSwapCheck.Add_Click({Update-Estimate})
$StageUp.Add_Click({Move-Stage -1})
$StageDown.Add_Click({Move-Stage 1})
$FullVideoCheck.Add_Checked({$FramesBox.IsEnabled=$false;Update-Estimate})
$FullVideoCheck.Add_Unchecked({$FramesBox.IsEnabled=((Combo-Tag $PerformanceCombo) -ne 'Realtime');Update-Estimate})
$FramesBox.Add_LostFocus({Update-Estimate})
$StartBox.Add_LostFocus({Update-Estimate})

function Finalize-Run {
    if ($script:Finalized) { return }
    $script:Finalized = $true
    if ($script:EphemeralConfig -and (Test-Path -LiteralPath $script:EphemeralConfig)) {
        Remove-Item -LiteralPath $script:EphemeralConfig -Force
        $script:EphemeralConfig = $null
    }
    if ($script:EphemeralControl -and (Test-Path -LiteralPath $script:EphemeralControl)) {
        Remove-Item -LiteralPath $script:EphemeralControl -Force
    }
    if ($script:EphemeralControl) {
        $HeaderFile=$script:EphemeralControl+'.headers.json'
        if(Test-Path -LiteralPath $HeaderFile){Remove-Item -LiteralPath $HeaderFile -Force}
        $script:EphemeralControl = $null
    }
    Release-PipelineLock
    $RunButton.IsEnabled = $true
    $CancelButton.IsEnabled = $false
    $Progress.IsIndeterminate = $false
    if ($script:Cancelled) {
        Remove-ActiveWorkSafely
        $StatusText.Text = 'Остановлено пользователем'
        $DetailText.Text = 'Все связанные процессы завершены. Незаконченный файл не помечен как готовый.'
        $SpeedText.Text = 'STOP'
        $EtaText.Text = 'Осталось: —'
        $ProgressHint.Text = 'Можно сразу изменить настройки и запустить новый тест.'
        $OpenVideo.IsEnabled = $false
        $OpenFolder.IsEnabled = $false
        $PlayButton.IsEnabled = $false
    } elseif ($script:Process.ExitCode -eq 0 -and $script:Result) {
        $StatusText.Text = if ($script:Result.recording) { 'Запись готова' } else { 'Просмотр завершён' }
        $ModeText = if ($script:Result.recording) { [string]$script:Result.codec } else { 'без записи' }
        $ShownGeometry = if ($script:Result.container_geometry) { $script:Result.container_geometry } else { $script:Result.output_geometry }
        $DetailText.Text = "$($script:Result.frames) кадров · $($ShownGeometry[0])×$($ShownGeometry[1]) · $ModeText · $($script:Result.pipeline_label)"
        $ShownFps = if ($script:Result.recording) { [double]$script:Result.end_to_end_fps } else { [double]$script:Result.display_fps }
        $VsrFps = [double]$script:Result.upscaler_fps
        $SpeedText.Text = if ($VsrFps -gt 0) { ('{0:0.00} FPS · VSR {1:0.00} · DLSS {2:0.00}' -f $ShownFps,$VsrFps,[double]$script:Result.dlss5_fps) } else { ('{0:0.00} FPS · DLSS {1:0.00}' -f $ShownFps,[double]$script:Result.dlss5_fps) }
        $Progress.Value = 100
        $EtaText.Text = 'Осталось: 00:00'
        if ($script:Result.recording) {
            $script:LastOutputVideo = [string]$script:Result.output_video
            $OpenVideo.IsEnabled = $true
            $OpenFolder.IsEnabled = $true
            $PlayButton.IsEnabled = $true
            $Preview.Source = [Uri]$script:Result.output_video
            $Placeholder.Visibility = 'Collapsed'
            $Preview.Position = [TimeSpan]::Zero
            $Preview.Play()
            $script:IsPlaying = $true
            $StartText = if ($script:Result.first_host_chunk_seconds) { (' · первый пакет {0:0.00} с' -f [double]$script:Result.first_host_chunk_seconds) } else { '' }
            $ProgressHint.Text = 'Готовое видео автоматически названо; настройки, summary и логи сохранены рядом' + $StartText + '.'
        } else {
            $OpenVideo.IsEnabled = $false
            $OpenFolder.IsEnabled = $false
            $PlayButton.IsEnabled = $false
            $ProgressHint.Text = 'GPU-direct просмотр завершён. Видеофайл не создавался.'
        }
    } else {
        $StatusText.Text = 'Ошибка обработки'
        $DetailText.Text = if ($script:LastError) { $script:LastError } else { 'Откройте вкладку «Журнал» для подробностей.' }
        $SpeedText.Text = 'ERROR'
        $EtaText.Text = 'Осталось: —'
        $Progress.Value = 0
        $OpenVideo.IsEnabled = $false
        $OpenFolder.IsEnabled = $false
        $PlayButton.IsEnabled = $false
        $ProgressHint.Text = 'Обработка не завершена. Причина показана выше и в журнале.'
    }
    $script:Process = $null
    $script:RunStartedAt = $null
    $script:LastEtaSeconds = $null
    $script:RunJournal = $null
}

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$Timer.Add_Tick({
    try {
        if ($script:Process -and $script:RunStartedAt) {
            $ElapsedText.Text = 'Прошло: ' + (Format-Time (((Get-Date)-$script:RunStartedAt).TotalSeconds))
            if ($null -ne $script:LastEtaSeconds -and $script:LastProgressAt) {
                $Remaining=[math]::Max(0,[double]$script:LastEtaSeconds-((Get-Date)-$script:LastProgressAt).TotalSeconds)
                $EtaText.Text='Осталось: '+(Format-Time $Remaining)
            }
        }
        while ($script:Stdout -and $script:Stdout.IsCompleted) {
            $V = $script:Stdout.Result
            if ($null -eq $V) { $script:Stdout = $null; break }
            $script:Queue.Enqueue($V)
            $script:Stdout = $script:Process.StandardOutput.ReadLineAsync()
        }
        while ($script:Stderr -and $script:Stderr.IsCompleted) {
            $V = $script:Stderr.Result
            if ($null -eq $V) { $script:Stderr = $null; break }
            $script:Queue.Enqueue('ERROR: ' + $V)
            $script:Stderr = $script:Process.StandardError.ReadLineAsync()
        }
        $L = $null
        while ($script:Queue.TryDequeue([ref]$L)) {
            Add-Log $L
            if ($L -match '^STUDIO_STAGE (?<a>\d+)/(?<b>\d+) (?<m>.+)$') {
                $StatusText.Text = $Matches.m
            } elseif ($L -match '^STUDIO_WORK (?<p>.+)$') {
                $script:ActiveWork=$Matches.p
            } elseif ($L -match '^STUDIO_SOURCE_RESOLVING (?<m>.+)$') {
                $StatusText.Text='Открытие сетевого видео…';$DetailText.Text='Проверка ссылки и выбор прямого потока…';$Progress.IsIndeterminate=$true
            } elseif ($L -match '^STUDIO_SOURCE_JSON (?<j>.+)$') {
                try {
                    $Source=$Matches.j|ConvertFrom-Json
                    $HeightText=if([int]$Source.height-gt 0){"$($Source.height)p"}else{'авто'}
                    $SourceResolutionText.Text="Сетевой источник: $HeightText · $($Source.format_id)"
                    $VideoInfo.Text="$($Source.title) · $(Format-Time ([double]$Source.duration_seconds))"
                    $StatusText.Text='Ссылка открыта'
                    $DetailText.Text="Прямой поток $HeightText подготовлен · можно перематывать"
                } catch { Add-Log ('Source JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PLAYER_READY (?<j>.+)$') {
                try {
                    $Player=$Matches.j|ConvertFrom-Json
                    $StatusText.Text='Realtime-плеер готов'
                    $DetailText.Text="Буфер $($Player.buffer_seconds) сек · Space пауза · F11 весь экран · стрелки перемотка"
                } catch { Add-Log ('Player JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PLAYER_SESSION (?<j>.+)$') {
                try {
                    $Session=$Matches.j|ConvertFrom-Json
                    $StatusText.Text='Подготовка буфера…'
                    $DetailText.Text=('Позиция {0} · формируются кадры motion/depth и DLSS5' -f (Format-Time ([double]$Session.start_seconds)))
                } catch { Add-Log ('Player session JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PLAYER_PLAYING (?<j>.+)$') {
                try {
                    $Playing=$Matches.j|ConvertFrom-Json
                    $StatusText.Text='Realtime-воспроизведение'
                    $SoundText=if([bool]$Playing.audio){'звук синхронизирован'}else{'без звука'}
                    $DetailText.Text=('Позиция {0} · {1} · Space пауза · F11 весь экран' -f (Format-Time ([double]$Playing.position_seconds)),$SoundText)
                } catch { Add-Log ('Player playing JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PLAYER_SEEK (?<s>[0-9.]+)$') {
                $StatusText.Text='Перемотка и повторная буферизация…'
                $DetailText.Text=('Новая позиция: '+(Format-Time ([double]::Parse($Matches.s,$Invariant))))
                $Progress.IsIndeterminate=$true
                $script:Result=$null
            } elseif ($L -eq 'STUDIO_PLAYER_CLOSED') {
                $script:Cancelled=$true
            } elseif ($L -match '^STUDIO_PLAN (?<j>.+)$') {
                try {
                    $Plan=$Matches.j|ConvertFrom-Json
                    $DetailText.Text="$($Plan.total_frames) кадров · $([math]::Round([double]$Plan.source_fps,2)) → $([math]::Round([double]$Plan.fps,2)) FPS · $($Plan.source_geometry[0])×$($Plan.source_geometry[1]) → $($Plan.output_geometry[0])×$($Plan.output_geometry[1]) · $($Plan.pipeline_label)"
                } catch { Add-Log ('Plan JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PROGRESS_JSON (?<j>.+)$') {
                try {
                    $P=$Matches.j|ConvertFrom-Json
                    $Progress.IsIndeterminate=$false; $Progress.Maximum=100; $Progress.Value=[double]$P.percent
                    $StatusText.Text=[string]$P.message
                    $DetailText.Text="$($P.phase) · $($P.processed_frames) из $($P.total_frames) кадров · $([math]::Round([double]$P.percent,1))%"
                    if([double]$P.phase_fps-gt 0){$SpeedText.Text=('{0:0.00} FPS' -f [double]$P.phase_fps)}
                    if($null-ne$P.eta_seconds){$script:LastEtaSeconds=[double]$P.eta_seconds;$script:LastProgressAt=Get-Date;$EtaText.Text='Осталось: '+(Format-Time $script:LastEtaSeconds)}
                }catch{Add-Log ('Progress JSON: '+$_.Exception.Message)}
            } elseif ($L -match '^STUDIO_PROGRESS (?<a>\d+)/(?<b>\d+)$') {
                $Progress.IsIndeterminate = $false
                $Progress.Maximum = [double]$Matches.b
                $Progress.Value = [double]$Matches.a
                $DetailText.Text = "Обработано $($Matches.a) из $($Matches.b) кадров"
            } elseif ($L -match '^UPSCALER_STATUS (?<j>.+)$') {
                try {
                    $U=$Matches.j|ConvertFrom-Json
                    $StatusText.Text=[string]$U.message
                    if($U.stage-eq'model'){$DetailText.Text="Загрузка тяжёлой модели в VRAM · отмена доступна в любой момент"}
                    elseif($U.stage-eq'ready'){$DetailText.Text="Модель готова · $($U.resolved_variant) · VRAM $($U.allocated_vram_mb) MiB"}
                    elseif($U.stage-eq'chunk'){$DetailText.Text="$($U.frames) кадров в текущей порции · модель уже находится в GPU"}
                }catch{Add-Log ('Upscaler status JSON: '+$_.Exception.Message)}
            } elseif ($L -match '^STUDIO_RESULT (?<j>.+)$') {
                try { $script:Result = $Matches.j | ConvertFrom-Json } catch { Add-Log ('Result JSON: ' + $_.Exception.Message) }
            } elseif ($L -match '^STUDIO_ERROR (?<m>.+)$') {
                $script:LastError = $Matches.m
            } elseif ($L -match '^GUIDE_FRAME (?<a>\d+)/(?<b>\d+)') {
                $DetailText.Text = "Автоматические карты: кадр $($Matches.a) из $($Matches.b)"
            }
            $L = $null
        }
        if ($script:Process -and $script:Process.HasExited -and -not $script:Stdout -and -not $script:Stderr -and $script:Queue.IsEmpty) {
            Finalize-Run
        }
    } catch {
        Add-Log ('Monitor: ' + $_.Exception.Message)
    }
})
$Timer.Start()

$RunButton.Add_Click({
    $Config = $null
    try {
        if ($script:Process) { throw 'Обработка уже выполняется.' }
        $WorkspaceMode=Get-WorkspaceMode
        $Realtime = $WorkspaceMode -eq 'Realtime'
        $IsOnlineSource = $InputBox.Text -match '^https?://'
        if ([string]::IsNullOrWhiteSpace($InputBox.Text)) { throw 'Выберите видеофайл или вставьте ссылку.' }
        if (-not $IsOnlineSource -and -not (Test-Path -LiteralPath $InputBox.Text -PathType Leaf)) { throw 'Выберите существующий входной видеофайл.' }
        if ([string]$UpscalerCombo.SelectedItem.Tag -eq 'DLoRAL' -and -not (Test-Path -LiteralPath $DLoRALCheckpoint -PathType Leaf)) {
            throw 'DLoRAL checkpoint ещё не скачан: Google Drive превысил квоту. Запустите INSTALL_MODELS.cmd позже; NanoVSR, AnimeSR v2 и FlashVSR уже готовы.'
        }
        $Start = 0.0
        if (-not [double]::TryParse($StartBox.Text,[Globalization.NumberStyles]::Float,$Invariant,[ref]$Start) -or $Start -lt 0) { throw 'Некорректное время старта.' }
        $Frames = 0
        if (-not $Realtime -and -not $FullVideoCheck.IsChecked) {
            if (-not [int]::TryParse($FramesBox.Text,[ref]$Frames) -or $Frames -lt 1) { throw 'Количество кадров должно быть не меньше 1.' }
        }
        $PipelineOrder = Get-PipelineOrder
        if ($Realtime -and $PipelineOrder -eq 'DLSSThenVSR') { throw 'Для живого вывода VSR должна идти перед DLSS5.' }
        if ($Realtime -and -not (Test-Path -LiteralPath $RealtimeRunner -PathType Leaf)) { throw 'Файл realtime-плеера отсутствует. Переустановите portable-версию.' }
        Acquire-PipelineLock
        if ($Realtime) {
            $RealtimeConfigDirectory = Join-Path $Root 'temp'
            New-Item -ItemType Directory -Force -Path $RealtimeConfigDirectory | Out-Null
            $Config = Join-Path $RealtimeConfigDirectory ('realtime-' + [Guid]::NewGuid().ToString('N') + '.ReShade.ini')
            $ControlDirectory = Join-Path $env:ProgramData 'DLSS5VideoStudio\control'
            New-Item -ItemType Directory -Force -Path $ControlDirectory | Out-Null
            $Control = Join-Path $ControlDirectory ('player-' + [Guid]::NewGuid().ToString('N') + '.txt')
            $Output = $null
            $script:EphemeralConfig = $Config
            $script:EphemeralControl = $Control
        } else {
            $Output = Get-AutomaticOutputPath
            $Config = [IO.Path]::ChangeExtension($Output,'.ReShade.ini')
            $script:EphemeralConfig = $null
        }
        $script:RunJournal = if($Realtime){[IO.Path]::ChangeExtension($Config,'.studio.log')}else{[IO.Path]::ChangeExtension($Output,'.studio.log')}
        if(Test-Path -LiteralPath $script:RunJournal){Remove-Item -LiteralPath $script:RunJournal -Force}
        [IO.File]::WriteAllText($Config,(Get-Ini),(New-Object Text.UTF8Encoding($false)))
        if ($Realtime) {
            $Args = @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$RealtimeRunner+'"'),
                '-Runner',('"'+$Runner+'"'),'-InputVideo',('"'+$InputBox.Text+'"'),
                '-ConfigPath',('"'+$Config+'"'),'-ControlPath',('"'+$Control+'"'),
                '-OutputMode',([string]$ModeCombo.SelectedItem.Tag),
                '-HardwareProfile',(Combo-Tag $HardwareCombo),'-RenderPreset',(Combo-Tag $RenderPresetCombo),
                '-DepthModelProfile',(Combo-Tag $DepthModelCombo),
                '-Upscaler',([string]$UpscalerCombo.SelectedItem.Tag),
                '-UpscalerVariant',([string]$UpscalerVariantCombo.SelectedItem.Tag),
                '-UpscalerStrength',([string]::Format($Invariant,'{0:0.###}',[double]$UpscalerStrengthSlider.Value)),
                '-PipelineOrder',$PipelineOrder,
                '-BufferSeconds',[int]$RealtimeBufferSlider.Value,
                '-ChunkFrames',[int]$RealtimeChunkSlider.Value,
                '-StartSeconds',([string]::Format($Invariant,'{0:0.######}',$Start)),
                '-NetworkMaxHeight',[int](Combo-Tag $NetworkHeightCombo),
                '-CookiesBrowser',(Combo-Tag $NetworkCookiesCombo),
                '-GuideWidth',[int]$GuideWidthSlider.Value,
                '-DepthInterval',[int]$DepthIntervalSlider.Value,
                '-DepthMinInterval',[math]::Min([int]$DepthMinIntervalSlider.Value,[int]$DepthIntervalSlider.Value),
                '-AdaptiveConfidence',([string]::Format($Invariant,'{0:0.###}',[double]$AdaptiveConfidenceSlider.Value)),
                '-AdaptiveMotion',([string]::Format($Invariant,'{0:0.###}',[double]$AdaptiveMotionSlider.Value)),
                '-TemporalDepth',([string]::Format($Invariant,'{0:0.###}',[double]$TemporalDepthSlider.Value)),
                '-SceneCutThreshold',([string]::Format($Invariant,'{0:0.###}',[double]$SceneCutSlider.Value)),
                '-MotionPreset',(Combo-Tag $GuideMotionPresetCombo),
                '-MotionBackend',(Combo-Tag $GuideMotionBackendCombo),
                '-RaftUpdates',[int]$RaftUpdatesSlider.Value,
                '-FpsMode',(Combo-Tag $RealtimeFpsCombo),'-FrameGeneration',(Combo-Tag $FrameGenerationCombo),
                '-Volume',[int]$RealtimeVolumeSlider.Value
            )
            if ($RealtimeFullscreenCheck.IsChecked) { $Args += '-Fullscreen' }
            if ($RealtimeAudioCheck.IsChecked) { $Args += '-EnableAudio' }
        } else {
            $Args = @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Runner+'"'),
                '-InputVideo',('"'+$InputBox.Text+'"'),'-ConfigPath',('"'+$Config+'"'),
                '-Codec',([string]$CodecCombo.SelectedItem.Tag),'-Quality',[int]$QualitySlider.Value,
                '-OutputMode',([string]$ModeCombo.SelectedItem.Tag),
                '-PerformanceProfile',([string]$PerformanceCombo.SelectedItem.Tag),
                '-HardwareProfile',(Combo-Tag $HardwareCombo),'-DepthModelProfile',(Combo-Tag $DepthModelCombo),
                '-Upscaler',([string]$UpscalerCombo.SelectedItem.Tag),
                '-UpscalerVariant',([string]$UpscalerVariantCombo.SelectedItem.Tag),
                '-UpscalerStrength',([string]::Format($Invariant,'{0:0.###}',[double]$UpscalerStrengthSlider.Value)),
                '-PipelineOrder',$PipelineOrder,
                '-VRMode',(Combo-Tag $VrModeCombo),'-VRSbsLayout',(Combo-Tag $VrLayoutCombo),
                '-VREyeSeparation',([string]::Format($Invariant,'{0:0.###}',[double]$VREyeSlider.Value)),
                '-VRConvergence',([string]::Format($Invariant,'{0:0.###}',[double]$VRConvergenceSlider.Value)),
                '-VRDepthGamma',([string]::Format($Invariant,'{0:0.###}',[double]$VRDepthGammaSlider.Value)),
                '-VROcclusionFill',([string]::Format($Invariant,'{0:0.###}',[double]$VROcclusionSlider.Value)),
                '-VREdgeFeather',([string]::Format($Invariant,'{0:0.###}',[double]$VREdgeSlider.Value)),
                '-VRTemporalSmoothing',([string]::Format($Invariant,'{0:0.###}',[double]$VRTemporalSlider.Value)),
                '-NetworkMaxHeight',[int](Combo-Tag $RecordNetworkHeightCombo),
                '-NetworkCookiesBrowser',(Combo-Tag $RecordNetworkCookiesCombo),
                '-StartSeconds',([string]::Format($Invariant,'{0:0.######}',$Start)),'-FrameCount',$Frames,
                '-OutputVideo',('"'+$Output+'"')
            )
            if ($RecordFineGuideCheck.IsChecked) {
                $Args += @(
                    '-FineGuideSettings','-GuideWidthOverride',[int]$RecordGuideWidthSlider.Value,
                    '-DepthIntervalOverride',[int]$RecordDepthIntervalSlider.Value,
                    '-DepthMinIntervalOverride',[math]::Min([int]$RecordDepthMinSlider.Value,[int]$RecordDepthIntervalSlider.Value),
                    '-AdaptiveConfidenceOverride',([string]::Format($Invariant,'{0:0.###}',[double]$RecordConfidenceSlider.Value)),
                    '-AdaptiveMotionOverride',([string]::Format($Invariant,'{0:0.###}',[double]$RecordMotionSlider.Value)),
                    '-TemporalDepthOverride',([string]::Format($Invariant,'{0:0.###}',[double]$RecordTemporalSlider.Value)),
                    '-SceneCutThresholdOverride',([string]::Format($Invariant,'{0:0.###}',[double]$RecordSceneSlider.Value)),
                    '-MotionPresetOverride',(Combo-Tag $RecordMotionPresetCombo),'-MotionBackendOverride',(Combo-Tag $RecordMotionBackendCombo),
                    '-RaftUpdatesOverride',[int]$RecordRaftSlider.Value,'-ChunkFramesOverride',[int]$RecordChunkSlider.Value
                )
            }
            if ($VREyeSwapCheck.IsChecked) { $Args += '-VREyeSwap' }
            if ($LivePreviewCheck.IsChecked) { $Args += '-LivePreview' }
            if ($ComparisonCheck.IsChecked) { $Args += '-CreateComparison' }
            if ($KeepTempCheck.IsChecked) { $Args += '-KeepTemporaryFiles' }
        }
        $Psi = New-Object Diagnostics.ProcessStartInfo
        $Psi.FileName = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $Psi.Arguments = $Args -join ' '
        $Psi.WorkingDirectory = $Root
        $Psi.UseShellExecute = $false
        $Psi.RedirectStandardOutput = $true
        $Psi.RedirectStandardError = $true
        $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $Psi.CreateNoWindow = $true
        $P = New-Object Diagnostics.Process
        $P.StartInfo = $Psi
        if (-not $P.Start()) { throw 'Не удалось запустить обработку.' }
        $script:Process = $P
        $script:Stdout = $P.StandardOutput.ReadLineAsync()
        $script:Stderr = $P.StandardError.ReadLineAsync()
        $script:Result = $null
        $script:LastError = $null
        $script:LastOutputVideo = $null
        $script:Finalized = $false
        $script:Cancelled = $false
        $script:RunStartedAt = Get-Date
        $script:LastProgressAt = $null
        $script:LastEtaSeconds = $null
        $script:ActiveWork = $null
        $LogBox.Clear()
        Add-Log ('DLSS5 Video Studio · ' + (Get-Date).ToString('s'))
        Add-Log ('Очередность: ' + $PipelineOrder + ' · VR: ' + (Combo-Tag $VrModeCombo))
        if ($Realtime) { Add-Log ('Realtime: '+(Combo-Tag $RealtimeQualityCombo)+' · '+(Combo-Tag $GuideMotionBackendCombo)+' · '+(Combo-Tag $RealtimeFpsCombo)+' · guide '+[int]$GuideWidthSlider.Value+' · depth 1/'+[int]$DepthIntervalSlider.Value+' · буфер '+[int]$RealtimeBufferSlider.Value+' сек · fullscreen '+[bool]$RealtimeFullscreenCheck.IsChecked+' · без лимита кадров') }
        if (-not $Realtime) { Add-Log ('Автоматическое имя: ' + $Output) }
        $StatusText.Text = if ($Realtime) { 'Запуск живого вывода…' } else { 'Подготовка записи…' }
        $DetailText.Text = if ($Realtime) { "До конца видео · буфер $([int]$RealtimeBufferSlider.Value) сек · $($PerformanceCombo.SelectedItem.Content)" } elseif ($Frames) { "$Frames кадров · $($PerformanceCombo.SelectedItem.Content)" } else { "Полное видео · $($PerformanceCombo.SelectedItem.Content)" }
        $SpeedText.Text = '… FPS'
        $EtaText.Text = 'Осталось: уточняется…'
        $ElapsedText.Text = 'Прошло: 00:00'
        $Progress.Value = 0
        $Progress.IsIndeterminate = $true
        $ProgressHint.Text = if ($Realtime) {
            'Прямой вывод GPU без NVENC и создания файла.'
        } elseif ((Combo-Tag $UpscalerCombo) -eq 'None') {
            'Быстрый DLSS-only: NGX прогревается параллельно с первым motion/depth-пакетом; внешний x4-апскейл отключён.'
        } else {
            'FlashVSR/DLoRAL сначала 10–30 секунд загружают веса; затем модель остаётся в GPU на весь ролик.'
        }
        $RunButton.IsEnabled = $false
        $CancelButton.IsEnabled = $true
        $OpenVideo.IsEnabled = $false
        $OpenFolder.IsEnabled = $false
        $PlayButton.IsEnabled = $false
        $Preview.Stop()
        $Placeholder.Visibility = 'Visible'
    } catch {
        if (-not $script:Process) {
            if ($Config -and (Test-Path -LiteralPath $Config)) { Remove-Item -LiteralPath $Config -Force }
            if ($script:EphemeralControl -and (Test-Path -LiteralPath $script:EphemeralControl)) { Remove-Item -LiteralPath $script:EphemeralControl -Force; $script:EphemeralControl=$null }
            Release-PipelineLock
            $script:RunJournal = $null
        }
        [Windows.MessageBox]::Show($_.Exception.Message,'DLSS5 Video Studio','OK','Error') | Out-Null
    }
})
function Stop-ActiveRun {
    if ($script:Process -and -not $script:Process.HasExited) {
        $script:Cancelled=$true
        $CancelButton.IsEnabled=$false
        $StatusText.Text='Немедленная остановка…'
        $DetailText.Text='Завершаются runner, FFmpeg, VSR, guidegen и DLSS5 host.'
        $EtaText.Text='Осталось: —'
        Add-Log 'STOP_REQUEST: пользователь запросил немедленную остановку всего дерева процессов.'
        try { & taskkill.exe /PID $script:Process.Id /T /F 2>$null | Out-Null } catch { Add-Log ('STOP: '+$_.Exception.Message) }
    }
}
$CancelButton.Add_Click({Stop-ActiveRun})
$PlayButton.Add_Click({if($script:IsPlaying){$Preview.Pause();$script:IsPlaying=$false}else{$Preview.Play();$script:IsPlaying=$true}})
$OpenVideo.Add_Click({if($script:LastOutputVideo -and (Test-Path -LiteralPath $script:LastOutputVideo)){Start-Process -FilePath $script:LastOutputVideo}})
$OpenFolder.Add_Click({if($script:LastOutputVideo -and (Test-Path -LiteralPath $script:LastOutputVideo)){Start-Process explorer.exe -ArgumentList "/select,`"$($script:LastOutputVideo)`""}})
$Preview.Add_MediaEnded({$Preview.Position=[TimeSpan]::Zero;$Preview.Play()})
$Window.Add_PreviewKeyDown({param($S,$E);if($E.Key -eq [Windows.Input.Key]::Escape -and $script:Process -and -not $script:Process.HasExited){Stop-ActiveRun;$E.Handled=$true}})
$Window.Add_Closing({param($S,$E);if($script:Process-and-not$script:Process.HasExited){$A=[Windows.MessageBox]::Show('Обработка выполняется. Остановить её и закрыть окно?','DLSS5 Video Studio','YesNo','Warning');if($A-ne'Yes'){$E.Cancel=$true;return};Stop-ActiveRun}})

$WorkspaceTabs.SelectedIndex=0;$ModeCombo.SelectedIndex=0;$CodecCombo.SelectedIndex=0;$PerformanceCombo.SelectedIndex=2;$VrModeCombo.SelectedIndex=0;$VrLayoutCombo.SelectedIndex=0;$HardwareCombo.SelectedIndex=0;$RenderPresetCombo.SelectedIndex=0;$DepthModelCombo.SelectedIndex=0;$FrameGenerationCombo.SelectedIndex=0;$QuickScenarioCombo.SelectedIndex=0;$UpscalerCombo.SelectedIndex=0;$UpscalerVariantCombo.SelectedIndex=0;$UpscalerStrengthSlider.Value=1.0;$NrPresetCombo.SelectedIndex=1;$StyleCombo.SelectedIndex=1;$DepthCombo.SelectedIndex=0;$QualitySlider.Value=18;$GuideMotionPresetCombo.SelectedIndex=0;$GuideMotionBackendCombo.SelectedIndex=0;$RecordMotionPresetCombo.SelectedIndex=1;$RecordMotionBackendCombo.SelectedIndex=0;$RealtimeFpsCombo.SelectedIndex=1;$NetworkHeightCombo.SelectedIndex=1;$NetworkCookiesCombo.SelectedIndex=0;$RecordNetworkHeightCombo.SelectedIndex=3;$RecordNetworkCookiesCombo.SelectedIndex=0;$RealtimeQualityCombo.SelectedIndex=1;$OutputBox.Text=Join-Path $Root 'output';Load-Presets;Apply-Settings $BuiltIn['Balanced · рекомендовано'];Apply-RealtimeProfile 'Balanced';Apply-QuickScenario;Refresh-Labels;Update-RealtimeQualityInfo;Update-RecordFineUi;Update-UpscalerUi;Update-WorkspaceUi;Update-VrUi;Update-ExpertUi;Refresh-StageList
$Window.ShowDialog() | Out-Null
