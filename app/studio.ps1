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
$M2SVidCheckpoint = Join-Path $Root 'models\vr\m2svid\m2svid_weights.pt'
$M2SVidOpenClip = Join-Path $Root 'models\vr\m2svid\open_clip_pytorch_model.bin'
$M2SVidInstallStatus = Join-Path $Root 'models\vr\m2svid\install.json'
$M2SVidCode = Join-Path $Root 'third_party\m2svid\m2svid\models_for_sgm\m2svid_model.py'
$MoebiusCheckpoint = Join-Path $Root 'models\vr\moebius\ft_places2\diffusion_pytorch_model.bin'
$MoebiusVae = Join-Path $Root 'models\vr\moebius\vae\diffusion_pytorch_model.bin'
$MoebiusInstallStatus = Join-Path $Root 'models\vr\moebius\install.json'
$MoebiusCode = Join-Path $Root 'third_party\moebius\removal\v1_2\pipeline.py'
$MoebiusDiffusers = Join-Path $Root 'models\vr\moebius\site-packages\diffusers\__init__.py'
$TemporalAtlasWorker = Join-Path $Root 'tools\vr_generative\temporal_atlas_worker.py'
$MiganModel = Join-Path $Root 'models\vr\migan\migan_pipeline_v2.onnx'
$RaftWeights = Join-Path $Root 'models\motion\raft_small_C_T_V2-01064c6d.pth'
$Invariant = [Globalization.CultureInfo]::InvariantCulture

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DLSS5 Video Studio 19 · Temporal Atlas 2K/4K VR" Width="1500" Height="960"
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
    <Style TargetType="TabItem"><Setter Property="Foreground" Value="#C9D7E9"/><Setter Property="Padding" Value="14,8"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="88"/><RowDefinition Height="*"/><RowDefinition Height="76"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#111824" BorderBrush="#26354D" BorderThickness="1" CornerRadius="14" Padding="18,10" Margin="0,0,0,12">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="DLSS5 VIDEO STUDIO" FontSize="24" FontWeight="SemiBold" Foreground="#F5F9FF"/><TextBlock Text="Feature 18 · Temporal Atlas · real-frame 2K/4K VR · motion/depth · аппаратная автоадаптация" Foreground="#7F91AA" Margin="0,3,0,0"/></StackPanel>
        <Button x:Name="PreviewPaneButton" Grid.Column="1" Content="Скрыть просмотр" VerticalAlignment="Center" Margin="0,0,10,0" ToolTip="Правая панель не участвует в обработке. Её можно убрать, чтобы освободить место настройкам."/>
        <Border Grid.Column="2" Background="#102923" BorderBrush="#268C78" BorderThickness="1" CornerRadius="10" Padding="15,8" VerticalAlignment="Center"><TextBlock x:Name="RuntimeStatus" Text="● Persistent DLSS5 pipeline" Foreground="#6BE0C3"/></Border>
      </Grid>
    </Border>

    <Grid x:Name="MainWorkspaceGrid" Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition x:Name="SettingsColumn" Width="620"/><ColumnDefinition x:Name="PreviewGapColumn" Width="14"/><ColumnDefinition x:Name="PreviewColumn" Width="*"/></Grid.ColumnDefinitions>
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
              <Border x:Name="NetworkSourcePanel" Visibility="Collapsed" Background="#101B29" BorderBrush="#315270" BorderThickness="1" CornerRadius="9" Padding="10" Margin="0,0,0,9"><StackPanel>
                <TextBlock Text="ПАРАМЕТРЫ ВХОДА ПО ССЫЛКЕ" Foreground="#78D9FF" FontWeight="SemiBold"/>
                <TextBlock Text="Выберите качество именно исходного потока. Разрешение обработки задаётся отдельно ниже." Foreground="#849AB5" TextWrapping="Wrap" Margin="0,3,0,7"/>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <StackPanel><TextBlock Text="Входное разрешение"/><ComboBox x:Name="SourceNetworkHeightCombo"><ComboBoxItem Content="Лучшее доступное" Tag="0"/><ComboBoxItem Content="До 2160p / 4K" Tag="2160"/><ComboBoxItem Content="До 1440p" Tag="1440"/><ComboBoxItem Content="До 1080p" Tag="1080"/><ComboBoxItem Content="До 720p" Tag="720"/><ComboBoxItem Content="До 540p" Tag="540"/></ComboBox></StackPanel>
                  <StackPanel Grid.Column="2"><TextBlock Text="Авторизация сайта"/><ComboBox x:Name="SourceCookiesCombo"><ComboBoxItem Content="Публичное видео" Tag="None"/><ComboBoxItem Content="Cookies Chrome" Tag="chrome"/><ComboBoxItem Content="Cookies Edge" Tag="edge"/><ComboBoxItem Content="Cookies Firefox" Tag="firefox"/></ComboBox></StackPanel>
                </Grid>
              </StackPanel></Border>
              <StackPanel x:Name="RecordingPathPanel"><TextBlock Text="Папка для готовых записей"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="45"/></Grid.ColumnDefinitions><TextBox x:Name="OutputBox"/><Button x:Name="BrowseOutput" Grid.Column="1" Content="…"/></Grid></StackPanel>
            </StackPanel>
          </GroupBox>

          <Border Background="#0C1622" BorderBrush="#263A51" BorderThickness="1" CornerRadius="10" Padding="11" Margin="0,0,0,12"><StackPanel>
            <TextBlock Text="ЧТО ДЕЛАЕТ НАСТРОЙКА" Foreground="#60D7FF" FontWeight="SemiBold"/>
            <TextBlock x:Name="ContextHelpText" Text="Наведите курсор на параметр — здесь появится понятное объяснение и влияние на скорость, качество или память." Foreground="#9DB0C8" TextWrapping="Wrap" Margin="0,4,0,0"/>
          </StackPanel></Border>

          <TabControl x:Name="WorkspaceTabs" Height="112" Margin="0,0,0,12" Background="#0A1019" BorderBrush="#334B6D">
            <TabItem Header="▶  REALTIME" Tag="Realtime"><Border Background="#0D1822" Padding="14"><StackPanel><TextBlock Text="Живой GPU-вывод" FontSize="18" FontWeight="SemiBold" Foreground="#61D9FF"/><TextBlock Text="Буфер, перемотка, полноэкранный плеер, DLSS-G и отдельные настройки задержки." Foreground="#93A8C2" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border></TabItem>
            <TabItem Header="●  ЗАПИСЬ" Tag="Recording"><Border Background="#14170F" Padding="14"><StackPanel><TextBlock Text="Файл H.264 / H.265" FontSize="18" FontWeight="SemiBold" Foreground="#B7E36E"/><TextBlock Text="Локальное видео или ссылка; детальные motion/depth-параметры и автоматическое имя результата." Foreground="#A8B696" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border></TabItem>
            <TabItem Header="◉  VR / 3D" Tag="VR"><Border Background="#151224" Padding="14"><StackPanel><TextBlock Text="Отдельный VR-конвейер" FontSize="18" FontWeight="SemiBold" Foreground="#B59CFF"/><TextBlock Text="SBS/Over-Under, GAPW-геометрия, Temporal Atlas из соседних кадров, локальная AI-дорисовка и DLSS5." Foreground="#AEA3CE" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel></Border></TabItem>
          </TabControl>

          <GroupBox x:Name="QuickGroup" Header="БЫСТРЫЙ ЗАПУСК">
            <StackPanel>
              <TextBlock Text="Сценарий"/><ComboBox x:Name="QuickScenarioCombo"><ComboBoxItem Content="Ultra Fast · минимальная задержка" Tag="UltraFast"/><ComboBoxItem Content="Fast · живой просмотр" Tag="Fast"/><ComboBoxItem Content="Medium · универсальный" Tag="Medium"/><ComboBoxItem Content="Heavy · высокая точность" Tag="Heavy"/><ComboBoxItem Content="Maximum · максимум качества" Tag="Maximum"/><ComboBoxItem Content="VR 3D · Depth + DLSS5" Tag="DepthVR"/></ComboBox>
              <CheckBox x:Name="ExpertCheck" Content="Показать экспертные настройки" IsChecked="False" Margin="0,7,0,0"/>
              <TextBlock x:Name="QuickScenarioInfo" Foreground="#7F91AA" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="VrGroup" Header="VR-ВЫВОД">
            <StackPanel>
              <Border Background="#17122A" BorderBrush="#6B55A5" BorderThickness="1" CornerRadius="9" Padding="10" Margin="0,0,0,9"><StackPanel><TextBlock Text="DLSS 5 — ЯВНАЯ ЧАСТЬ VR-КОНВЕЙЕРА" Foreground="#C6B3FF" FontWeight="SemiBold"/><TextBlock Text="Обычный режим применяет настоящий DLSS5 Feature 18 до построения глаз. Максимальный режим дополнительно разделяет стереопару и запускает ещё один независимый DLSS5-проход для каждого глаза." Foreground="#A99BD0" TextWrapping="Wrap" Margin="0,3,0,0"/></StackPanel></Border>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Профиль VR"/><ComboBox x:Name="VRQualityPresetCombo"><ComboBoxItem Content="Cinematic · рекомендуется" Tag="Cinematic"/><ComboBoxItem Content="Fast · быстрее" Tag="Fast"/><ComboBoxItem Content="Maximum · всё качество" Tag="Maximum"/><ComboBoxItem Content="Вручную" Tag="Custom"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="DLSS 5 в VR"/><ComboBox x:Name="VRDLSSModeCombo"><ComboBoxItem Content="До стереосинтеза · 1 проход, быстро" Tag="PreStereo"/><ComboBoxItem Content="До + отдельно для каждого глаза · максимум" Tag="PreAndPerEye"/></ComboBox></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Режим просмотра"/><ComboBox x:Name="VrModeCombo"><ComboBoxItem Content="Обычное видео" Tag="Off"/><ComboBoxItem Content="3D VR · разные ракурсы из depth" Tag="DepthSBS"/><ComboBoxItem Content="VR-кинотеатр · плоский SBS" Tag="CinemaSBS"/><ComboBoxItem Content="Панорама 360° · equirectangular" Tag="Equirect360"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Компоновка для шлема"/><ComboBox x:Name="VrLayoutCombo"><ComboBoxItem Content="Half-SBS · та же ширина" Tag="HalfSBS"/><ComboBoxItem Content="Full-SBS · двойная ширина" Tag="FullSBS"/><ComboBoxItem Content="Half-OU · верх/низ" Tag="HalfOU"/><ComboBoxItem Content="Full-OU · двойная высота" Tag="FullOU"/></ComboBox></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Частота готового VR-видео"/><ComboBox x:Name="VrTargetFpsCombo"><ComboBoxItem Content="Как в исходнике" Tag="0"/><ComboBoxItem Content="72 FPS · стандарт VR" Tag="72"/><ComboBoxItem Content="90 FPS · плавно" Tag="90"/><ComboBoxItem Content="120 FPS · максимум плавности" Tag="120"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Метод плавности"/><TextBlock Text="Motion-compensated bidirectional interpolation после DLSS5 и стереосинтеза. Увеличивает время записи, но не число DLSS5-проходов." Foreground="#9387B8" TextWrapping="Wrap" Margin="0,5,0,0"/></StackPanel>
              </Grid>
              <Expander Header="МНОГОКАДРОВОЕ ВОССТАНОВЛЕНИЕ СКРЫТОГО ФОНА" Foreground="#7DE3C7" Margin="2,4,2,9">
                <Border Background="#0D211F" BorderBrush="#2B7B6B" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,7,0,0"><StackPanel>
                  <TextBlock Text="Temporal Atlas сначала переносит настоящий фон из прошлых и будущих кадров, проверяя motion, depth и контуры. MI-GAN получает только оставшиеся области; исходные 2K/4K-пиксели не уменьшаются." Foreground="#9CCFC2" TextWrapping="Wrap"/>
                  <Grid Margin="0,7,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Метод восстановления"/><ComboBox x:Name="VRGenerativeBackendCombo"><ComboBoxItem Content="Выключен · только стереоварп" Tag="Off"/><ComboBoxItem Content="Temporal Atlas + локальная AI · рекомендуется" Tag="TemporalAtlas"/><ComboBoxItem Content="Moebius Sparse · экспериментальный" Tag="MoebiusSparse"/><ComboBoxItem Content="M2SVid Hybrid · тяжёлый эксперимент" Tag="M2SVidHybrid"/><ComboBoxItem Content="M2SVid Full · меняет весь правый глаз" Tag="M2SVidFull"/></ComboBox></StackPanel>
                    <StackPanel Grid.Column="2"><TextBlock Text="Разрешение motion / neural ROI"/><ComboBox x:Name="VRGenerativeResolutionCombo"><ComboBoxItem Content="Авто по профилю" Tag="Auto"/><ComboBoxItem Content="384 · быстро" Tag="384"/><ComboBoxItem Content="512 · баланс" Tag="512"/><ComboBoxItem Content="640 · высокое качество" Tag="640"/><ComboBoxItem Content="768 · рекомендуемо для 4K" Tag="768"/><ComboBoxItem Content="1024 · точные края" Tag="1024"/><ComboBoxItem Content="1536 · очень тяжело" Tag="1536"/></ComboBox></StackPanel>
                  </Grid>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Дорисовка раскрытых областей"/><TextBlock x:Name="VRGenerativeHoleValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#7DE3C7"/></Grid><Slider x:Name="VRGenerativeHoleSlider" Minimum="0" Maximum="1" Value="1" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Глобальное уточнение правого глаза"/><TextBlock x:Name="VRGenerativeRefineValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#7DE3C7"/></Grid><Slider x:Name="VRGenerativeRefineSlider" Minimum="0" Maximum="1" Value="0.3" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Окно Temporal Atlas / шаги другой модели"/><TextBlock x:Name="VRGenerativeChunkValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#7DE3C7"/></Grid><Slider x:Name="VRGenerativeChunkSlider" Minimum="0" Maximum="30" Value="0" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Итерации RAFT / перекрытие другой модели"/><TextBlock x:Name="VRGenerativeOverlapValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#7DE3C7"/></Grid><Slider x:Name="VRGenerativeOverlapSlider" Minimum="0" Maximum="8" Value="4" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions><TextBlock x:Name="VRGenerativeStatusText" Text="Temporal Atlas: проверка установки…" Foreground="#A7B8C8" TextWrapping="Wrap" VerticalAlignment="Center"/><Button x:Name="InstallVRModelsButton" Grid.Column="1" Content="Установить ~28 МБ"/></Grid>
                </StackPanel></Border>
              </Expander>
              <Expander Header="ТОНКАЯ НАСТРОЙКА DEPTH-СТЕРЕО" Foreground="#C1B4EE" Margin="2,4,2,9">
                <Border BorderBrush="#3A315B" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,7,0,0"><StackPanel>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Стереорендер"/><ComboBox x:Name="VRStereoMethodCombo"><ComboBoxItem Content="GAPW · чистые маски для Atlas" Tag="GAPW"/><ComboBoxItem Content="Temporal LDI · старый многослойный" Tag="TemporalLDI"/><ComboBoxItem Content="Layered z-splat · баланс" Tag="Layered"/><ComboBoxItem Content="Inverse warp · максимум FPS" Tag="Inverse"/></ComboBox></StackPanel>
                    <StackPanel Grid.Column="2"><TextBlock Text="Стабилизация depth"/><ComboBox x:Name="VRTemporalModeCombo"><ComboBoxItem Content="Motion-compensated · рекомендуется" Tag="Motion"/><ComboBoxItem Content="EMA · проще" Tag="EMA"/><ComboBoxItem Content="Выключена" Tag="Off"/></ComboBox></StackPanel>
                  </Grid>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Опорный глаз"/><ComboBox x:Name="VREyeAnchorCombo"><ComboBoxItem Content="Симметрично · объём" Tag="Symmetric"/><ComboBoxItem Content="Левый исходный · чище/быстрее" Tag="Left"/><ComboBoxItem Content="Правый исходный · чище/быстрее" Tag="Right"/></ComboBox></StackPanel>
                    <StackPanel Grid.Column="2"><TextBlock Text="Совместимость файла"/><ComboBox x:Name="VRPixelFormatCombo"><ComboBoxItem Content="8-bit 4:2:0 · все шлемы" Tag="Compatible8Bit"/><ComboBoxItem Content="10-bit HEVC · меньше полос" Tag="HEVC10Bit"/></ComboBox></StackPanel>
                  </Grid>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Автофокус стерео"/><ComboBox x:Name="VRConvergenceModeCombo"><ComboBoxItem Content="По главному объекту" Tag="Subject"/><ComboBoxItem Content="Комфортный диапазон" Tag="Comfort"/><ComboBoxItem Content="Ручная плоскость" Tag="Manual"/></ComboBox></StackPanel>
                    <StackPanel Grid.Column="2"><TextBlock Text="Кривая параллакса"/><ComboBox x:Name="VRDisparityCurveCombo"><ComboBoxItem Content="Cinematic · выраженный объём" Tag="Cinematic"/><ComboBoxItem Content="Comfort · мягкие края" Tag="Comfort"/><ComboBoxItem Content="Linear · без коррекции" Tag="Linear"/></ComboBox></StackPanel>
                  </Grid>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Гамма глубины"/><TextBlock x:Name="VRDepthGammaValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRDepthGammaSlider" Minimum="0.25" Maximum="3" Value="1" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Сила переднего плана"/><TextBlock x:Name="VRForegroundValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRForegroundSlider" Minimum="0" Maximum="2" Value="1" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Сила заднего плана"/><TextBlock x:Name="VRBackgroundValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRBackgroundSlider" Minimum="0" Maximum="2" Value="0.75" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Приоритет ближнего слоя (z)"/><TextBlock x:Name="VRZBufferValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRZBufferSlider" Minimum="0" Maximum="10" Value="5" TickFrequency="0.25" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Заполнение раскрытых краёв"/><TextBlock x:Name="VROcclusionValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VROcclusionSlider" Minimum="0" Maximum="1" Value="0.65" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Радиус заполнения дыр"/><TextBlock x:Name="VRHoleFillValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRHoleFillSlider" Minimum="1" Maximum="48" Value="8" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Слои LDI"/><TextBlock x:Name="VRLDILayersValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRLDILayersSlider" Minimum="2" Maximum="12" Value="6" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Восстановление скрытого фона"/><TextBlock x:Name="VRBackgroundExpansionValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRBackgroundExpansionSlider" Minimum="0" Maximum="48" Value="16" TickFrequency="2" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Заполнение из соседних кадров"/><TextBlock x:Name="VRTemporalFillValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRTemporalFillSlider" Minimum="0" Maximum="1" Value="0.75" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Порог доверия temporal-fill"/><TextBlock x:Name="VRTemporalConfidenceValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRTemporalConfidenceSlider" Minimum="0" Maximum="1" Value="0.35" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Защита границ объектов"/><TextBlock x:Name="VREdgeProtectionValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VREdgeProtectionSlider" Minimum="0" Maximum="1" Value="0.7" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Обрезка выбросов depth"/><TextBlock x:Name="VRDepthTrimValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRDepthTrimSlider" Minimum="0" Maximum="10" Value="1.5" TickFrequency="0.5" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Комфортное ограничение параллакса"/><TextBlock x:Name="VRComfortValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRComfortSlider" Minimum="0" Maximum="1" Value="0.3" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Адаптивный 3D-комфорт"/><TextBlock x:Name="VRAdaptiveComfortValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRAdaptiveComfortSlider" Minimum="0" Maximum="1" Value="0.65" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Порог быстрого движения"/><TextBlock x:Name="VRMotionSafetyValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRMotionSafetySlider" Minimum="1" Maximum="40" Value="14" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Плавный вход 3D после склейки"/><TextBlock x:Name="VRSceneCutRampValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRSceneCutRampSlider" Minimum="0" Maximum="24" Value="6" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Резкость дорисованных областей"/><TextBlock x:Name="VRInpaintSharpenValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRInpaintSharpenSlider" Minimum="0" Maximum="1" Value="0.35" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Плавность автофокуса"/><TextBlock x:Name="VRConvergenceSmoothingValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRConvergenceSmoothingSlider" Minimum="0" Maximum="0.98" Value="0.88" TickFrequency="0.02" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Стабильность диапазона depth"/><TextBlock x:Name="VRDepthRangeSmoothingValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRDepthRangeSmoothingSlider" Minimum="0" Maximum="0.98" Value="0.9" TickFrequency="0.02" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Смягчение границ depth"/><TextBlock x:Name="VREdgeValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VREdgeSlider" Minimum="0" Maximum="12" Value="2" TickFrequency="1" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Временная стабилизация depth"/><TextBlock x:Name="VRTemporalValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRTemporalSlider" Minimum="0" Maximum="0.95" Value="0.55" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions><TextBlock Text="Максимальная диспаратность"/><TextBlock x:Name="VRDisparityValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B59CFF"/></Grid><Slider x:Name="VRDisparitySlider" Minimum="0.5" Maximum="5" Value="2.4" TickFrequency="0.1" IsSnapToTickEnabled="True"/>
                  <CheckBox x:Name="VREyeSwapCheck" Content="Поменять левый и правый глаз"/>
                </StackPanel></Border>
              </Expander>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Модель глубины"/><ComboBox x:Name="DepthModelCombo"><ComboBoxItem Content="DA2 Small · realtime" Tag="DA2Small"/><ComboBoxItem Content="Video Depth Anything · стабильное видео" Tag="VideoDepthSmall"/><ComboBoxItem Content="Depth Anything 3 Small · качество" Tag="DA3Small"/><ComboBoxItem Content="Depth Anything 3 Base · высокое" Tag="DA3Base"/><ComboBoxItem Content="Depth Anything 3 Large · максимум 3D" Tag="DA3Large"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Сила 3D"/><TextBlock x:Name="VREyeValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="VREyeSlider" Minimum="0.1" Maximum="3" Value="1" TickFrequency="0.1" IsSnapToTickEnabled="True"/><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Плоскость фокуса"/><TextBlock x:Name="VRConvergenceValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#9C8CFF"/></Grid><Slider x:Name="VRConvergenceSlider" Minimum="0.1" Maximum="0.9" Value="0.48" TickFrequency="0.02" IsSnapToTickEnabled="True"/></StackPanel>
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
            <ComboBox x:Name="HardwareCombo" Visibility="Collapsed"><ComboBoxItem Content="Автоматическая аппаратная адаптация" Tag="Auto"/></ComboBox>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Нагрузка / качество"/><ComboBox x:Name="PerformanceCombo"><ComboBoxItem Content="Ultra Fast · минимум задержки" Tag="UltraFast"/><ComboBoxItem Content="Fast · высокая скорость" Tag="Fast"/><ComboBoxItem Content="Medium · баланс" Tag="Medium"/><ComboBoxItem Content="Heavy · высокая точность" Tag="Heavy"/><ComboBoxItem Content="Maximum · максимум вычислений" Tag="Maximum"/></ComboBox></StackPanel>
              <StackPanel Grid.Column="2"><TextBlock Text="Внутреннее разрешение DLSS"/><ComboBox x:Name="RenderPresetCombo"><ComboBoxItem Content="Авто по VRAM и разрешению" Tag="Auto"/><ComboBoxItem Content="Native / DLAA · 100%" Tag="Native"/><ComboBoxItem Content="Quality · 75%" Tag="Quality"/><ComboBoxItem Content="Balanced · 67%" Tag="Balanced"/><ComboBoxItem Content="Performance · 50%" Tag="Performance"/></ComboBox></StackPanel>
            </Grid>
            <CheckBox x:Name="LivePreviewCheck" Content="Показывать готовый файл справа после записи"/>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="65"/></Grid.ColumnDefinitions><TextBlock Text="Качество NVENC (меньше = лучше)"/><TextBlock x:Name="QualityValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
            <Slider x:Name="QualitySlider" Minimum="12" Maximum="32" TickFrequency="1" IsSnapToTickEnabled="True"/>
            <WrapPanel><CheckBox x:Name="ComparisonCheck" Content="Сравнение: оригинал слева" IsChecked="True"/><CheckBox x:Name="KeepTempCheck" Content="Сохранить временные файлы"/></WrapPanel>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="RealtimePanel" Header="REALTIME-ПЛЕЕР">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Профиль realtime"/><ComboBox x:Name="RealtimeQualityCombo"><ComboBoxItem Content="Ultra Fast" Tag="UltraFast"/><ComboBoxItem Content="Fast" Tag="Fast"/><ComboBoxItem Content="Medium" Tag="Medium"/><ComboBoxItem Content="Heavy" Tag="Heavy"/><ComboBoxItem Content="Maximum" Tag="Maximum"/><ComboBoxItem Content="Вручную" Tag="Custom"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Окно плеера"/><CheckBox x:Name="RealtimeFullscreenCheck" Content="Сразу на весь экран" IsChecked="True"/><CheckBox x:Name="RealtimeAudioCheck" Content="Синхронный звук" IsChecked="True"/><TextBlock Text="F1: меню · F2: текущий/реальный FPS" Foreground="#7F91AA" Margin="0,3,0,0"/></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Генерация кадров"/><ComboBox x:Name="FrameGenerationCombo"><ComboBoxItem Content="Dynamic MFG · цель по FPS" Tag="NvidiaDynamicMFG"/><ComboBoxItem Content="NVIDIA DLSS-G · x2" Tag="NvidiaDLSSGx2"/><ComboBoxItem Content="NVIDIA MFG · x3" Tag="NvidiaMFGx3"/><ComboBoxItem Content="NVIDIA MFG · x4" Tag="NvidiaMFGx4"/><ComboBoxItem Content="GPU Motion · x2 fallback" Tag="MotionGPU"/><ComboBoxItem Content="Без генерации" Tag="Off"/><ComboBoxItem Content="Blend · только совместимость" Tag="CompatibilityBlend"/></ComboBox></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="Целевая частота MFG"/><ComboBox x:Name="RealtimeTargetFpsCombo"><ComboBoxItem Content="Авто · частота монитора" Tag="0"/><ComboBoxItem Content="60 FPS" Tag="60"/><ComboBoxItem Content="72 FPS" Tag="72"/><ComboBoxItem Content="90 FPS" Tag="90"/><ComboBoxItem Content="120 FPS" Tag="120"/></ComboBox><ComboBox x:Name="RealtimeFpsCombo" Visibility="Collapsed"><ComboBoxItem Content="Source" Tag="Source"/></ComboBox></StackPanel>
              </Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions><TextBlock Text="Громкость"/><TextBlock x:Name="RealtimeVolumeValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="RealtimeVolumeSlider" Minimum="0" Maximum="100" Value="80" TickFrequency="5" IsSnapToTickEnabled="True"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="MFG работает только при поддержке драйвера и GPU" Foreground="#7F91AA" TextWrapping="Wrap" Margin="0,5,0,0"/></StackPanel></Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions><TextBlock Text="Предварительная буферизация"/><TextBlock x:Name="RealtimeBufferValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid>
              <Slider x:Name="RealtimeBufferSlider" Minimum="3" Maximum="30" Value="5" TickFrequency="1" IsSnapToTickEnabled="True"/>
              <CheckBox x:Name="RealtimeFillPauseCheck" Content="Продолжать максимально наполнять буфер во время паузы" IsChecked="True"/>
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
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="CPU-потоки guide (0 = авто)"/><TextBlock x:Name="GuideWorkerValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#60D7FF"/></Grid><Slider x:Name="GuideWorkerSlider" Minimum="0" Maximum="16" Value="0" TickFrequency="1" IsSnapToTickEnabled="True"/>
                </StackPanel></Border>
              </Expander>
              <Border Background="#0C1622" BorderBrush="#263A51" BorderThickness="1" CornerRadius="8" Padding="9"><TextBlock Text="Управление в окне видео: Space — пауза; ←/→ — 10 с; Ctrl+←/→ — 60 с; Shift+←/→ или PageUp/PageDown — 5 мин; F11 или двойной клик — весь экран; F1/Tab — показать панель." Foreground="#9DB0C8" TextWrapping="Wrap"/></Border>
            </StackPanel>
          </GroupBox>

          <GroupBox x:Name="RecordingPanel" Header="ЗАПИСЬ И ТОЧНЫЕ MOTION / DEPTH-КАРТЫ">
            <StackPanel>
              <TextBlock Text="Универсальный профиль выше одновременно настраивает guide-разрешение, частоту нейроглубины, optical flow и размер чанка. Программа сама выбирает аппаратный класс по VRAM; названия видеокарт больше не нужны." Foreground="#96AB82" TextWrapping="Wrap" Margin="0,0,0,7"/>
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
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions><TextBlock Text="CPU-потоки guide (0 = авто)"/><TextBlock x:Name="RecordWorkerValue" Grid.Column="1" HorizontalAlignment="Right" Foreground="#B7E36E"/></Grid><Slider x:Name="RecordWorkerSlider" Minimum="0" Maximum="16" Value="0" TickFrequency="1" IsSnapToTickEnabled="True"/>
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

      <Border x:Name="PreviewPane" Grid.Column="2" Background="#101722" BorderBrush="#25344B" BorderThickness="1" CornerRadius="14" Padding="16">
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
$Names = @('RuntimeStatus','InputBox','BrowseInput','PasteInput','SourceResolutionText','VideoInfo','ExpectedTimeText','RecordingPathPanel','OutputBox','BrowseOutput','QuickScenarioCombo','ExpertCheck','QuickScenarioInfo','VrGroup','StageGroup','UpscalerGroup','NeuralGroup','AdvancedParams','HardwareCombo','RenderPresetCombo','DepthModelCombo','VREyeSlider','VREyeValue','VRConvergenceSlider','VRConvergenceValue','FrameGenerationCombo','ModeCombo','CodecCombo','PerformanceCombo','LivePreviewCheck','QualitySlider','QualityValue','ComparisonCheck','KeepTempCheck','VrModeCombo','VrLayoutCombo','VrInfo','RealtimePanel','RealtimeFullscreenCheck','RealtimeQualityCombo','RealtimeQualityInfo','RealtimeFpsCombo','RealtimeAudioCheck','RealtimeVolumeSlider','RealtimeVolumeValue','RealtimeBufferSlider','RealtimeBufferValue','GuideWidthSlider','GuideWidthValue','DepthIntervalSlider','DepthIntervalValue','DepthMinIntervalSlider','DepthMinIntervalValue','AdaptiveConfidenceSlider','AdaptiveConfidenceValue','AdaptiveMotionSlider','AdaptiveMotionValue','TemporalDepthSlider','TemporalDepthValue','SceneCutSlider','SceneCutValue','GuideMotionPresetCombo','GuideMotionBackendCombo','RaftUpdatesSlider','RaftUpdatesValue','UpscalerCombo','UpscalerVariantCombo','UpscalerStrengthSlider','UpscalerStrengthValue','UpscalerInfo','StageList','StageUp','StageDown','StageOrderInfo','PresetBox','SavePreset','DeletePreset','IntensitySlider','IntensityValue','ToneSlider','ToneValue','StructureSlider','StructureValue','SkinSlider','SkinValue','NrPresetCombo','StyleCombo','AutoMaskCheck','UpliftCheck','UICorrectionCheck','AggressionText','MotionXSlider','MotionXValue','MotionYSlider','MotionYValue','DepthCombo','TransferSlider','TransferValue','ColorSlider','ColorValue','PaperSlider','PaperValue','StartBox','FramesBox','FullVideoCheck','RangeHint','StatusText','DetailText','EtaText','ElapsedText','SpeedText','Preview','Placeholder','LogBox','Progress','ProgressHint','PlayButton','OpenVideo','OpenFolder','CancelButton','RunButton')
foreach ($Name in $Names) { Set-Variable -Name $Name -Value $Window.FindName($Name) -Scope Script }
$AdditionalNames = @(
    'WorkspaceTabs','QuickGroup','OutputGroup','RecordingPanel','RangeGroup','RealtimeChunkSlider','RealtimeChunkValue','RealtimeFillPauseCheck',
    'PreviewPaneButton','PreviewPane','SettingsColumn','PreviewGapColumn','PreviewColumn','NetworkSourcePanel','SourceNetworkHeightCombo','SourceCookiesCombo','ContextHelpText',
    'RealtimeTargetFpsCombo','GuideWorkerSlider','GuideWorkerValue','RecordWorkerSlider','RecordWorkerValue',
    'RecordFineGuideCheck','RecordFineGuideExpander','VrTargetFpsCombo','VRDisparitySlider','VRDisparityValue',
    'RecordGuideWidthSlider','RecordGuideWidthValue','RecordDepthIntervalSlider','RecordDepthIntervalValue',
    'RecordDepthMinSlider','RecordDepthMinValue','RecordConfidenceSlider','RecordConfidenceValue',
    'RecordMotionSlider','RecordMotionValue','RecordTemporalSlider','RecordTemporalValue','RecordSceneSlider','RecordSceneValue',
    'RecordMotionPresetCombo','RecordMotionBackendCombo','RecordRaftSlider','RecordRaftValue','RecordChunkSlider','RecordChunkValue',
    'VRDepthGammaSlider','VRDepthGammaValue','VROcclusionSlider','VROcclusionValue','VREdgeSlider','VREdgeValue',
    'VRTemporalSlider','VRTemporalValue','VREyeSwapCheck','VRStereoMethodCombo','VRTemporalModeCombo','VRDLSSModeCombo','VRQualityPresetCombo',
    'VREyeAnchorCombo','VRPixelFormatCombo','VRForegroundSlider','VRForegroundValue',
    'VRBackgroundSlider','VRBackgroundValue','VRZBufferSlider','VRZBufferValue','VRHoleFillSlider','VRHoleFillValue',
    'VRConvergenceModeCombo','VRDisparityCurveCombo','VRLDILayersSlider','VRLDILayersValue',
    'VRBackgroundExpansionSlider','VRBackgroundExpansionValue','VRTemporalFillSlider','VRTemporalFillValue',
    'VRTemporalConfidenceSlider','VRTemporalConfidenceValue','VREdgeProtectionSlider','VREdgeProtectionValue',
    'VRDepthTrimSlider','VRDepthTrimValue','VRComfortSlider','VRComfortValue','VRInpaintSharpenSlider','VRInpaintSharpenValue',
    'VRAdaptiveComfortSlider','VRAdaptiveComfortValue','VRMotionSafetySlider','VRMotionSafetyValue','VRSceneCutRampSlider','VRSceneCutRampValue',
    'VRConvergenceSmoothingSlider','VRConvergenceSmoothingValue','VRDepthRangeSmoothingSlider','VRDepthRangeSmoothingValue',
    'VRGenerativeBackendCombo','VRGenerativeResolutionCombo','VRGenerativeHoleSlider','VRGenerativeHoleValue',
    'VRGenerativeRefineSlider','VRGenerativeRefineValue','VRGenerativeChunkSlider','VRGenerativeChunkValue',
    'VRGenerativeOverlapSlider','VRGenerativeOverlapValue','VRGenerativeStatusText','InstallVRModelsButton'
)
foreach ($Name in $AdditionalNames) { Set-Variable -Name $Name -Value $Window.FindName($Name) -Scope Script }

$BuiltIn = [ordered]@{
    'Balanced · рекомендовано' = [ordered]@{ intensity=1.35; tone=1.15; structure=1.75; skin=1.25; preset=1; style=1; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
    'Natural · мягко' = [ordered]@{ intensity=1.05; tone=1.0; structure=1.0; skin=-1.0; preset=1; style=1; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
    'Strong · максимум' = [ordered]@{ intensity=2.0; tone=1.6; structure=2.0; skin=1.65; preset=1; style=1; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
    'Cinematic' = [ordered]@{ intensity=1.35; tone=1.35; structure=1.35; skin=1.0; preset=2; style=2; automask=$true; uplift=$true; ui=$false; motionx=1.0; motiony=1.0; depth=0; transfer=1.0; color=1.0; paper=1.0 }
}
$RealtimeProfiles = [ordered]@{
    UltraFast = [ordered]@{ guide=256; interval=24; minimum=16; confidence=0.0; motion=0.0; temporal=0.88; scene=0.16; preset='realtime'; backend='dis'; updates=3; workers=0; text='Минимальная задержка: DIS, компактная guide-карта и редкая нейроглубина. DLSS5 обрабатывает каждый кадр; экономятся только служебные карты.' }
    Fast = [ordered]@{ guide=320; interval=16; minimum=8; confidence=0.70; motion=16.0; temporal=0.78; scene=0.13; preset='realtime'; backend='dis'; updates=4; workers=0; text='Быстрый универсальный режим: чаще обновляет depth на сложном движении, сохраняя лёгкий DIS optical flow.' }
    Medium = [ordered]@{ guide=384; interval=12; minimum=6; confidence=0.62; motion=14.0; temporal=0.68; scene=0.11; preset='balanced'; backend='raft'; updates=4; workers=0; text='Баланс скорости и стабильности: RAFT-small, адаптивная глубина и умеренная временная фильтрация.' }
    Heavy = [ordered]@{ guide=512; interval=6; minimum=3; confidence=0.55; motion=11.0; temporal=0.52; scene=0.09; preset='quality'; backend='raft'; updates=6; workers=0; text='Высокая точность персонажей и границ: более крупные guide-карты, RAFT 6 итераций и частая нейроглубина.' }
    Maximum = [ordered]@{ guide=640; interval=3; minimum=2; confidence=0.48; motion=8.0; temporal=0.40; scene=0.07; preset='quality'; backend='raft'; updates=10; workers=0; text='Максимум вычислений и устойчивости depth/motion. Используйте, когда качество важнее задержки.' }
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
$script:ApplyingVrProfile = $false
$script:SyncingUniversalProfile = $false

function Tag($Combo) { if ($Combo.SelectedItem) { return [int]$Combo.SelectedItem.Tag }; return 0 }
function Select-Tag($Combo,[int]$Value) { foreach($Item in $Combo.Items){ if([int]$Item.Tag -eq $Value){$Combo.SelectedItem=$Item;break} } }
function F([double]$Value) { $Value.ToString('0.00',$Invariant) }
function Combo-Tag($Combo) { if ($Combo.SelectedItem) { return [string]$Combo.SelectedItem.Tag }; return '' }
function Select-StringTag($Combo,[string]$Value) { foreach($Item in $Combo.Items){ if([string]$Item.Tag -eq $Value){$Combo.SelectedItem=$Item;break} } }
function Test-M2SVidInstalled {
    return (Test-Path -LiteralPath $M2SVidCode -PathType Leaf) -and
        (Test-Path -LiteralPath $M2SVidInstallStatus -PathType Leaf) -and
        (Test-Path -LiteralPath $M2SVidCheckpoint -PathType Leaf) -and
        (Get-Item -LiteralPath $M2SVidCheckpoint).Length -eq 4978220327 -and
        (Test-Path -LiteralPath $M2SVidOpenClip -PathType Leaf) -and
        (Get-Item -LiteralPath $M2SVidOpenClip).Length -eq 3944692325
}
function Test-MoebiusInstalled {
    return (Test-Path -LiteralPath $MoebiusCode -PathType Leaf) -and
        (Test-Path -LiteralPath $MoebiusInstallStatus -PathType Leaf) -and
        (Test-Path -LiteralPath $MoebiusCheckpoint -PathType Leaf) -and
        (Get-Item -LiteralPath $MoebiusCheckpoint).Length -eq 905298356 -and
        (Test-Path -LiteralPath $MoebiusVae -PathType Leaf) -and
        (Get-Item -LiteralPath $MoebiusVae).Length -eq 167394306 -and
        (Test-Path -LiteralPath $MoebiusDiffusers -PathType Leaf)
}
function Test-VrGenerativeBackendInstalled([string]$Backend) {
    if($Backend-eq'TemporalAtlas'){
        return (Test-Path -LiteralPath $TemporalAtlasWorker -PathType Leaf) -and
            (Test-Path -LiteralPath $MiganModel -PathType Leaf) -and
            (Test-Path -LiteralPath $RaftWeights -PathType Leaf)
    }
    if($Backend-eq'MoebiusSparse'){return (Test-MoebiusInstalled)}
    if($Backend-in @('M2SVidHybrid','M2SVidFull')){return (Test-M2SVidInstalled)}
    return $true
}
function Refresh-VrGenerativeStatus {
    $script:TemporalAtlasReady = Test-VrGenerativeBackendInstalled 'TemporalAtlas'
    $script:MoebiusReady = Test-MoebiusInstalled
    $script:M2SVidReady = Test-M2SVidInstalled
    if($script:TemporalAtlasReady){
        $Experimental=@()
        if($script:MoebiusReady){$Experimental+='Moebius'}
        if($script:M2SVidReady){$Experimental+='M2SVid'}
        $Suffix=if($Experimental.Count -gt 0){' · эксперименты: '+($Experimental -join ', ')}else{''}
        $VRGenerativeStatusText.Text='Temporal Atlas готов · реальный фон + локальная MI-GAN, нативные 2K/4K'+$Suffix
        $VRGenerativeStatusText.Foreground='#70E0C0'
        $InstallVRModelsButton.Content='Проверить / обновить'
    } else {
        $VRGenerativeStatusText.Text='Temporal Atlas не установлен · основной MI-GAN-пакет около 28 МБ, загрузка возобновляется'
        $VRGenerativeStatusText.Foreground='#E7B878'
        $InstallVRModelsButton.Content='Установить ~28 МБ'
    }
}
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
    $GuideWorkerValue.Text=if([int]$GuideWorkerSlider.Value-eq 0){'Авто'}else{[string][int]$GuideWorkerSlider.Value}
    $RecordWorkerValue.Text=if([int]$RecordWorkerSlider.Value-eq 0){'Авто'}else{[string][int]$RecordWorkerSlider.Value}
    $VRDepthGammaValue.Text=F $VRDepthGammaSlider.Value;$VROcclusionValue.Text=F $VROcclusionSlider.Value;$VREdgeValue.Text=[string][int]$VREdgeSlider.Value;$VRTemporalValue.Text=F $VRTemporalSlider.Value;$VRDisparityValue.Text=(F $VRDisparitySlider.Value)+'%'
    $VRForegroundValue.Text=F $VRForegroundSlider.Value;$VRBackgroundValue.Text=F $VRBackgroundSlider.Value;$VRZBufferValue.Text=F $VRZBufferSlider.Value;$VRHoleFillValue.Text=[string][int]$VRHoleFillSlider.Value
    $VRLDILayersValue.Text=[string][int]$VRLDILayersSlider.Value;$VRBackgroundExpansionValue.Text=([string][int]$VRBackgroundExpansionSlider.Value)+' px';$VRTemporalFillValue.Text=F $VRTemporalFillSlider.Value;$VRTemporalConfidenceValue.Text=F $VRTemporalConfidenceSlider.Value
    $VREdgeProtectionValue.Text=F $VREdgeProtectionSlider.Value;$VRDepthTrimValue.Text=(F $VRDepthTrimSlider.Value)+'%';$VRComfortValue.Text=F $VRComfortSlider.Value;$VRInpaintSharpenValue.Text=F $VRInpaintSharpenSlider.Value
    $VRAdaptiveComfortValue.Text=F $VRAdaptiveComfortSlider.Value;$VRMotionSafetyValue.Text=([string][int]$VRMotionSafetySlider.Value)+' px';$VRSceneCutRampValue.Text=([string][int]$VRSceneCutRampSlider.Value)+' к.'
    $VRConvergenceSmoothingValue.Text=F $VRConvergenceSmoothingSlider.Value;$VRDepthRangeSmoothingValue.Text=F $VRDepthRangeSmoothingSlider.Value
    $VRGenerativeHoleValue.Text=F $VRGenerativeHoleSlider.Value;$VRGenerativeRefineValue.Text=F $VRGenerativeRefineSlider.Value
    $VRGenerativeChunkValue.Text=if([int]$VRGenerativeChunkSlider.Value-eq 0){'Авто'}else{[string][int]$VRGenerativeChunkSlider.Value}
    $VRGenerativeOverlapValue.Text=switch(Combo-Tag $VRGenerativeBackendCombo){'MoebiusSparse'{([string]([int]$VRGenerativeOverlapSlider.Value*32))+' px'}'TemporalAtlas'{([string][int]$VRGenerativeOverlapSlider.Value)+' ит.'}default{([string][int]$VRGenerativeOverlapSlider.Value)+' к.'}}
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
        if((Combo-Tag $RealtimeQualityCombo)-ne'Custom'){Select-StringTag $PerformanceCombo (Combo-Tag $RealtimeQualityCombo)}
        Select-StringTag $VrModeCombo 'Off'
    }else{
        if($Vr -and (Combo-Tag $VrModeCombo)-eq'Off'){Select-StringTag $VrModeCombo 'DepthSBS'}
        if(-not $Vr){Select-StringTag $VrModeCombo 'Off'}
    }
    Update-ExpertUi;Update-ProfileUi;Update-VrUi;Update-Estimate
    $RuntimeStatus.Text=if($Realtime){'● REALTIME · GPU-direct'}elseif($Vr){'● VR / 3D · запись'}else{'● ЗАПИСЬ · H.264 / H.265'}
}
function Apply-QuickScenario {
    $Scenario=Combo-Tag $QuickScenarioCombo
    switch($Scenario){
        'UltraFast' { $WorkspaceTabs.SelectedIndex=0;Select-StringTag $PerformanceCombo 'UltraFast';Select-StringTag $ModeCombo '1080p';Select-StringTag $RenderPresetCombo 'Performance';Select-StringTag $FrameGenerationCombo 'NvidiaDynamicMFG';Select-StringTag $RealtimeTargetFpsCombo '90';Select-StringTag $DepthModelCombo 'DA2Small';Apply-RealtimeProfile 'UltraFast';$QuickScenarioInfo.Text='Минимальная задержка и автоматическая адаптация по VRAM. DLSS5 остаётся на каждом кадре, а служебные карты строятся облегчённо.' }
        'Fast' { $WorkspaceTabs.SelectedIndex=0;Select-StringTag $PerformanceCombo 'Fast';Select-StringTag $ModeCombo '1080p';Select-StringTag $RenderPresetCombo 'Balanced';Select-StringTag $FrameGenerationCombo 'NvidiaDynamicMFG';Select-StringTag $RealtimeTargetFpsCombo '90';Select-StringTag $DepthModelCombo 'DA2Small';Apply-RealtimeProfile 'Fast';$QuickScenarioInfo.Text='Быстрый просмотр с адаптивной нейроглубиной. Подходит как стартовая точка почти для любого железа.' }
        'Medium' { $WorkspaceTabs.SelectedIndex=0;Select-StringTag $PerformanceCombo 'Medium';Select-StringTag $ModeCombo '1440p';Select-StringTag $RenderPresetCombo 'Auto';Select-StringTag $FrameGenerationCombo 'NvidiaDynamicMFG';Select-StringTag $RealtimeTargetFpsCombo '90';Select-StringTag $DepthModelCombo 'DA2Small';Apply-RealtimeProfile 'Medium';$QuickScenarioInfo.Text='Универсальный баланс: RAFT, DLSS5 Feature 18 и Dynamic MFG с честной проверкой поддержки.' }
        'Heavy' { Select-StringTag $PerformanceCombo 'Heavy';Apply-RealtimeProfile 'Heavy';$QuickScenarioInfo.Text='Более точные motion/depth-карты и частые обновления. Программа сама использует доступные CPU-потоки и VRAM.' }
        'Maximum' { Select-StringTag $PerformanceCombo 'Maximum';Apply-RealtimeProfile 'Maximum';$QuickScenarioInfo.Text='Максимальная точность motion/depth и нейрорендеринга; предназначен для запаса производительности или финальной записи.' }
        'DepthVR' {
            $WorkspaceTabs.SelectedIndex=2
            Select-StringTag $ModeCombo '1440p';Select-StringTag $PerformanceCombo 'Heavy';Select-StringTag $VrModeCombo 'DepthSBS';Select-StringTag $VrTargetFpsCombo '90';Select-StringTag $VRPixelFormatCombo 'Compatible8Bit'
            Select-StringTag $VRQualityPresetCombo 'Cinematic'
            $QuickScenarioInfo.Text='DLSS5 восстанавливает исходный ракурс, DA3 строит геометрию, Temporal LDI восстанавливает скрытый фон и переносит его между кадрами. При необходимости включите отдельный DLSS5-проход для каждого глаза.'
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
        $GuideWorkerSlider.Value=$P.workers
    }finally{$script:ApplyingRealtimeProfile=$false}
    Refresh-Labels;Update-RealtimeQualityInfo;Update-Estimate
}
function Apply-VrProfile {
    if(-not $VRQualityPresetCombo.SelectedItem -or $script:ApplyingVrProfile){return}
    $Name=Combo-Tag $VRQualityPresetCombo
    if($Name-eq'Custom'){Update-VrUi;Update-Estimate;return}
    $script:ApplyingVrProfile=$true
    try{
        Select-StringTag $VrModeCombo 'DepthSBS'
        Select-StringTag $VRTemporalModeCombo 'Motion'
        Select-StringTag $VREyeAnchorCombo 'Symmetric'
        Select-StringTag $VRConvergenceModeCombo 'Subject'
        switch($Name){
            'Fast' {
                Select-StringTag $DepthModelCombo 'DA2Small';Select-StringTag $VRStereoMethodCombo 'GAPW';Select-StringTag $VRDLSSModeCombo 'PreStereo';Select-StringTag $VRDisparityCurveCombo 'Comfort';Select-StringTag $VrLayoutCombo 'HalfSBS'
                Select-StringTag $VRGenerativeBackendCombo $(if($script:TemporalAtlasReady){'TemporalAtlas'}else{'Off'});Select-StringTag $VRGenerativeResolutionCombo 'Auto';$VRGenerativeChunkSlider.Value=4;$VRGenerativeOverlapSlider.Value=4;$VRGenerativeHoleSlider.Value=0.85;$VRGenerativeRefineSlider.Value=0.10
                $VREyeSlider.Value=0.85;$VRConvergenceSlider.Value=0.50;$VRDepthGammaSlider.Value=1.0;$VRForegroundSlider.Value=0.90;$VRBackgroundSlider.Value=0.65;$VRZBufferSlider.Value=4.0;$VROcclusionSlider.Value=0.65;$VRHoleFillSlider.Value=8;$VRLDILayersSlider.Value=4;$VRBackgroundExpansionSlider.Value=10;$VRTemporalFillSlider.Value=0.55;$VRTemporalConfidenceSlider.Value=0.45;$VREdgeProtectionSlider.Value=0.55;$VRDepthTrimSlider.Value=2.0;$VRComfortSlider.Value=0.60;$VRAdaptiveComfortSlider.Value=0.85;$VRMotionSafetySlider.Value=10;$VRSceneCutRampSlider.Value=8;$VRInpaintSharpenSlider.Value=0.20;$VRConvergenceSmoothingSlider.Value=0.86;$VRDepthRangeSmoothingSlider.Value=0.86;$VREdgeSlider.Value=2;$VRTemporalSlider.Value=0.48;$VRDisparitySlider.Value=1.8
            }
            'Maximum' {
                Select-StringTag $DepthModelCombo 'DA3Large';Select-StringTag $VRStereoMethodCombo 'GAPW';Select-StringTag $VRDLSSModeCombo 'PreAndPerEye';Select-StringTag $VRDisparityCurveCombo 'Cinematic';Select-StringTag $VrLayoutCombo 'FullSBS'
                Select-StringTag $VRGenerativeBackendCombo $(if($script:TemporalAtlasReady){'TemporalAtlas'}else{'Off'});Select-StringTag $VRGenerativeResolutionCombo 'Auto';$VRGenerativeChunkSlider.Value=12;$VRGenerativeOverlapSlider.Value=8;$VRGenerativeHoleSlider.Value=1.0;$VRGenerativeRefineSlider.Value=0.50
                $VREyeSlider.Value=1.15;$VRConvergenceSlider.Value=0.48;$VRDepthGammaSlider.Value=1.05;$VRForegroundSlider.Value=1.15;$VRBackgroundSlider.Value=0.82;$VRZBufferSlider.Value=7.0;$VROcclusionSlider.Value=0.82;$VRHoleFillSlider.Value=24;$VRLDILayersSlider.Value=10;$VRBackgroundExpansionSlider.Value=32;$VRTemporalFillSlider.Value=0.88;$VRTemporalConfidenceSlider.Value=0.42;$VREdgeProtectionSlider.Value=0.92;$VRDepthTrimSlider.Value=1.0;$VRComfortSlider.Value=0.20;$VRAdaptiveComfortSlider.Value=0.55;$VRMotionSafetySlider.Value=18;$VRSceneCutRampSlider.Value=4;$VRInpaintSharpenSlider.Value=0.55;$VRConvergenceSmoothingSlider.Value=0.94;$VRDepthRangeSmoothingSlider.Value=0.94;$VREdgeSlider.Value=1;$VRTemporalSlider.Value=0.68;$VRDisparitySlider.Value=2.8
            }
            default {
                Select-StringTag $DepthModelCombo 'VideoDepthSmall';Select-StringTag $VRStereoMethodCombo 'GAPW';Select-StringTag $VRDLSSModeCombo 'PreStereo';Select-StringTag $VRDisparityCurveCombo 'Cinematic';Select-StringTag $VrLayoutCombo 'FullSBS'
                Select-StringTag $VRGenerativeBackendCombo $(if($script:TemporalAtlasReady){'TemporalAtlas'}else{'Off'});Select-StringTag $VRGenerativeResolutionCombo 'Auto';$VRGenerativeChunkSlider.Value=8;$VRGenerativeOverlapSlider.Value=6;$VRGenerativeHoleSlider.Value=1.0;$VRGenerativeRefineSlider.Value=0.25
                $VREyeSlider.Value=1.0;$VRConvergenceSlider.Value=0.48;$VRDepthGammaSlider.Value=1.0;$VRForegroundSlider.Value=1.0;$VRBackgroundSlider.Value=0.75;$VRZBufferSlider.Value=5.5;$VROcclusionSlider.Value=0.75;$VRHoleFillSlider.Value=16;$VRLDILayersSlider.Value=6;$VRBackgroundExpansionSlider.Value=20;$VRTemporalFillSlider.Value=0.75;$VRTemporalConfidenceSlider.Value=0.35;$VREdgeProtectionSlider.Value=0.75;$VRDepthTrimSlider.Value=1.5;$VRComfortSlider.Value=0.30;$VRAdaptiveComfortSlider.Value=0.70;$VRMotionSafetySlider.Value=14;$VRSceneCutRampSlider.Value=6;$VRInpaintSharpenSlider.Value=0.35;$VRConvergenceSmoothingSlider.Value=0.88;$VRDepthRangeSmoothingSlider.Value=0.90;$VREdgeSlider.Value=2;$VRTemporalSlider.Value=0.55;$VRDisparitySlider.Value=2.4
            }
        }
    }finally{$script:ApplyingVrProfile=$false}
    Refresh-Labels;Update-VrUi;Update-Estimate
}
function Mark-VrCustom {
    if(-not $script:ApplyingVrProfile -and $VRQualityPresetCombo.SelectedItem -and (Combo-Tag $VRQualityPresetCombo)-ne'Custom'){
        Select-StringTag $VRQualityPresetCombo 'Custom'
    }
    Refresh-Labels;Update-VrUi;Update-Estimate
}
function Mark-RealtimeCustom {
    if($DepthMinIntervalSlider.Value -gt $DepthIntervalSlider.Value){
        $WasApplying=$script:ApplyingRealtimeProfile;$script:ApplyingRealtimeProfile=$true
        try{$DepthMinIntervalSlider.Value=$DepthIntervalSlider.Value}finally{$script:ApplyingRealtimeProfile=$WasApplying}
    }
    $RaftUpdatesSlider.IsEnabled=((Combo-Tag $GuideMotionBackendCombo)-eq'raft') -and ((Get-WorkspaceMode)-eq'Realtime')
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
    $StageUp.IsEnabled = $HasVsr -and (Get-WorkspaceMode) -ne 'Realtime'
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
    if ((Get-PipelineOrder) -eq 'DLSSThenVSR') { $LivePreviewCheck.IsChecked=$false; $LivePreviewCheck.IsEnabled=$false } elseif ((Get-WorkspaceMode) -ne 'Realtime') { $LivePreviewCheck.IsEnabled=$true }
}
function Update-VrUi {
    if (-not $VrModeCombo.SelectedItem) { return }
    $VrMode=Combo-Tag $VrModeCombo
    $VrLayoutCombo.IsEnabled = $VrMode -in @('CinemaSBS','DepthSBS') -and (Get-WorkspaceMode) -ne 'Realtime'
    $DepthStereo=$VrMode-eq'DepthSBS'
    foreach($Control in @($VREyeSlider,$VRConvergenceSlider,$VRDepthGammaSlider,$VROcclusionSlider,$VREdgeSlider,$VRTemporalSlider,$VRDisparitySlider,$VREyeSwapCheck,$VRStereoMethodCombo,$VRTemporalModeCombo,$VREyeAnchorCombo,$VRForegroundSlider,$VRBackgroundSlider,$VRZBufferSlider,$VRHoleFillSlider,$VRDLSSModeCombo,$VRQualityPresetCombo,$VRConvergenceModeCombo,$VRDisparityCurveCombo,$VRLDILayersSlider,$VRBackgroundExpansionSlider,$VRTemporalFillSlider,$VRTemporalConfidenceSlider,$VREdgeProtectionSlider,$VRDepthTrimSlider,$VRComfortSlider,$VRAdaptiveComfortSlider,$VRMotionSafetySlider,$VRSceneCutRampSlider,$VRInpaintSharpenSlider,$VRConvergenceSmoothingSlider,$VRDepthRangeSmoothingSlider,$VRGenerativeBackendCombo)){$Control.IsEnabled=$DepthStereo}
    $Generative=$DepthStereo -and (Combo-Tag $VRGenerativeBackendCombo)-ne'Off'
    $Atlas=$Generative -and (Combo-Tag $VRGenerativeBackendCombo)-eq'TemporalAtlas'
    if($Atlas -and (Combo-Tag $VRStereoMethodCombo)-ne'GAPW'){
        Select-StringTag $VRStereoMethodCombo 'GAPW'
        Select-StringTag $VREyeAnchorCombo 'Symmetric'
    }elseif($Generative -and -not $Atlas -and (Combo-Tag $VRStereoMethodCombo)-ne'TemporalLDI'){
        Select-StringTag $VRStereoMethodCombo 'TemporalLDI'
    }
    foreach($Control in @($VRGenerativeResolutionCombo,$VRGenerativeChunkSlider,$VRGenerativeOverlapSlider)){$Control.IsEnabled=$Generative}
    $Hybrid=$Generative -and (Combo-Tag $VRGenerativeBackendCombo)-eq'M2SVidHybrid'
    $Sparse=$Generative -and (Combo-Tag $VRGenerativeBackendCombo)-eq'MoebiusSparse'
    $VRGenerativeHoleSlider.IsEnabled=$Hybrid -or $Sparse -or $Atlas;$VRGenerativeRefineSlider.IsEnabled=$Hybrid -or $Atlas
    if($Sparse -and $VRGenerativeRefineSlider.Value-ne 0){$VRGenerativeRefineSlider.Value=0}
    $VREyeAnchorCombo.IsEnabled=$DepthStereo -and -not $Generative
    $VRPixelFormatCombo.IsEnabled=$VrMode-ne'Off' -and (Combo-Tag $CodecCombo)-eq'H265'
    if((Combo-Tag $CodecCombo)-eq'H264'){Select-StringTag $VRPixelFormatCombo 'Compatible8Bit'}
    $LayeredStereo=$DepthStereo -and (Combo-Tag $VRStereoMethodCombo)-in @('GAPW','Layered','TemporalLDI')
    $TemporalLdi=$DepthStereo -and (Combo-Tag $VRStereoMethodCombo)-eq'TemporalLDI'
    $Gapw=$DepthStereo -and (Combo-Tag $VRStereoMethodCombo)-eq'GAPW'
    $VRZBufferSlider.IsEnabled=$LayeredStereo
    $VRHoleFillSlider.IsEnabled=$VRZBufferSlider.IsEnabled
    foreach($Control in @($VRLDILayersSlider,$VRBackgroundExpansionSlider,$VRInpaintSharpenSlider)){$Control.IsEnabled=$TemporalLdi -or $Gapw}
    foreach($Control in @($VRTemporalFillSlider,$VRTemporalConfidenceSlider)){$Control.IsEnabled=$TemporalLdi}
    $VRConvergenceSmoothingSlider.IsEnabled=$DepthStereo -and (Combo-Tag $VRConvergenceModeCombo)-ne'Manual'
    switch($VrMode){
        'DepthSBS' { $VrInfo.Text=if($Atlas){'Рекомендуемый 2K/4K-путь: DLSS5 → neural depth → симметричный GAPW → Temporal Atlas. Фон берётся из прошлых и будущих кадров в нативном разрешении; MI-GAN запускается не более чем для 1–2 остаточных ROI на глаз.'}elseif($Sparse){'Экспериментальный путь: DLSS5 → neural depth/motion → Temporal LDI → Moebius по остаточным ROI. Покадровая диффузия медленнее и может быть менее стабильной.'}elseif($Generative){'Тяжёлый эксперимент: M2SVid видит левое видео, правый warp и маску во временном окне. Он требует много VRAM и заметно смягчает 4K-детали.'}else{'Быстрый путь без нейрозаполнения: DLSS5 → depth → GAPW/LDI. Для чистых скрытых областей выберите Temporal Atlas.'} }
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
    $Realtime=(Get-WorkspaceMode)-eq'Realtime'
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
    switch(Combo-Tag $PerformanceCombo){'UltraFast'{$Effective*=2.8}'Fast'{$Effective*=2.0}'Medium'{$Effective*=1.25}'Heavy'{$Effective*=0.78}'Maximum'{$Effective*=0.55}}
    $Seconds=$Startup+$Frames/[math]::Max(0.01,$Effective)
    if((Get-PipelineOrder)-eq 'DLSSThenVSR'){$Seconds*=1.12}
    if((Combo-Tag $VrModeCombo)-ne 'Off'){
        $Seconds*=1.18
        if((Combo-Tag $VrModeCombo)-eq'DepthSBS'){
            switch(Combo-Tag $DepthModelCombo){
                'VideoDepthSmall' {$Seconds+=1.0;$Seconds*=1.25}
                'DA3Small' {$Seconds+=2.0;$Seconds*=1.55}
                'DA3Base' {$Seconds+=3.5;$Seconds*=2.2}
                'DA3Large' {$Seconds+=6.0;$Seconds*=4.5}
            }
            if((Combo-Tag $VrLayoutCombo)-in @('FullSBS','FullOU')){$Seconds*=1.18}
            if((Combo-Tag $VRStereoMethodCombo)-eq'Layered'){$Seconds*=1.08}
            elseif((Combo-Tag $VRStereoMethodCombo)-eq'TemporalLDI'){$Seconds*=1.22}
            if((Combo-Tag $VRGenerativeBackendCombo)-ne'Off'){
                if((Combo-Tag $VRGenerativeBackendCombo)-eq'TemporalAtlas'){
                    $GuideSide=if((Combo-Tag $VRGenerativeResolutionCombo)-eq'Auto'){640}else{[int](Combo-Tag $VRGenerativeResolutionCombo)}
                    $AtlasFps=1.15/[math]::Max(0.55,[math]::Pow($GuideSide/640.0,1.45))
                    if((Combo-Tag $PerformanceCombo)-in @('UltraFast','Fast')){$AtlasFps*=1.45}
                    $Seconds+=4.0+$Frames/[math]::Max(0.18,$AtlasFps)
                }elseif((Combo-Tag $VRGenerativeBackendCombo)-eq'MoebiusSparse'){
                    $Steps=if([int]$VRGenerativeChunkSlider.Value-gt 0){[math]::Max(8,[int]$VRGenerativeChunkSlider.Value)}else{18}
                    # Sparse time follows the area of newly exposed holes, not
                    # the number of pixels in the complete 4K eye. Runtime
                    # telemetry replaces this conservative startup estimate.
                    $Seconds+=8.0+$Frames*(0.12+$Steps*0.045)
                }else{
                    $GenerativeSide=if((Combo-Tag $VRGenerativeResolutionCombo)-eq'Auto'){512}else{[int](Combo-Tag $VRGenerativeResolutionCombo)}
                    $GenerativeFps=0.42/[math]::Max(0.35,[math]::Pow($GenerativeSide/512.0,2.0))
                    if((Combo-Tag $VRGenerativeBackendCombo)-eq'M2SVidFull'){$GenerativeFps*=0.92}
                    $Seconds+=24.0+$Frames/[math]::Max(0.03,$GenerativeFps)
                }
            }
            if((Combo-Tag $VRDLSSModeCombo)-eq'PreAndPerEye'){$Seconds*=2.65}
        }
        if([int](Combo-Tag $VrTargetFpsCombo)-gt 0){$Seconds*=1.65}
    }
    $VrSuffix=if((Combo-Tag $VrModeCombo)-in @('CinemaSBS','DepthSBS')){
        switch(Combo-Tag $VrLayoutCombo){'FullSBS'{' · VR-контейнер: '+($Geometry[0]*2)+'×'+$Geometry[1]}'FullOU'{' · VR-контейнер: '+$Geometry[0]+'×'+($Geometry[1]*2)}default{''}}
    }else{''}
    $ExpectedTimeText.Text=if($Realtime){"Realtime: $($Geometry[0])×$($Geometry[1]) · стартовый буфер $([int]$RealtimeBufferSlider.Value) сек · воспроизведение до конца файла."}else{"Ожидаемый выход: $($Geometry[0])×$($Geometry[1])$VrSuffix · оценка: ~$(Format-Time $Seconds); после первых чанков ETA уточнится."}
}
function Update-InputInfo {
    if($InputBox.Text -match '^https?://'){
        $NetworkSourcePanel.Visibility='Visible'
        $script:SourceInfo=$null
        $SourceResolutionText.Text='Сетевой источник: параметры будут прочитаны при запуске'
        $VideoInfo.Text='VK Video и другие сайты через встроенный resolver · выбранный поток можно перематывать.'
        $ExpectedTimeText.Text='Ссылка будет проверена при запуске. Её можно смотреть в realtime или сразу записывать в H.264/H.265.'
        return
    }
    if(-not(Test-Path -LiteralPath $InputBox.Text -PathType Leaf)){
        $NetworkSourcePanel.Visibility='Collapsed'
        $script:SourceInfo=$null;$SourceResolutionText.Text='Исходник: файл ещё не выбран';$VideoInfo.Text='Выберите файл или вставьте ссылку VK Video';return
    }
    try{
        $NetworkSourcePanel.Visibility='Collapsed'
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
    $Realtime = (Get-WorkspaceMode) -eq 'Realtime'
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
    $RealtimeFillPauseCheck.IsEnabled = $Realtime
    $RealtimeQualityCombo.IsEnabled = $Realtime
    $SourceNetworkHeightCombo.IsEnabled = $true
    $SourceCookiesCombo.IsEnabled = $true
    $RealtimeFpsCombo.IsEnabled=$Realtime;$RealtimeTargetFpsCombo.IsEnabled=$Realtime -and (Combo-Tag $FrameGenerationCombo)-eq'NvidiaDynamicMFG';$RealtimeAudioCheck.IsEnabled=$Realtime;$RealtimeVolumeSlider.IsEnabled=$Realtime
    $FrameGenerationCombo.IsEnabled=$Realtime;$RenderPresetCombo.IsEnabled=$Realtime
    foreach($Control in @($GuideWidthSlider,$DepthIntervalSlider,$DepthMinIntervalSlider,$AdaptiveConfidenceSlider,$AdaptiveMotionSlider,$TemporalDepthSlider,$SceneCutSlider,$GuideMotionPresetCombo,$GuideMotionBackendCombo,$GuideWorkerSlider)){$Control.IsEnabled=$Realtime}
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

foreach($S in @($IntensitySlider,$ToneSlider,$StructureSlider,$SkinSlider,$MotionXSlider,$MotionYSlider,$TransferSlider,$ColorSlider,$PaperSlider,$QualitySlider,$UpscalerStrengthSlider,$VREyeSlider,$VRConvergenceSlider,$VRDepthGammaSlider,$VROcclusionSlider,$VREdgeSlider,$VRTemporalSlider,$VRDisparitySlider,$VRForegroundSlider,$VRBackgroundSlider,$VRZBufferSlider,$VRHoleFillSlider,$VRLDILayersSlider,$VRBackgroundExpansionSlider,$VRTemporalFillSlider,$VRTemporalConfidenceSlider,$VREdgeProtectionSlider,$VRDepthTrimSlider,$VRComfortSlider,$VRAdaptiveComfortSlider,$VRMotionSafetySlider,$VRSceneCutRampSlider,$VRInpaintSharpenSlider,$VRConvergenceSmoothingSlider,$VRDepthRangeSmoothingSlider,$VRGenerativeHoleSlider,$VRGenerativeRefineSlider,$VRGenerativeChunkSlider,$VRGenerativeOverlapSlider,$RecordGuideWidthSlider,$RecordDepthIntervalSlider,$RecordDepthMinSlider,$RecordConfidenceSlider,$RecordMotionSlider,$RecordTemporalSlider,$RecordSceneSlider,$RecordRaftSlider,$RecordChunkSlider,$RecordWorkerSlider,$GuideWorkerSlider)){$S.Add_ValueChanged({Refresh-Labels})}
$RealtimeBufferSlider.Add_ValueChanged({Refresh-Labels;Update-Estimate})
$RealtimeChunkSlider.Add_ValueChanged({Refresh-Labels})
$RealtimeQualityCombo.Add_SelectionChanged({
    $Tag=Combo-Tag $RealtimeQualityCombo
    if($Tag-ne'Custom'){
        if(-not $script:SyncingUniversalProfile){
            $script:SyncingUniversalProfile=$true
            try{Select-StringTag $PerformanceCombo $Tag}finally{$script:SyncingUniversalProfile=$false}
        }
        Apply-RealtimeProfile $Tag
    }else{Update-RealtimeQualityInfo}
})
foreach($S in @($GuideWidthSlider,$DepthIntervalSlider,$DepthMinIntervalSlider,$AdaptiveConfidenceSlider,$AdaptiveMotionSlider,$TemporalDepthSlider,$SceneCutSlider,$RaftUpdatesSlider,$GuideWorkerSlider)){$S.Add_ValueChanged({Mark-RealtimeCustom})}
$GuideMotionPresetCombo.Add_SelectionChanged({Mark-RealtimeCustom})
$GuideMotionBackendCombo.Add_SelectionChanged({Mark-RealtimeCustom})
$RealtimeFpsCombo.Add_SelectionChanged({Update-Estimate})
$FrameGenerationCombo.Add_SelectionChanged({Update-ProfileUi;Update-Estimate})
$RealtimeTargetFpsCombo.Add_SelectionChanged({Update-Estimate})
$VrTargetFpsCombo.Add_SelectionChanged({Update-Estimate})
$VRStereoMethodCombo.Add_SelectionChanged({Update-VrUi})
$VRConvergenceModeCombo.Add_SelectionChanged({Update-VrUi})
$VRDLSSModeCombo.Add_SelectionChanged({Update-Estimate})
$VRGenerativeBackendCombo.Add_SelectionChanged({
    $SelectedBackend=Combo-Tag $VRGenerativeBackendCombo
    if($SelectedBackend-ne'Off' -and -not (Test-VrGenerativeBackendInstalled $SelectedBackend)){
        $Message=if($SelectedBackend-eq'TemporalAtlas'){'Temporal Atlas ещё не установлен. Нажмите «Установить ~28 МБ», дождитесь строки TEMPORAL_ATLAS_MODELS_READY и перезапустите Studio.'}elseif($SelectedBackend-eq'MoebiusSparse'){'Moebius — отдельный экспериментальный пакет. Запустите INSTALL_MOEBIUS_EXPERIMENTAL.cmd в папке программы.'}else{'M2SVid — отдельный экспериментальный пакет. Запустите INSTALL_M2SVID_EXPERIMENTAL.cmd в папке программы.'}
        [Windows.MessageBox]::Show($Message,'Генеративный VR',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)|Out-Null
        Select-StringTag $VRGenerativeBackendCombo 'Off'
    }
    Mark-VrCustom
})
$VRGenerativeResolutionCombo.Add_SelectionChanged({Mark-VrCustom})
$VRQualityPresetCombo.Add_SelectionChanged({Apply-VrProfile})
$VrLayoutCombo.Add_SelectionChanged({Mark-VrCustom})
foreach($S in @($VREyeSlider,$VRConvergenceSlider,$VRDepthGammaSlider,$VROcclusionSlider,$VREdgeSlider,$VRTemporalSlider,$VRDisparitySlider,$VRForegroundSlider,$VRBackgroundSlider,$VRZBufferSlider,$VRHoleFillSlider,$VRLDILayersSlider,$VRBackgroundExpansionSlider,$VRTemporalFillSlider,$VRTemporalConfidenceSlider,$VREdgeProtectionSlider,$VRDepthTrimSlider,$VRComfortSlider,$VRAdaptiveComfortSlider,$VRMotionSafetySlider,$VRSceneCutRampSlider,$VRInpaintSharpenSlider,$VRConvergenceSmoothingSlider,$VRDepthRangeSmoothingSlider,$VRGenerativeHoleSlider,$VRGenerativeRefineSlider,$VRGenerativeChunkSlider,$VRGenerativeOverlapSlider)){$S.Add_ValueChanged({Mark-VrCustom})}
foreach($C in @($VRStereoMethodCombo,$VRTemporalModeCombo,$VREyeAnchorCombo,$VRDLSSModeCombo,$VRConvergenceModeCombo,$VRDisparityCurveCombo,$DepthModelCombo)){$C.Add_SelectionChanged({Mark-VrCustom})}
$VREyeSwapCheck.Add_Click({Mark-VrCustom})
$InstallVRModelsButton.Add_Click({
    $Installer=Join-Path $Root 'INSTALL_VR_MODELS.cmd'
    if(-not(Test-Path -LiteralPath $Installer -PathType Leaf)){
        [Windows.MessageBox]::Show('INSTALL_VR_MODELS.cmd отсутствует в папке программы. Обновите portable-сборку.','Установщик не найден',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)|Out-Null
        return
    }
    Start-Process -FilePath "$env:WINDIR\System32\cmd.exe" -ArgumentList @('/c',('"'+$Installer+'"')) | Out-Null
    $VRGenerativeStatusText.Text='Установщик Temporal Atlas открыт отдельно. После строки TEMPORAL_ATLAS_MODELS_READY перезапустите Studio.'
})
$CodecCombo.Add_SelectionChanged({Update-VrUi;Update-Estimate})
$DepthModelCombo.Add_SelectionChanged({Update-Estimate})
$RenderPresetCombo.Add_SelectionChanged({Update-Estimate})
$HardwareCombo.Add_SelectionChanged({Update-Estimate})
$ExpertCheck.Add_Click({Update-ExpertUi})
$WorkspaceTabs.Add_SelectionChanged({Update-WorkspaceUi})
$RecordFineGuideCheck.Add_Click({Update-RecordFineUi;Update-Estimate})
$RecordMotionBackendCombo.Add_SelectionChanged({Update-RecordFineUi})
$QuickScenarioCombo.Add_SelectionChanged({if($QuickScenarioCombo.SelectedItem){Apply-QuickScenario}})
$RealtimeVolumeSlider.Add_ValueChanged({Refresh-Labels})
$PreviewPaneButton.Add_Click({
    $Visible=$PreviewPane.Visibility -eq 'Visible'
    if($Visible){$PreviewPane.Visibility='Collapsed';$PreviewGapColumn.Width=[Windows.GridLength]::new(0);$PreviewColumn.Width=[Windows.GridLength]::new(0);$SettingsColumn.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);$PreviewPaneButton.Content='Показать просмотр'}
    else{$PreviewPane.Visibility='Visible';$SettingsColumn.Width=[Windows.GridLength]::new(620);$PreviewGapColumn.Width=[Windows.GridLength]::new(14);$PreviewColumn.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);$PreviewPaneButton.Content='Скрыть просмотр'}
})

$HelpText=[ordered]@{
    QuickScenarioCombo='Меняет сразу несколько связанных параметров. Это безопасная стартовая точка; после выбора любой параметр можно скорректировать вручную.'
    SourceNetworkHeightCombo='Ограничивает разрешение загружаемого потока по ссылке. Это вход до DLSS5; большее разрешение даёт больше исходных деталей, но требует больше сети, памяти и GPU.'
    SourceCookiesCombo='Использует авторизацию выбранного браузера только для сайтов, где публичного доступа недостаточно. Для открытого видео оставьте «Публичное».'
    ModeCombo='Фактическое разрешение окна или готового файла. Оно не обязано совпадать с входным разрешением ссылки или внутренним render-разрешением DLSS.'
    CodecCombo='Кодек нужен только для записи. H.265 обычно даёт меньший файл при том же качестве; H.264 совместим с большим числом устройств.'
    PerformanceCombo='Универсальный уровень вычислений. Ultra Fast экономит на частоте guide/depth, Maximum строит самые точные карты. Сам DLSS5 Feature 18 всё равно проходит каждый кадр.'
    RenderPresetCombo='Определяет внутреннее разрешение, на котором DLSS5 получает кадр. Auto выбирает масштаб по VRAM и выходному разрешению; Native даёт максимум качества и нагрузки.'
    RealtimeQualityCombo='Готовый набор motion/depth-настроек для живого просмотра. После ручного изменения автоматически станет «Вручную».'
    FrameGenerationCombo='Dynamic MFG целится в выбранный FPS; фиксированный MFG создаёт 2/3/4 кадра на один базовый. Поддержка проверяется через официальный Streamline API.'
    RealtimeTargetFpsCombo='Цель Dynamic MFG. 0 использует частоту текущего монитора; 72/90/120 полезны для шлемов и высокочастотных дисплеев.'
    RealtimeFullscreenCheck='Открывает GPU-direct плеер сразу без рамки на весь экран. F11 и двойной щелчок переключают режим во время просмотра.'
    RealtimeAudioCheck='Звук привязан к фактически показанным кадрам по измеренному аудиочасу. При тяжёлом рендере темп плавно согласуется с видео с сохранением высоты голоса; пауза останавливает само аудиоустройство, а исправный декодер не пересоздаётся.'
    RealtimeVolumeSlider='Громкость отдельного realtime-аудиопотока. На обработку кадров и запись не влияет.'
    RealtimeBufferSlider='Гарантированный запас полностью подготовленных RGB, motion и depth кадров. Плеер запускается только после набора выбранных секунд и затем постоянно восстанавливает этот уровень.'
    RealtimeFillPauseCheck='Если включено, декодирование и построение motion/depth продолжаются на паузе с максимальной доступной скоростью, пока выбранный запас не станет полным. Если выключено, вычислительный конвейер тоже ждёт.'
    RealtimeChunkSlider='Частота пополнения буфера. Авто использует блоки около 0,5 секунды (меньше для 4K), чтобы сложная сцена не задерживала следующую порцию на несколько секунд.'
    GuideWorkerSlider='Число CPU-потоков OpenCV/guide. Авто учитывает доступные ядра и VRAM; ручное завышение может ухудшить плавность из-за конкуренции.'
    GuideWidthSlider='Разрешение служебной motion/depth-карты. Выше — точнее мелкие границы, больше CPU/GPU-нагрузка; выходной кадр DLSS5 остаётся полноразмерным.'
    DepthIntervalSlider='Как часто нейросеть заново считает полную глубину. Меньше N — устойчивее сложное движение и выше нагрузка.'
    DepthMinIntervalSlider='Насколько рано адаптивный алгоритм имеет право обновить depth при плохой уверенности или сильном движении.'
    AdaptiveConfidenceSlider='Если надёжность motion ниже порога, depth обновляется раньше. 0 отключает этот триггер.'
    AdaptiveMotionSlider='Если движение превышает порог, depth обновляется раньше. 0 отключает этот триггер.'
    TemporalDepthSlider='Смешивает depth между кадрами. Больше — стабильнее, но возможно запаздывание на резкой смене глубины.'
    SceneCutSlider='Определяет резкость реакции на монтажную склейку. Малое значение быстрее сбрасывает temporal history, но может давать ложные сбросы.'
    GuideMotionBackendCombo='DIS использует CPU и быстрее; RAFT — нейросетевой optical flow на CUDA, обычно точнее на персонажах и деформациях.'
    VrTargetFpsCombo='Частота записанного VR-файла. 72/90/120 создаются motion-compensated интерполяцией после DLSS5 и стереосинтеза, поэтому оба глаза остаются синхронны.'
    VrModeCombo='Depth 3D строит разные ракурсы глаз; Cinema SBS упаковывает плоское видео; 360 подходит только для готового источника 2:1.'
    VrLayoutCombo='Half экономит разрешение контейнера; Full сохраняет полное разрешение каждого глаза. SBS располагает глаза слева/справа, OU — сверху/снизу.'
    DepthModelCombo='DA2 Small быстрее; Video Depth устойчивее во времени; DA3 Small/Base точнее геометрически; DA3 Large — самый тяжёлый и детальный вариант для офлайн VR-записи.'
    VRQualityPresetCombo='Fast: Half-SBS, DIS и окно 4 кадра. Cinematic: Temporal Atlas с видеоглубиной и окном 8. Maximum: DA3 Large, Full-SBS, окно 12 и отдельный DLSS5-проход для каждого глаза. После ручного изменения выбирается «Вручную».'
    VRDLSSModeCombo='«До стерео» — один настоящий проход DLSS5 Feature 18. «До + по глазам» после создания двух ракурсов запускает DLSS5 ещё раз отдельно для левого и правого глаза; это намного медленнее, но детали глаз не смешиваются через шов SBS.'
    VRGenerativeBackendCombo='Temporal Atlas — основной режим: проверяет bidirectional motion, depth и сцены, затем переносит настоящие 2K/4K-пиксели из соседних кадров. MI-GAN дорисовывает только остаток. Moebius и M2SVid оставлены как тяжёлые эксперименты.'
    VRGenerativeResolutionCombo='Разрешение служебной сетки motion/depth. RGB переносится из нативного 2K/4K-кадра без уменьшения. 512–640 — лучший баланс; 768 полезно для тонких контуров в Maximum.'
    VRGenerativeHoleSlider='Надёжность заполнения: большее значение разрешает Atlas принять больше проверенных пикселей соседних кадров. Слишком низкое оставит больше работы MI-GAN.'
    VRGenerativeRefineSlider='Допуск к изменению света/цвета между соседними кадрами. 0.2–0.35 сохраняет строгую проверку; выше помогает при мерцании, но может принять неверный участок.'
    VRGenerativeChunkSlider='Радиус просмотра назад и вперёд в кадрах. 8 — хороший баланс, 12 — качество. Используются разреженные расстояния 1/2/4/8/12, поэтому время растёт умеренно.'
    VRGenerativeOverlapSlider='Для Temporal Atlas — число итераций RAFT. 4 быстро, 6 качественно, 8 для Maximum. Для Moebius единица равна 32 пикселям перекрытия ROI.'
    InstallVRModelsButton='Скачивает компактную MI-GAN для локального заполнения остаточных областей. RAFT уже входит в основной пакет. Незавершённая загрузка возобновляется.'
    VRStereoMethodCombo='GAPW создаёт строгую карту раскрытых областей и является обязательной базой Temporal Atlas. Temporal LDI — старый многослойный путь. Layered быстрее, Inverse — максимум FPS.'
    VRTemporalModeCombo='Motion-compensated переносит предыдущую глубину по optical flow перед смешиванием и не приклеивает объём к экрану. EMA дешевле, но может плыть; Off полезен для диагностики.'
    VRConvergenceModeCombo='По главному объекту удерживает нулевой параллакс около центрального персонажа. Comfort выбирает устойчивый средний диапазон. Manual использует только ползунок плоскости фокуса.'
    VRDisparityCurveCombo='Cinematic усиливает хорошо читаемые средние планы; Comfort мягко ограничивает экстремальный параллакс; Linear переносит depth без художественного ремаппинга.'
    VREyeAnchorCombo='Симметричный режим строит оба ракурса и даёт центральную композицию. Опорный левый/правый глаз сохраняет один исходный кадр нетронутым, экономит один warp и уменьшает артефакты.'
    VRPixelFormatCombo='8-bit 4:2:0 использует аппаратно совместимые HEVC Main/H.264 High и не даёт чёрный экран в обычных VR-плеерах. 10-bit HEVC Main10 уменьшает цветовые полосы, если шлем его поддерживает.'
    VREyeSlider='Масштаб стереопараллакса. Слишком большое значение вызывает усталость глаз и раскрытые области по краям.'
    VRConvergenceSlider='Глубина плоскости, которая остаётся без горизонтального сдвига. Меняет, какие объекты ощущаются перед экраном или за ним.'
    VRDisparitySlider='Ограничивает максимальный горизонтальный разнос глаз в процентах ширины. Это главный предохранитель VR-комфорта.'
    VRDepthGammaSlider='Перераспределяет глубину между ближними и дальними объектами без изменения выбранной плоскости фокуса.'
    VRForegroundSlider='Отдельно усиливает параллакс объектов ближе плоскости фокуса: персонажей, лиц и переднего плана.'
    VRBackgroundSlider='Отдельно управляет глубиной окружения за плоскостью фокуса. Меньшее значение обычно комфортнее для длительного просмотра.'
    VRZBufferSlider='Насколько строго ближний слой перекрывает дальний при layered splat. Больше сохраняет чёткие силуэты, но может открыть больше дыр.'
    VREdgeSlider='Смягчает резкие границы карты глубины, уменьшая рваные края при построении второго ракурса.'
    VROcclusionSlider='Заполняет области, открывшиеся после построения второго ракурса. Больше — меньше дыр, но слабее настоящий стереоэффект на краях.'
    VRHoleFillSlider='Радиус поиска соседнего видимого слоя для дыр после смещения. Увеличивайте для сильного 3D; слишком большое значение может растянуть фон.'
    VRLDILayersSlider='Число дискретных уровней приоритета layered-depth image. Больше лучше разделяет близкие перекрывающиеся поверхности, но повышает чувствительность к ошибкам depth.'
    VRBackgroundExpansionSlider='Строит отдельную дальнюю цветовую пластину за границами переднего плана. Она используется только в областях, реально раскрывшихся при сдвиге камеры.'
    VRTemporalFillSlider='Доля скрытого фона, переносимая из предыдущего кадра по motion vectors. Убирает мерцание дорисованных краёв; требует Motion temporal.'
    VRTemporalConfidenceSlider='Запрещает temporal-fill там, где optical flow ненадёжен. Больше — меньше шлейфов, но чаще используется пространственное заполнение.'
    VREdgeProtectionSlider='Gradient-aware разделение глубины на силуэтах. Убирает резиновые края волос, рук и персонажей без размытия всего кадра.'
    VRDepthTrimSlider='Отбрасывает небольшой процент выбросов нейроглубины и растягивает полезный диапазон. Обычно 1–3% даёт более выразительный объём.'
    VRComfortSlider='Мягко ограничивает крайний отрицательный и положительный параллакс. 0 сохраняет максимум pop-out; 1 безопаснее для долгого просмотра.'
    VRAdaptiveComfortSlider='Автоматически немного уменьшает параллакс при быстром движении, слабых motion vectors и сразу после монтажной склейки, затем медленно возвращает полный объём. Убирает рывки глубины без постоянного ослабления 3D.'
    VRMotionSafetySlider='Движение в пикселях guide-карты, после которого адаптивный контроллер начинает заметно снижать параллакс. Больше сохраняет сильный 3D даже в динамичных сценах.'
    VRSceneCutRampSlider='Число кадров плавного восстановления стереосилы после склейки. Предотвращает мгновенный скачок плоскости глубины; 0 отключает плавный вход.'
    VRInpaintSharpenSlider='Возвращает локальную резкость только дорисованным disocclusion-областям, не перешарпливая исходный глаз.'
    VRConvergenceSmoothingSlider='Инерция автоматической плоскости фокуса. Больше устраняет прыжки глубины между кадрами; меньше быстрее следует за новым главным объектом.'
    VRDepthRangeSmoothingSlider='Удерживает одинаковый ближний/дальний диапазон depth во времени и подавляет дыхание объёма.'
    VRTemporalSlider='Стабилизирует нейроглубину во времени перед построением глаз. Убирает дрожание объёма, но слишком большое значение замедляет реакцию.'
    VREyeSwapCheck='Меняет местами левый и правый ракурсы, если конкретный VR-плеер трактует порядок глаз наоборот.'
    RecordFineGuideCheck='Открывает ручные motion/depth-параметры записи и VR. Если выключено, работает выбранный универсальный профиль.'
    RecordGuideWidthSlider='Разрешение служебных карт записи. Больше помогает тонким контурам, но увеличивает расчёт и объём sidecar-данных.'
    RecordDepthIntervalSlider='Период полного нейросетевого depth-прохода в записи. 1 означает расчёт на каждом кадре.'
    RecordWorkerSlider='Ручное число CPU-потоков guide для записи/VR. Авто обычно лучше; настройка нужна для необычных систем или параллельной нагрузки.'
    UpscalerCombo='Дополнительная VSR-модель x4. Она необязательна и значительно тяжелее DLSS5; None оставляет только основной DLSS5-конвейер.'
    UpscalerVariantCombo='Компромисс конкретной VSR-модели между скоростью, VRAM и восстановлением деталей. Не меняет универсальный профиль motion/depth.'
    UpscalerStrengthSlider='Смешивает результат внешней VSR-модели с обычным масштабированием. 1.00 — максимальное влияние модели.'
    IntensitySlider='Общая сила DLSS5 neural rendering. Увеличивает дорисовку деталей, но на максимуме может менять исходную структуру.'
    StructureSlider='Влияние DLSS5 на окружение, поверхности и мелкую структуру сцены.'
    SkinSlider='Отдельная сила восстановления персонажей, лиц и кожи. Отрицательное значение оставляет кожу ближе к оригиналу.'
    QualitySlider='Параметр QP аппаратного NVENC. Меньше — выше качество и размер файла; на скорость DLSS5 почти не влияет.'
    StartBox='Позиция начала в секундах. Realtime воспроизводит отсюда до конца; запись начинает выбранный диапазон отсюда.'
    FramesBox='Число кадров только для записи и быстрых тестов. Во вкладке Realtime параметр не используется.'
    FullVideoCheck='Игнорирует число кадров и записывает весь оставшийся ролик, начиная с указанной секунды.'
    LivePreviewCheck='После записи автоматически загружает готовый файл в правую панель. Само кодирование от этого не меняется.'
    ComparisonCheck='Создаёт дополнительное видео слева/справа для проверки результата. Увеличивает время и место на диске.'
    KeepTempCheck='Оставляет промежуточные чанки, карты motion/depth и служебные файлы для диагностики. Обычно выключено.'
}
foreach($Entry in $HelpText.GetEnumerator()){
    $Control=Get-Variable -Name $Entry.Key -ValueOnly -ErrorAction SilentlyContinue
    if($Control){$Control.ToolTip=[string]$Entry.Value;$Control.Add_MouseEnter({param($Sender,$EventArgs)$ContextHelpText.Text=[string]$Sender.ToolTip})}
}
$PresetBox.Add_SelectionChanged({$N=[string]$PresetBox.SelectedItem;if($BuiltIn.Contains($N)){Apply-Settings $BuiltIn[$N]}elseif($script:UserPresets.Contains($N)){Apply-Settings $script:UserPresets[$N]};Refresh-Labels})
$SavePreset.Add_Click({$N=$PresetBox.Text.Trim();if(-not$N){$N='Мой пресет '+(Get-Date -Format 'HHmmss')};if($BuiltIn.Contains($N)){[Windows.MessageBox]::Show('Введите другое имя: встроенный пресет не перезаписывается.','DLSS5 Video Studio')|Out-Null;return};$script:UserPresets[$N]=Current-Settings;Save-Presets;Refresh-Presets $N})
$DeletePreset.Add_Click({$N=$PresetBox.Text.Trim();if($script:UserPresets.Contains($N)){$script:UserPresets.Remove($N);Save-Presets;Refresh-Presets 'Balanced · рекомендовано'}})
$BrowseInput.Add_Click({$D=New-Object Microsoft.Win32.OpenFileDialog;$D.Filter='Video files|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.m4v;*.ts|All files|*.*';if($D.ShowDialog($Window)){$InputBox.Text=$D.FileName;Update-InputInfo}})
$PasteInput.Add_Click({try{$Text=[Windows.Clipboard]::GetText().Trim();if($Text){$InputBox.Text=$Text;Update-InputInfo}}catch{[Windows.MessageBox]::Show('Не удалось прочитать буфер обмена.','DLSS5 Video Studio')|Out-Null}})
$BrowseOutput.Add_Click({$D=New-Object System.Windows.Forms.FolderBrowserDialog;$D.Description='Выберите папку для автоматически названных записей';if(Test-Path -LiteralPath $OutputBox.Text -PathType Container){$D.SelectedPath=$OutputBox.Text};if($D.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$OutputBox.Text=$D.SelectedPath};$D.Dispose()})
$InputBox.Add_LostFocus({Update-InputInfo})
$PerformanceCombo.Add_SelectionChanged({
    $Tag=Combo-Tag $PerformanceCombo
    if((Get-WorkspaceMode)-eq'Realtime' -and $RealtimeProfiles.Contains($Tag) -and -not $script:SyncingUniversalProfile){
        $script:SyncingUniversalProfile=$true
        try{Select-StringTag $RealtimeQualityCombo $Tag}finally{$script:SyncingUniversalProfile=$false}
        Apply-RealtimeProfile $Tag
    }
    Update-ProfileUi
})
$UpscalerCombo.Add_SelectionChanged({Update-UpscalerUi})
$ModeCombo.Add_SelectionChanged({Update-Estimate})
$UpscalerVariantCombo.Add_SelectionChanged({Update-Estimate})
$VrModeCombo.Add_SelectionChanged({Update-VrUi})
$VrLayoutCombo.Add_SelectionChanged({Update-Estimate})
$VREyeSwapCheck.Add_Click({Update-Estimate})
$StageUp.Add_Click({Move-Stage -1})
$StageDown.Add_Click({Move-Stage 1})
$FullVideoCheck.Add_Checked({$FramesBox.IsEnabled=$false;Update-Estimate})
$FullVideoCheck.Add_Unchecked({$FramesBox.IsEnabled=((Get-WorkspaceMode)-ne'Realtime');Update-Estimate})
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
        $MfgDetail = if($script:Result.mfg_actual_multiplier){(' · MFG ×{0:0.00} ({1} кадров)' -f [double]$script:Result.mfg_actual_multiplier,[long]$script:Result.mfg_generated_frames)}else{''}
        $DetailText.Text = "$($script:Result.frames) кадров · $($ShownGeometry[0])×$($ShownGeometry[1]) · $ModeText · $($script:Result.pipeline_label)$MfgDetail"
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
            } elseif ($L -match '^STUDIO_REALTIME_BUFFER_READY_JSON (?<j>.+)$') {
                try {
                    $Buffer=$Matches.j|ConvertFrom-Json
                    $StatusText.Text='Буфер готов — запуск воспроизведения'
                    $DetailText.Text=('Подготовлено {0:0.00} сек ({1} кадров) · задано {2} сек' -f [double]$Buffer.ready_seconds,[int]$Buffer.ready_frames,[int]$Buffer.target_seconds)
                } catch { Add-Log ('Buffer ready JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_REALTIME_BUFFER_LEVEL (?<j>.+)$') {
                try {
                    $Buffer=$Matches.j|ConvertFrom-Json
                    $DetailText.Text=('Постоянный запас: {0:0.00}/{1} сек · единый таймлайн звука и кадров' -f [double]$Buffer.ready_seconds,[int]$Buffer.target_seconds)
                } catch { Add-Log ('Buffer level JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_REALTIME_BUFFER_STATUS (?<j>.+)$') {
                try {
                    $Buffer=$Matches.j|ConvertFrom-Json
                    $PauseText=if([bool]$Buffer.rebuffering){' · синхронное ожидание кадров'}elseif([bool]$Buffer.paused){if([bool]$Buffer.fill_on_pause){' · пауза, буфер наполняется'}else{' · пауза, вычисления остановлены'}}else{''}
                    $FullText=if([bool]$Buffer.full){' · запас полный'}else{''}
                    $DetailText.Text=('Осталось в буфере: {0:0.00}/{1:0.00} сек · пополнение {2:0.0} FPS ({3:0.00}× realtime){4}{5}' -f [double]$Buffer.remaining_seconds,[double]$Buffer.target_seconds,[double]$Buffer.refill_fps,[double]$Buffer.refill_realtime,$FullText,$PauseText)
                    $SpeedText.Text=('Буфер {0:0.00} сек · +{1:0.0} FPS' -f [double]$Buffer.remaining_seconds,[double]$Buffer.refill_fps)
                } catch { Add-Log ('Buffer status JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PLAYER_PLAYING (?<j>.+)$') {
                try {
                    $Playing=$Matches.j|ConvertFrom-Json
                    $StatusText.Text='Realtime-воспроизведение'
                    $SoundText=if([bool]$Playing.audio){'звук синхронизирован'}else{'без звука'}
                    $DetailText.Text=('Позиция {0} · {1} · Space пауза · F11 весь экран' -f (Format-Time ([double]$Playing.position_seconds)),$SoundText)
                } catch { Add-Log ('Player playing JSON: '+$_.Exception.Message) }
            } elseif ($L -match '^STUDIO_PLAYER_REBUFFERING (?<s>[0-9.]+)$') {
                $StatusText.Text='Буфер временно исчерпан — звук и видео удерживаются вместе'
            } elseif ($L -match '^STUDIO_PLAYER_REBUFFERED (?<s>[0-9.]+)$') {
                $StatusText.Text='Realtime-воспроизведение восстановлено синхронно'
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
            } elseif ($L -match '^VR_GENERATIVE_(?<k>STATUS|PROGRESS|DONE) (?<j>.+)$') {
                try {
                    $G=$Matches.j|ConvertFrom-Json
                    $Backend=if($G.backend){[string]$G.backend}else{'M2SVid'}
                    if($Matches.k-eq'PROGRESS'){
                        $StatusText.Text="${Backend}: генеративная реконструкция второго глаза"
                        $SparseDetail=if($G.generated_rois-ne$null){" · ROI $($G.generated_rois)/$($G.rois) · перенос $([math]::Round([double]$G.reused_hole_percent,1))%"}else{''}
                        $DetailText.Text="$($G.frames) из $($G.total) кадров · model $($G.model_canvas)$SparseDetail"
                        if([double]$G.fps-gt 0){$SpeedText.Text=('{0:0.00} gen FPS' -f [double]$G.fps)}
                    }elseif($Matches.k-eq'DONE'){
                        $Preserved=if($G.native_preserved_percent-ne$null){" · нативно сохранено $([math]::Round([double]$G.native_preserved_percent,2))%"}else{''}
                        $DetailText.Text="$Backend завершён · $($G.frames) кадров · $($G.model_canvas)$Preserved"
                    }elseif($G.stage-eq'model-ready'){
                        $Extra=if($G.roi_side){" · ROI до $($G.roi_side) px · $($G.steps) шагов"}else{" · attention: $($G.attention)"}
                        $DetailText.Text="$Backend загружен в VRAM$Extra"
                    }elseif($G.stage-eq'initializing'){
                        $DetailText.Text="$($G.gpu) · $($G.model_canvas) · окно $($G.chunk_frames) кадров"
                    }
                }catch{Add-Log ('Generative VR status JSON: '+$_.Exception.Message)}
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
        if($WorkspaceMode-eq'VR' -and (Combo-Tag $VRGenerativeBackendCombo)-ne'Off' -and -not (Test-VrGenerativeBackendInstalled (Combo-Tag $VRGenerativeBackendCombo))){
            if((Combo-Tag $VRGenerativeBackendCombo)-eq'TemporalAtlas'){
                throw 'Temporal Atlas установлен не полностью. Нажмите «Установить ~28 МБ», дождитесь строки TEMPORAL_ATLAS_MODELS_READY и перезапустите Studio.'
            }
            if((Combo-Tag $VRGenerativeBackendCombo)-eq'MoebiusSparse'){
                throw 'Moebius установлен не полностью. Запустите INSTALL_MOEBIUS_EXPERIMENTAL.cmd и перезапустите Studio.'
            }
            throw 'M2SVid установлен не полностью. Запустите INSTALL_M2SVID_EXPERIMENTAL.cmd и перезапустите Studio.'
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
                '-PerformanceProfile',(Combo-Tag $PerformanceCombo),
                '-HardwareProfile',(Combo-Tag $HardwareCombo),'-RenderPreset',(Combo-Tag $RenderPresetCombo),
                '-DepthModelProfile',(Combo-Tag $DepthModelCombo),
                '-Upscaler',([string]$UpscalerCombo.SelectedItem.Tag),
                '-UpscalerVariant',([string]$UpscalerVariantCombo.SelectedItem.Tag),
                '-UpscalerStrength',([string]::Format($Invariant,'{0:0.###}',[double]$UpscalerStrengthSlider.Value)),
                '-PipelineOrder',$PipelineOrder,
                '-BufferSeconds',[int]$RealtimeBufferSlider.Value,
                '-ChunkFrames',[int]$RealtimeChunkSlider.Value,
                '-StartSeconds',([string]::Format($Invariant,'{0:0.######}',$Start)),
                '-NetworkMaxHeight',[int](Combo-Tag $SourceNetworkHeightCombo),
                '-CookiesBrowser',(Combo-Tag $SourceCookiesCombo),
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
                '-TargetFps',[int](Combo-Tag $RealtimeTargetFpsCombo),'-GuideWorkerThreads',[int]$GuideWorkerSlider.Value,
                '-Volume',[int]$RealtimeVolumeSlider.Value
            )
            if ($RealtimeFullscreenCheck.IsChecked) { $Args += '-Fullscreen' }
            if ($RealtimeAudioCheck.IsChecked) { $Args += '-EnableAudio' }
            if ($RealtimeFillPauseCheck.IsChecked) { $Args += '-FillBufferOnPause' }
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
                '-VRMaxDisparityPercent',([string]::Format($Invariant,'{0:0.###}',[double]$VRDisparitySlider.Value)),
                '-VRStereoMethod',(Combo-Tag $VRStereoMethodCombo),'-VRDLSSMode',(Combo-Tag $VRDLSSModeCombo),'-VREyeAnchor',(Combo-Tag $VREyeAnchorCombo),
                '-VRGenerativeBackend',(Combo-Tag $VRGenerativeBackendCombo),'-VRGenerativeResolution',(Combo-Tag $VRGenerativeResolutionCombo),
                '-VRGenerativeChunkFrames',[int]$VRGenerativeChunkSlider.Value,'-VRGenerativeOverlapFrames',[int]$VRGenerativeOverlapSlider.Value,
                '-VRGenerativeHoleStrength',([string]::Format($Invariant,'{0:0.###}',[double]$VRGenerativeHoleSlider.Value)),
                '-VRGenerativeRefineStrength',([string]::Format($Invariant,'{0:0.###}',[double]$VRGenerativeRefineSlider.Value)),
                '-VRTemporalMode',(Combo-Tag $VRTemporalModeCombo),'-VRPixelFormat',(Combo-Tag $VRPixelFormatCombo),
                '-VRConvergenceMode',(Combo-Tag $VRConvergenceModeCombo),'-VRDisparityCurve',(Combo-Tag $VRDisparityCurveCombo),
                '-VRConvergenceSmoothing',([string]::Format($Invariant,'{0:0.###}',[double]$VRConvergenceSmoothingSlider.Value)),
                '-VRDepthTrimPercent',([string]::Format($Invariant,'{0:0.###}',[double]$VRDepthTrimSlider.Value)),
                '-VRDepthRangeSmoothing',([string]::Format($Invariant,'{0:0.###}',[double]$VRDepthRangeSmoothingSlider.Value)),
                '-VREdgeProtection',([string]::Format($Invariant,'{0:0.###}',[double]$VREdgeProtectionSlider.Value)),
                '-VRComfortStrength',([string]::Format($Invariant,'{0:0.###}',[double]$VRComfortSlider.Value)),
                '-VRAdaptiveComfort',([string]::Format($Invariant,'{0:0.###}',[double]$VRAdaptiveComfortSlider.Value)),
                '-VRMotionSafetyPixels',([string]::Format($Invariant,'{0:0.###}',[double]$VRMotionSafetySlider.Value)),
                '-VRSceneCutRampFrames',[int]$VRSceneCutRampSlider.Value,
                '-VRForegroundStrength',([string]::Format($Invariant,'{0:0.###}',[double]$VRForegroundSlider.Value)),
                '-VRBackgroundStrength',([string]::Format($Invariant,'{0:0.###}',[double]$VRBackgroundSlider.Value)),
                '-VRZBufferStrength',([string]::Format($Invariant,'{0:0.###}',[double]$VRZBufferSlider.Value)),
                '-VRHoleFillRadius',[int]$VRHoleFillSlider.Value,'-VRLDILayers',[int]$VRLDILayersSlider.Value,
                '-VRBackgroundExpansion',[int]$VRBackgroundExpansionSlider.Value,
                '-VRTemporalFill',([string]::Format($Invariant,'{0:0.###}',[double]$VRTemporalFillSlider.Value)),
                '-VRTemporalFillConfidence',([string]::Format($Invariant,'{0:0.###}',[double]$VRTemporalConfidenceSlider.Value)),
                '-VRInpaintSharpen',([string]::Format($Invariant,'{0:0.###}',[double]$VRInpaintSharpenSlider.Value)),
                '-VRTargetFps',[int](Combo-Tag $VrTargetFpsCombo),
                '-GuideWorkerThreads',[int]$RecordWorkerSlider.Value,
                '-NetworkMaxHeight',[int](Combo-Tag $SourceNetworkHeightCombo),
                '-NetworkCookiesBrowser',(Combo-Tag $SourceCookiesCombo),
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
        if ($Realtime) { Add-Log ('Realtime: '+(Combo-Tag $RealtimeQualityCombo)+' · '+(Combo-Tag $GuideMotionBackendCombo)+' · '+(Combo-Tag $FrameGenerationCombo)+' → '+(Combo-Tag $RealtimeTargetFpsCombo)+' FPS · guide '+[int]$GuideWidthSlider.Value+' · depth 1/'+[int]$DepthIntervalSlider.Value+' · буфер '+[int]$RealtimeBufferSlider.Value+' сек · fullscreen '+[bool]$RealtimeFullscreenCheck.IsChecked+' · без лимита кадров') }
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

$WorkspaceTabs.SelectedIndex=0
$ModeCombo.SelectedIndex=2
$CodecCombo.SelectedIndex=0
$PerformanceCombo.SelectedIndex=2
$VrModeCombo.SelectedIndex=0
$VrLayoutCombo.SelectedIndex=0
$VrTargetFpsCombo.SelectedIndex=0
$VRStereoMethodCombo.SelectedIndex=0
$VRTemporalModeCombo.SelectedIndex=0
$VREyeAnchorCombo.SelectedIndex=0
$VRPixelFormatCombo.SelectedIndex=0
$VRDLSSModeCombo.SelectedIndex=0
$VRGenerativeBackendCombo.SelectedIndex=0
$VRGenerativeResolutionCombo.SelectedIndex=0
$VRConvergenceModeCombo.SelectedIndex=0
$VRDisparityCurveCombo.SelectedIndex=0
$HardwareCombo.SelectedIndex=0
$RenderPresetCombo.SelectedIndex=0
$DepthModelCombo.SelectedIndex=0
$FrameGenerationCombo.SelectedIndex=0
$RealtimeTargetFpsCombo.SelectedIndex=3
$RealtimeFpsCombo.SelectedIndex=0
$QuickScenarioCombo.SelectedIndex=2
$SourceNetworkHeightCombo.SelectedIndex=3
$SourceCookiesCombo.SelectedIndex=0
$UpscalerCombo.SelectedIndex=0
$UpscalerVariantCombo.SelectedIndex=0
$UpscalerStrengthSlider.Value=1.0
$NrPresetCombo.SelectedIndex=1
$StyleCombo.SelectedIndex=1
$DepthCombo.SelectedIndex=0
$QualitySlider.Value=18
$GuideMotionPresetCombo.SelectedIndex=0
$GuideMotionBackendCombo.SelectedIndex=0
$RecordMotionPresetCombo.SelectedIndex=1
$RecordMotionBackendCombo.SelectedIndex=0
$RealtimeQualityCombo.SelectedIndex=2
Refresh-VrGenerativeStatus
$VRQualityPresetCombo.SelectedIndex=0
$OutputBox.Text=Join-Path $Root 'output'
Load-Presets
Apply-Settings $BuiltIn['Balanced · рекомендовано']
Apply-RealtimeProfile 'Medium'
Refresh-Labels
Refresh-VrGenerativeStatus
Update-RealtimeQualityInfo
Update-RecordFineUi
Update-UpscalerUi
Update-WorkspaceUi
Update-VrUi
Update-ExpertUi
Refresh-StageList
$Window.ShowDialog() | Out-Null
